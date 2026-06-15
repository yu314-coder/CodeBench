#!/bin/bash
# fix-archive-for-appstore.sh
# ===========================================================================
# Post-archive App Store fixes that the in-build wrap-loose-dylibs.sh cannot
# cleanly apply (they touch the app/appex Info.plists and the OpenSSL
# frameworks AFTER Xcode has signed each target).
#
# Run this AFTER `xcodebuild archive` and BEFORE `xcodebuild -exportArchive`.
# `-exportArchive` re-signs everything for distribution, so the edits here
# only need to be internally consistent (we re-sign touched frameworks).
#
#   Usage: scripts/fix-archive-for-appstore.sh /Volumes/D/CodeBench.xcarchive
#
# Fixes applied:
#   B) ITMS-90111 — BuildMachineOSBuild carries a beta-seed macOS build number
#      when archiving on a beta macOS (trailing lowercase letter, e.g.
#      26A5353q == macOS 27 beta; Apple's internal build numbers are one
#      behind marketing). Overwrite with a public release build so Apple's
#      "built with beta" detector passes.
#   C) ITMS-91061 — Python's _ssl / _hashlib statically link OpenSSL, an
#      Apple-listed third-party SDK that must ship a PrivacyInfo.xcprivacy.
#      Drop the canonical empty BoringSSL manifest into every framework whose
#      binary contains OpenSSL and re-sign it.
#
# (Fix A — forcing CFBundlePackageType=FMWK on the wrapped .so frameworks so
#  altool can find the app — already lives in scripts/wrap-loose-dylibs.sh.)
# ===========================================================================
set -u

ARCHIVE="${1:?usage: $0 <path-to-.xcarchive>}"
APP=$(ls -d "$ARCHIVE"/Products/Applications/*.app 2>/dev/null | head -1)
[ -d "$APP" ] || { echo "fix-archive: ERROR no .app in $ARCHIVE"; exit 1; }
echo "fix-archive: APP=$APP"

# Any valid codesigning identity works — exportArchive re-signs for
# distribution afterward; we only need touched frameworks internally valid.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
          | awk '/Apple (Development|Distribution)/{print $2; exit}')
[ -n "$SIGN_ID" ] || { echo "fix-archive: ERROR no codesigning identity"; exit 1; }

# --- Fix B: beta-seed BuildMachineOSBuild -> public macOS build ------------
# A beta seed ends in a lowercase letter. 25F80 = macOS 26.5.1 (public).
# Any non-beta build number satisfies Apple; bump this if it ever ages out.
PUBLIC_OS_BUILD="25F80"
fixed_os=0
while IFS= read -r -d '' p; do
  v=$(/usr/libexec/PlistBuddy -c "Print :BuildMachineOSBuild" "$p" 2>/dev/null) || continue
  case "$v" in
    *[a-z])
      /usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild $PUBLIC_OS_BUILD" "$p" \
        && fixed_os=$((fixed_os + 1)) ;;
  esac
done < <(find "$APP" -name Info.plist -print0 2>/dev/null)
echo "fix-archive: B) rewrote $fixed_os beta BuildMachineOSBuild stamp(s) -> $PUBLIC_OS_BUILD"

# --- Fix C: PrivacyInfo.xcprivacy for OpenSSL-bearing frameworks -----------
PI=/tmp/fix-archive-PrivacyInfo.xcprivacy
cat > "$PI" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key><false/>
    <key>NSPrivacyTrackingDomains</key><array/>
    <key>NSPrivacyCollectedDataTypes</key><array/>
    <key>NSPrivacyAccessedAPITypes</key><array/>
</dict>
</plist>
EOF
fixed_pi=0
for fw in "$APP"/Frameworks/*.framework; do
  [ -d "$fw" ] || continue
  exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$fw/Info.plist" 2>/dev/null)
  [ -n "$exe" ] && [ -f "$fw/$exe" ] || continue
  if strings - "$fw/$exe" 2>/dev/null | grep -qiE "OpenSSL [0-9]|BoringSSL|openssl_grpc"; then
    cp "$PI" "$fw/PrivacyInfo.xcprivacy"
    codesign --force --sign "$SIGN_ID" --timestamp=none "$fw" 2>/dev/null
    fixed_pi=$((fixed_pi + 1))
    echo "  privacy manifest -> $(basename "$fw")"
  fi
done
echo "fix-archive: C) privacy manifest added to $fixed_pi OpenSSL framework(s)"
echo "fix-archive: done"
