#!/bin/bash
# wrap-loose-dylibs.sh — App Store fix for CodeBench
# ===================================================
# CodeBench's existing "Install Python" build phase calls BeeWare's
# install_python which wraps every Python C extension (.so) as a
# .framework — already App-Store-compliant.
#
# What it leaves behind: 11 LOOSE .dylib files in Frameworks/ that
# Apple's validator rejects ("binary file is not permitted"):
#
#   libtorch_python.dylib, libshm.dylib              (PyTorch native)
#   libavcodec.62.dylib, libavformat.62.dylib,        (FFmpeg —
#   libavfilter.11.dylib, libavutil.60.dylib,          PyAV bindings)
#   libavdevice.62.dylib, libswresample.6.dylib,
#   libswscale.9.dylib
#   libfortran_io_stubs.dylib                         (scipy fortran)
#   libsf_error_state.dylib                           (scipy aux)
#
# This script (drop into Build Phases → New Run Script Phase, AFTER
# the existing "Install Python" phase, BEFORE Xcode's signing) does:
#
#   1. Walks every *.dylib loose in Frameworks/
#   2. Wraps each as Frameworks/<name>.framework/<name> with Info.plist
#   3. Rewrites every other framework's LC_LOAD_DYLIB reference that
#      pointed at the now-moved dylib (av.*.framework, scipy.*.framework,
#      torch.*.framework, the dylibs themselves)
#   4. Removes the original loose .dylib
#   5. Re-signs every modified binary
#
# Build Settings: ENABLE_USER_SCRIPT_SANDBOXING = NO
# ===================================================
set -e

APP="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
FW="$APP/Frameworks"
IDENT="${EXPANDED_CODE_SIGN_IDENTITY:--}"

[ -d "$FW" ] || { echo "wrap-loose-dylibs: no Frameworks/ dir, skipping"; exit 0; }

# ============================================================
# Helpers
# ============================================================

# Sanitize libfoo.62.dylib → libfoo_62  (frameworks can't have dots
# in their executable name on iOS).
to_fw_name() {
    local base; base=$(basename "$1" .dylib)
    echo "$base" | tr '.' '_'
}

write_plist() {
    local name="$1" out="$2"
    cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>     <string>en</string>
    <key>CFBundleExecutable</key>            <string>${name}</string>
    <key>CFBundleIdentifier</key>            <string>ai.codebench.dylib.${name}</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleName</key>                  <string>${name}</string>
    <key>CFBundlePackageType</key>           <string>FMWK</string>
    <key>CFBundleShortVersionString</key>    <string>1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>MinimumOSVersion</key>              <string>${IPHONEOS_DEPLOYMENT_TARGET:-17.0}</string>
</dict>
</plist>
PLIST
}

sign_bin() {
    codesign --force --sign "$IDENT" --timestamp=none \
        --preserve-metadata=identifier,entitlements,flags "$1" 2>/dev/null \
        || codesign --force --sign "$IDENT" --timestamp=none "$1" 2>/dev/null \
        || true
}

# ============================================================
# Step 1: collect every loose .dylib in Frameworks/  +  build a
# rename map (old basename → new framework relative path)
# ============================================================
MAP_FILE="${TEMP_DIR:-/tmp}/wrap-loose-dylibs-$$.map"
: > "$MAP_FILE"

while IFS= read -r -d '' dylib; do
    base=$(basename "$dylib")
    name=$(to_fw_name "$dylib")
    fw_dir="$FW/${name}.framework"
    new_load="@rpath/${name}.framework/${name}"
    # original_basename | new_load_path | new_framework_dir | new_binary_path
    echo "$base|$new_load|$fw_dir|$fw_dir/$name" >> "$MAP_FILE"
done < <(find "$FW" -maxdepth 1 -name "*.dylib" -not -type l -print0)

LOOSE_COUNT=$(wc -l < "$MAP_FILE" | tr -d ' ')
if [ "$LOOSE_COUNT" -eq 0 ]; then
    echo "wrap-loose-dylibs: 0 loose dylibs — nothing to do"
    rm -f "$MAP_FILE"
    exit 0
fi
echo "wrap-loose-dylibs: $LOOSE_COUNT loose dylibs to wrap"

# ============================================================
# Step 2: build each framework
# ============================================================
while IFS='|' read -r base new_load fw_dir new_bin; do
    [ -z "$base" ] && continue
    src="$FW/$base"
    [ -f "$src" ] || continue
    mkdir -p "$fw_dir"
    mv -f "$src" "$new_bin"
    install_name_tool -id "$new_load" "$new_bin" 2>/dev/null || true
    name=$(basename "$fw_dir" .framework)
    write_plist "$name" "$fw_dir/Info.plist"
