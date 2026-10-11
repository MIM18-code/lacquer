#!/bin/bash
#
# Build, sign, notarize and package the app.
#
#   packaging/make_dmg.sh
#
# Output goes to packaging/dist/:
#   <DIST_BASENAME>-<VERSION>-arm64.dmg      signed, notarized, stapled
#   <DIST_BASENAME>-<VERSION>-source.tar.gz  GPL corresponding source
#   SHA256SUMS
#
# Environment:
#   NOTARIZE=0|1        default 1 when a Developer ID identity exists
#   SIGN_IDENTITY       override the codesign identity
#   NOTARY_PROFILE      notarytool keychain profile (default: see app.env, then backlot-notary)
#   SOURCE_DIR          build the Swift package from this directory instead of the repo
#                       (for example a git worktree of HEAD while Sources/ is mid-edit)
#
# Names and versions come from packaging/app.env. The tool runtime comes from
# packaging/prepare_runtime.py (run automatically; a no-op when current).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
PKG="$REPO/packaging"
# shellcheck source=app.env
source "$PKG/app.env"
# shellcheck source=release_signing.sh
source "$PKG/release_signing.sh"

SRC_DIR="${SOURCE_DIR:-$REPO}"
DIST="$PKG/dist"
RUNTIME="$PKG/vendor/runtime"
APP_FILE="$DISPLAY_NAME.app"
DMG_NAME="$DIST_BASENAME-$VERSION-arm64.dmg"
SRC_NAME="$DIST_BASENAME-$VERSION-source"

say() { printf '\n== %s\n' "$*"; }

# ---- 1. tool runtime ---------------------------------------------------------
say "tool runtime"
python3 "$PKG/prepare_runtime.py"
for t in ffmpeg ffprobe tsMuxeR; do
    [ -x "$RUNTIME/bin/$t" ] || { echo "missing $RUNTIME/bin/$t" >&2; exit 1; }
done

# ---- 2. Swift build ----------------------------------------------------------
say "swift build (arm64, release)"
swift build -c release --arch arm64 --package-path "$SRC_DIR"
BIN_DIR="$(swift build -c release --arch arm64 --package-path "$SRC_DIR" --show-bin-path)"
EXE="$BIN_DIR/$EXECUTABLE_NAME"
[ -x "$EXE" ] || { echo "built executable not found: $EXE" >&2; exit 1; }

# ---- 3. assemble bundle ------------------------------------------------------
say "assembling $APP_FILE"
STAGE="$DIST/stage"
rm -rf "$STAGE"
APP="$STAGE/dmg/$APP_FILE"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
mkdir -p "$CONTENTS/MacOS" "$RES/bin" "$RES/legal"

cp "$EXE" "$CONTENTS/MacOS/$EXECUTABLE_NAME"
chmod 755 "$CONTENTS/MacOS/$EXECUTABLE_NAME"
# SwiftPM resource bundles, if the package ever gains resources.
for b in "$BIN_DIR"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$RES/"; done

cp "$RUNTIME/bin/ffmpeg" "$RUNTIME/bin/ffprobe" "$RUNTIME/bin/tsMuxeR" "$RES/bin/"
chmod 755 "$RES/bin/"*
# The static tools may link only Apple system libraries. No dylibs ship.
for t in ffmpeg ffprobe tsMuxeR; do
    bad="$(otool -L "$RES/bin/$t" | awk 'NR>1 {print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)"
    if [ -n "$bad" ]; then
        echo "$t links outside /usr/lib and /System:" >&2
        echo "$bad" >&2
        exit 1
    fi
done
echo "ok: ffmpeg, ffprobe, tsMuxeR link only /usr/lib and /System"

cp "$REPO/LICENSE" "$REPO/THIRD_PARTY_NOTICES.md" "$RES/"
cp -R "$RUNTIME/legal/." "$RES/legal/"
cat > "$RES/legal/SOURCE_OFFER.txt" <<OFFER
Written offer for source code

$DISPLAY_NAME $VERSION is free software under the GNU General Public License,
version 3. It bundles FFmpeg and x264, which are also under the GPL.

The complete corresponding source code is available at no charge from:

    $SOURCE_URL

