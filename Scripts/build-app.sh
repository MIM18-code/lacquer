#!/bin/bash
#
# Builds BluRayCompressor as a self-contained .app bundle with ffmpeg,
# ffprobe, and tsMuxeR (plus all their dynamic-library dependencies) bundled
# inside it, then packages the result as a DMG and ZIP for distribution.
#
# The resulting .app runs on any Apple Silicon Mac (arm64) without requiring
# the recipient to install Homebrew or anything else. Gatekeeper will prompt
# on first launch because the app is ad-hoc signed — right-click → Open.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="BluRayCompressor"
DISPLAY_NAME="Blu-ray Compressor"
BUNDLE_ID="com.joshland.BluRayCompressor"
VERSION="0.1.0"
BUILD_NUMBER="1"
MIN_MACOS="13.0"

BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${DISPLAY_NAME}.app"
DMG_PATH="${BUILD_DIR}/${DISPLAY_NAME}.dmg"
ZIP_PATH="${BUILD_DIR}/${DISPLAY_NAME}.zip"
RES_BIN="${APP_BUNDLE}/Contents/Resources/bin"
RES_LIBS="${APP_BUNDLE}/Contents/Resources/libs"

# Source paths for bundled tools. Override via env to use a different install.
SRC_FFMPEG="${SRC_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
SRC_FFPROBE="${SRC_FFPROBE:-/opt/homebrew/bin/ffprobe}"
SRC_TSMUXER="${SRC_TSMUXER:-/opt/homebrew/bin/tsMuxeR}"

for t in "$SRC_FFMPEG" "$SRC_FFPROBE" "$SRC_TSMUXER"; do
    if [ ! -x "$t" ]; then
        echo "! required tool missing: $t" >&2
        echo "  install with: brew install ffmpeg" >&2
        echo "  tsMuxeR: https://github.com/justdan96/tsMuxer/releases" >&2
        exit 1
    fi
done

if ! command -v dylibbundler >/dev/null 2>&1; then
    echo "! dylibbundler not found. Install with: brew install dylibbundler" >&2
    exit 1
fi

# ---- Build Swift ----
echo "→ Building Swift release binary…"
swift build -c release

BIN=""
for candidate in \
    ".build/arm64-apple-macosx/release/${APP_NAME}" \
    ".build/release/${APP_NAME}" \
    ".build/apple/Products/Release/${APP_NAME}"; do
    if [ -f "$candidate" ]; then
        BIN="$candidate"
        break
    fi
done
if [ -z "$BIN" ]; then
    echo "! built binary not found under .build/" >&2
    exit 1
fi
echo "  binary: $BIN"

# ---- Assemble bundle skeleton ----
echo "→ Assembling ${APP_BUNDLE}…"
rm -rf "$APP_BUNDLE" "$DMG_PATH" "$ZIP_PATH"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "$RES_BIN"
mkdir -p "$RES_LIBS"

