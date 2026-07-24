#!/bin/bash
# One-shot App Store push for build 122: archive -> fix -> export -> verify -> upload.
set -uo pipefail
PROJECT="/Volumes/D/OfflinAi/CodeBench.xcodeproj"
OUT="$HOME/Desktop/CodeBench-build-122"
ARCHIVE="$OUT/CodeBench.xcarchive"
EXPORT="$OUT/export"
IPA=""   # resolved after export (Xcode names it after CFBundleDisplayName, e.g. BenchCode.ipa)
TEAM="LYK4LV2859"
APIKEY="68L7XZ4K92"
APIISSUER="affeed72-2585-4742-b885-300a28f95d1a"
mkdir -p "$OUT"

echo "==> [0/5] clear stale explicit-module / xcbuild caches"
DD="$HOME/Library/Developer/Xcode/DerivedData"
find "$DD" -maxdepth 3 -type d \( -name ExplicitPrecompiledModules -o -name XCBuildData \) -prune -exec rm -rf {} + 2>/dev/null || true
# Clean archive: wipe ArchiveIntermediates so every framework is re-copied
# (guards against the incremental partial-framework-copy that broke a local install).
find "$DD" -maxdepth 4 -type d -name ArchiveIntermediates -prune -exec rm -rf {} + 2>/dev/null || true

echo "==> [1/5] archive (Release, generic iOS)…"
xcodebuild archive \
  -project "$PROJECT" -scheme CodeBench -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" SKIP_INSTALL=NO \
  || { echo "ARCHIVE FAILED"; exit 11; }

echo "==> [2/5] post-archive App Store fixes (B beta-stamp / C privacy / D strays)…"
bash /Volumes/D/OfflinAi/scripts/fix-archive-for-appstore.sh "$ARCHIVE" \
  || { echo "FIX-ARCHIVE FAILED"; exit 12; }

# Archive-root ApplicationProperties is REQUIRED by -exportArchive; a global
# SKIP_INSTALL=NO override sometimes leaves it out → "Unknown Distribution
# Error / expected one {}". Inject it if missing (values read from the .app).
AINFO="$ARCHIVE/Info.plist"
if ! /usr/libexec/PlistBuddy -c "Print :ApplicationProperties" "$AINFO" >/dev/null 2>&1; then
  echo "   ApplicationProperties missing — injecting"
  APPB="$ARCHIVE/Products/Applications/CodeBench.app"
  BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPB/Info.plist")
  SVER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APPB/Info.plist")
  BVER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APPB/Info.plist")
  SIGN=$(codesign -dvv "$APPB" 2>&1 | awk -F'Authority=' '/Authority=Apple/{print $2; exit}')
  /usr/libexec/PlistBuddy \
    -c "Add :ApplicationProperties dict" \
    -c "Add :ApplicationProperties:ApplicationPath string Applications/CodeBench.app" \
    -c "Add :ApplicationProperties:CFBundleIdentifier string $BID" \
    -c "Add :ApplicationProperties:CFBundleShortVersionString string $SVER" \
    -c "Add :ApplicationProperties:CFBundleVersion string $BVER" \
    -c "Add :ApplicationProperties:SigningIdentity string '$SIGN'" \
    -c "Add :ApplicationProperties:Team string $TEAM" \
    "$AINFO"
fi

echo "==> [3/5] export .ipa…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "/Volumes/D/OfflinAi/ExportOptions.plist" \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates \
  || { echo "EXPORT FAILED"; exit 13; }

IPA=$(ls "$EXPORT"/*.ipa 2>/dev/null | head -1); echo "resolved IPA: $IPA"
echo "==> [4/5] verify IPA payload for ITMS-90171 strays…"
WORK="$OUT/verify"; rm -rf "$WORK"; mkdir -p "$WORK"
( cd "$WORK" && unzip -q "$IPA" )
# Whole-Payload check (NOT just inside the .app): -exportArchive sweeps stray
# archive artifacts (e.g. Products/Users/.../SwiftTerm.o) into Payload/ beside
# the .app. Those are outside the app's code signature → safe to strip from the
# IPA zip. Auto-strip and continue rather than abort.
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  echo "   stripping stray: $rel"
  ( cd "$WORK" && zip -dq "$IPA" "$rel" )
done < <(cd "$WORK" && find Payload \( -name '*.dylib' -o -name '*.so.*.bak' -o -name '*.o' -o -name '*.applzma' \) \
           -not -path '*.framework/*' -not -path '*.appex/*' -not -path '*.xpc/*' 2>/dev/null)
# Completeness gate: the IPA MUST contain core Python frameworks.
for need in _ctypes math _hashlib _ssl; do
  if ! (cd "$WORK" && find Payload -maxdepth 4 -type d -name "${need}.framework" | grep -q .); then
    echo "!! COMPLETENESS FAIL: ${need}.framework missing from IPA — aborting upload"; exit 20
  fi
done
echo "   completeness OK (_ctypes/math/_hashlib/_ssl present)"
echo "   payload verified"
ls -la "$IPA"

echo "==> [5/5] upload to App Store Connect via altool…"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$APIKEY" --apiIssuer "$APIISSUER" \
  && echo "UPLOAD SUCCEEDED (build 122)" \
  || { echo "UPLOAD FAILED"; exit 15; }