as the file $SRC_NAME.tar.gz. It contains this app's source, the unmodified
FFmpeg, x264, zimg and tsMuxeR source archives, and the scripts that build
them (packaging/prepare_runtime.py). legal/BUILD.txt lists the exact configure
lines and the SHA-256 of each archive.

If that address is unavailable, write to MindInMotion LLC and we will send the
source on request for at least three years after this version was released.
OFFER

PLIST="$CONTENTS/Info.plist"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleDevelopmentRegion     -string "en"                        "$PLIST"
plutil -insert CFBundleExecutable            -string "$EXECUTABLE_NAME"          "$PLIST"
plutil -insert CFBundleIdentifier            -string "$BUNDLE_ID"                "$PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0"                       "$PLIST"
plutil -insert CFBundleName                  -string "$DISPLAY_NAME"             "$PLIST"
plutil -insert CFBundleDisplayName           -string "$DISPLAY_NAME"             "$PLIST"
plutil -insert CFBundlePackageType           -string "APPL"                      "$PLIST"
plutil -insert CFBundleShortVersionString    -string "$VERSION"                  "$PLIST"
plutil -insert CFBundleVersion               -string "$BUILD_NUMBER"             "$PLIST"
plutil -insert LSMinimumSystemVersion        -string "$MIN_MACOS"                "$PLIST"
plutil -insert LSApplicationCategoryType     -string "public.app-category.video" "$PLIST"
plutil -insert NSHighResolutionCapable       -bool true                          "$PLIST"
plutil -insert NSPrincipalClass              -string "NSApplication"             "$PLIST"
plutil -insert NSHumanReadableCopyright      -string "$COPYRIGHT"                "$PLIST"
# Lets Finder offer the app under "Open With" for movies, and accept files
# dropped on its Dock icon. Alternate rank: never the default movie player.
plutil -insert CFBundleDocumentTypes -json \
    '[{"CFBundleTypeName":"Movie","CFBundleTypeRole":"Viewer","LSHandlerRank":"Alternate","LSItemContentTypes":["public.movie","public.mpeg-4","com.apple.quicktime-movie","public.folder"]}]' \
    "$PLIST"
if [ -f "$PKG/AppIcon.icns" ]; then
    cp "$PKG/AppIcon.icns" "$RES/AppIcon.icns"
    plutil -insert CFBundleIconFile -string "AppIcon" "$PLIST"
    echo "icon: AppIcon.icns"
fi
plutil -lint "$PLIST" >/dev/null
printf 'APPL????' > "$CONTENTS/PkgInfo"
xattr -cr "$APP"

# ---- 4. sign: nested tools, main executable, bundle --------------------------
say "signing"
pick_signing_identity
for t in ffmpeg ffprobe tsMuxeR; do
    sign_tool "$RES/bin/$t" "$BUNDLE_ID.$t"
done
sign_code -i "$BUNDLE_ID" "$CONTENTS/MacOS/$EXECUTABLE_NAME"
sign_code "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if [ "$DEVELOPER_ID" = "1" ]; then
    for f in "$RES/bin/ffmpeg" "$RES/bin/ffprobe" "$RES/bin/tsMuxeR" "$CONTENTS/MacOS/$EXECUTABLE_NAME"; do
        info="$(codesign -dvv "$f" 2>&1)"
        grep -q 'flags=.*runtime' <<< "$info" || { echo "hardened runtime missing on $f" >&2; exit 1; }
        grep -q '^Timestamp=' <<< "$info" || { echo "secure timestamp missing on $f" >&2; exit 1; }
    done
    echo "ok: hardened runtime + secure timestamp on all executables"
fi

# ---- 5. smoke test the signed bundle's tools ---------------------------------
say "smoke test (signed, hardened tools)"
"$PKG/smoke_test.sh" "$RES/bin"

# ---- 6. notarize the app -----------------------------------------------------
NOTARIZE="${NOTARIZE:-$DEVELOPER_ID}"
APP_SUBMISSION_ID="-"; DMG_SUBMISSION_ID="-"
if [ "$NOTARIZE" = "1" ] && [ "$DEVELOPER_ID" != "1" ]; then
    echo "NOTARIZE=1 but no Developer ID identity; skipping notarization." >&2
    NOTARIZE=0
fi
if [ "$NOTARIZE" = "1" ]; then
    say "notarize app"
    resolve_notary_profile
    notarize_app "$APP"
    spctl -a -vv "$APP"