cp "$BIN" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# ---- Copy bundled tools ----
echo "→ Copying ffmpeg, ffprobe, tsMuxeR into bundle…"
cp "$SRC_FFMPEG"  "$RES_BIN/ffmpeg"
cp "$SRC_FFPROBE" "$RES_BIN/ffprobe"
cp "$SRC_TSMUXER" "$RES_BIN/tsMuxeR"
chmod +x "$RES_BIN"/*

# ---- Bundle dylibs for ffmpeg/ffprobe via dylibbundler ----
# dylibbundler rewrites each binary's load commands to use
# @executable_path/../libs/ and copies every transitive dylib dependency
# into Contents/Resources/libs/. tsMuxeR is already self-contained against
# /usr/lib/* system libraries, so it needs no bundling.
echo "→ Bundling ffmpeg dynamic dependencies…"
dylibbundler -od -b \
    -x "$RES_BIN/ffmpeg" \
    -d "$RES_LIBS/" \
    -p "@executable_path/../libs/" 2>&1 | tail -5

echo "→ Bundling ffprobe dynamic dependencies…"
dylibbundler -od -b \
    -x "$RES_BIN/ffprobe" \
    -d "$RES_LIBS/" \
    -p "@executable_path/../libs/" 2>&1 | tail -5

# Sanity: ffmpeg should now have only /System/*, /usr/lib/*, and
# @executable_path/* load commands. Note: `| head -N` would trigger SIGPIPE
# on the upstream pipe under `set -o pipefail`; use awk's NR limiter instead.
echo "→ Post-bundle ffmpeg load commands:"
otool -L "$RES_BIN/ffmpeg" | awk 'NR>1 && NR<=16 {print "   ", $1}'

# ---- Write Info.plist via plutil ----
PLIST="${APP_BUNDLE}/Contents/Info.plist"
echo "→ Writing Info.plist…"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleDevelopmentRegion     -string "en"                         "$PLIST"
plutil -insert CFBundleExecutable            -string "${APP_NAME}"                "$PLIST"
plutil -insert CFBundleIdentifier            -string "${BUNDLE_ID}"               "$PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0"                        "$PLIST"
plutil -insert CFBundleName                  -string "${APP_NAME}"                "$PLIST"
plutil -insert CFBundleDisplayName           -string "${DISPLAY_NAME}"            "$PLIST"
plutil -insert CFBundlePackageType           -string "APPL"                       "$PLIST"
plutil -insert CFBundleShortVersionString    -string "${VERSION}"                 "$PLIST"
plutil -insert CFBundleVersion               -string "${BUILD_NUMBER}"            "$PLIST"
plutil -insert LSMinimumSystemVersion        -string "${MIN_MACOS}"               "$PLIST"
plutil -insert NSHighResolutionCapable       -bool true                           "$PLIST"
plutil -insert NSPrincipalClass              -string "NSApplication"              "$PLIST"
plutil -insert LSApplicationCategoryType     -string "public.app-category.video"  "$PLIST"
plutil -lint "$PLIST" > /dev/null
[ -s "$PLIST" ] || { echo "! Info.plist empty" >&2; exit 1; }

# Strip any lingering extended attributes (e.g. com.apple.quarantine from
# the tsMuxeR binary which was downloaded via browser/curl). These would
# invalidate the code signature if left in place.
xattr -cr "$APP_BUNDLE"

# ---- Ad-hoc sign bottom-up ----
# On Apple Silicon every Mach-O must have at least an ad-hoc signature to
# execute, and signing the parent before the children invalidates the
# parent. Sign dylibs first, then executables, then the bundle itself.
echo "→ Ad-hoc signing nested binaries…"
find "$RES_LIBS" -type f \( -name "*.dylib" -o -name "*.so" \) | while read -r dylib; do
    codesign --force --sign - --timestamp=none "$dylib" >/dev/null 2>&1
done
for tool in ffmpeg ffprobe tsMuxeR; do
    codesign --force --sign - --timestamp=none "$RES_BIN/$tool"
done
codesign --force --sign - --timestamp=none "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "→ Signing outer bundle…"
codesign --force --sign - --timestamp=none "$APP_BUNDLE"

echo "→ Verifying signature (deep strict)…"
codesign --verify --deep --strict --verbose=1 "$APP_BUNDLE" 2>&1 | tail -5

# ---- Size summary ----
echo "→ Bundle size:"
du -sh "$APP_BUNDLE"
echo "   dylibs: $(find "$RES_LIBS" -type f | wc -l | tr -d ' ') files, $(du -sh "$RES_LIBS" | cut -f1)"
echo "   tools:  $(du -sh "$RES_BIN"/ffmpeg "$RES_BIN"/ffprobe "$RES_BIN"/tsMuxeR 2>/dev/null | awk '{print $2 ": " $1}')"

# ---- DMG ----
echo "→ Creating DMG…"
hdiutil create \
    -volname "${DISPLAY_NAME}" \
    -srcfolder "$APP_BUNDLE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" 2>&1 | tail -3

# ---- ZIP (alternative, more email/chat friendly) ----
echo "→ Creating ZIP…"
(cd "$BUILD_DIR" && zip -qry "${DISPLAY_NAME}.zip" "${DISPLAY_NAME}.app")

echo
echo "Built:"
du -sh "$APP_BUNDLE" "$DMG_PATH" "$ZIP_PATH"
echo
echo "To launch locally:"
echo "   open \"$APP_BUNDLE\""
echo
echo "To ship:"
echo "   DMG: $DMG_PATH"
echo "   ZIP: $ZIP_PATH"