done < "$MAP_FILE"

# Also handle versioned-symlink shadows (libavcodec.62.dylib + libavcodec.dylib
# pointing at the same file). Existing CodeBench script already strips the
# .X.Y.Z suffix to produce libavcodec.62.dylib, so we mostly only have one
# version of each — but if the existing script left a raw libavcodec.dylib
# symlink lying around, treat it the same way.
for sym in "$FW"/*.dylib; do
    [ -L "$sym" ] || continue
    base=$(basename "$sym")
    name=$(to_fw_name "$sym")
    fw_dir="$FW/${name}.framework"
    if [ -d "$fw_dir" ]; then
        rm -f "$sym"  # original was already wrapped, just drop the symlink
    fi
done

# ============================================================
# Step 3: rewrite cross-references — every framework binary that
# references one of our moved dylibs needs install_name_tool -change
# ============================================================
rewrite_refs_in() {
    local target="$1"
    [ -f "$target" ] || return
    while IFS='|' read -r base new_load fw_dir new_bin; do
        [ -z "$base" ] && continue
        # The original install_name was @rpath/<base> (CodeBench's
        # existing Install Python script already set those). So look
        # for that exact form and rewrite to the new framework path.
        old_ref="@rpath/$base"
        # Check if this file references that path
        if otool -L "$target" 2>/dev/null | grep -q "^	$old_ref "; then
            install_name_tool -change "$old_ref" "$new_load" "$target" 2>/dev/null || true
        fi
    done < "$MAP_FILE"
}

# Rewrite refs in every framework binary AND in the moved dylibs
# themselves (e.g. libavcodec depends on libavutil)
while IFS= read -r -d '' bin; do
    rewrite_refs_in "$bin"
done < <(
    # Walk every <X>.framework/<X> binary in Frameworks/
    find "$FW" -name "*.framework" -type d -print0 |
    while IFS= read -r -d '' fw; do
        plist="$fw/Info.plist"
        [ -f "$plist" ] || continue
        exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null)
        bin="$fw/$exe"
        [ -f "$bin" ] && printf '%s\0' "$bin"
    done
)

# Make sure dyld can find our wrapped frameworks at runtime — add
# an rpath entry to the main executable. Frameworks/ is the standard
# location dyld searches when @rpath references resolve, so the
# DEFAULT @executable_path/Frameworks rpath that Xcode adds already
# covers us. Verify:
MAIN_BIN="$APP/$EXECUTABLE_NAME"
if [ -f "$MAIN_BIN" ]; then
    if ! otool -l "$MAIN_BIN" 2>/dev/null | grep -A2 LC_RPATH | grep -q "Frameworks"; then
        install_name_tool -add_rpath "@executable_path/Frameworks" "$MAIN_BIN" 2>/dev/null || true
    fi
fi

# ============================================================
# Step 4: re-sign everything modified
# ============================================================
while IFS='|' read -r base new_load fw_dir new_bin; do
    [ -z "$base" ] && continue
    sign_bin "$new_bin"
    codesign --force --sign "$IDENT" --timestamp=none "$fw_dir" 2>/dev/null || true
done < "$MAP_FILE"

# Re-sign every framework whose binary we touched via install_name_tool -change
while IFS= read -r -d '' fw; do
    plist="$fw/Info.plist"
    [ -f "$plist" ] || continue
    exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null)
    bin="$fw/$exe"
    [ -f "$bin" ] && sign_bin "$bin"
    codesign --force --sign "$IDENT" --timestamp=none "$fw" 2>/dev/null || true
done < <(find "$FW" -name "*.framework" -type d -print0)

# Re-sign the main executable too (rpath edit invalidates its signature)
[ -f "$MAIN_BIN" ] && sign_bin "$MAIN_BIN"

rm -f "$MAP_FILE"

LEFT=$(find "$FW" -maxdepth 1 \( -name "*.dylib" -o -name "*.so" \) -not -type l 2>/dev/null | wc -l | tr -d ' ')
WRAPPED=$(find "$FW" -name "*.framework" -type d | wc -l | tr -d ' ')
echo "wrap-loose-dylibs: done — $WRAPPED frameworks, $LEFT loose binaries remain"
[ "$LEFT" -gt 0 ] && {
    echo "  ⚠ remaining loose binaries:"
    find "$FW" -maxdepth 1 \( -name "*.dylib" -o -name "*.so" \) -not -type l | sed 's|^|    |'
}
exit 0