else
    echo "Not notarizing (NOTARIZE=$NOTARIZE)."
fi

# ---- 7. DMG ------------------------------------------------------------------
say "dmg"
mkdir -p "$DIST"
ln -s /Applications "$STAGE/dmg/Applications"
DMG="$DIST/$DMG_NAME"
rm -f "$DMG"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGE/dmg" -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
if [ "$DEVELOPER_ID" = "1" ]; then
    if [ "$NOTARIZE" = "1" ]; then
        notarize_dmg "$DMG"
    else
        codesign --force -s "$IDENTITY" --timestamp "$DMG"
    fi
else
    codesign --force -s "$IDENTITY" "$DMG"
fi

# ---- 8. GPL corresponding source ---------------------------------------------
say "source archive"
SRC_STAGE="$STAGE/$SRC_NAME"
mkdir -p "$SRC_STAGE/app" "$SRC_STAGE/upstream"
rsync -a --exclude='.git/' --exclude='.build/' --exclude='/build/' --exclude='.DS_Store' \
    --exclude='packaging/vendor/' --exclude='packaging/dist/' "$REPO/" "$SRC_STAGE/app/"
if [ "$SRC_DIR" != "$REPO" ]; then
    rsync -a "$SRC_DIR/Package.swift" "$SRC_STAGE/app/"
    rsync -a --delete "$SRC_DIR/Sources/" "$SRC_STAGE/app/Sources/"
fi
python3 "$PKG/prepare_runtime.py" --emit-sources "$SRC_STAGE/upstream" >/dev/null
cp "$RUNTIME/legal/BUILD.txt" "$SRC_STAGE/BUILD.txt"
cat > "$SRC_STAGE/README.txt" <<README
Corresponding source for $DISPLAY_NAME $VERSION (GPL-3.0).

app/        this app's source, including packaging/ and Scripts/
upstream/   unmodified FFmpeg, x264, zimg and tsMuxeR source archives with the
            pinned hashes (runtime-sources.json) and the build script
BUILD.txt   exact configure lines and toolchain

Rebuild: cd app && python3 packaging/prepare_runtime.py --force && packaging/make_dmg.sh
README
if command -v git >/dev/null && git -C "$REPO" rev-parse HEAD >/dev/null 2>&1; then
    {
        echo "git commit: $(git -C "$REPO" rev-parse HEAD)"
        [ -z "$(git -C "$REPO" status --porcelain)" ] || echo "WARNING: working tree had uncommitted changes when this was built"
    } > "$SRC_STAGE/GIT_REVISION.txt"
fi
SRC_TAR="$DIST/$SRC_NAME.tar.gz"
rm -f "$SRC_TAR"
COPYFILE_DISABLE=1 tar -czf "$SRC_TAR" -C "$STAGE" "$SRC_NAME"

# ---- 9. checksums ------------------------------------------------------------
say "checksums"
( cd "$DIST" && shasum -a 256 "$DMG_NAME" "$SRC_NAME.tar.gz" > SHA256SUMS && cat SHA256SUMS )
DMG_SHA="$(awk -v n="$DMG_NAME" '$2==n {print $1}' "$DIST/SHA256SUMS")"

# ---- 10. final check on the mounted DMG --------------------------------------
say "verify DMG contents"
MNT="$(mktemp -d)"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MNT" -quiet
trap 'hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true' EXIT
codesign --verify --deep --strict "$MNT/$APP_FILE" && echo "ok: codesign verify (deep, strict)"
if [ "$NOTARIZE" = "1" ]; then
    spctl -a -vv "$MNT/$APP_FILE"
    xcrun stapler validate "$MNT/$APP_FILE"
fi
du -sh "$MNT/$APP_FILE" | awk '{print "app bundle size: " $1}'
du -sh "$RES/bin" | awk '{print "bundled tools size: " $1}'
hdiutil detach "$MNT" -quiet; trap - EXIT
rm -rf "$STAGE"

echo
echo "Built:"
ls -lh "$DMG" "$SRC_TAR"
echo "app notarization submission: $APP_SUBMISSION_ID"
echo "dmg notarization submission: $DMG_SUBMISSION_ID"
echo
echo "SHA-256: \`$DMG_SHA\`"
