#!/bin/bash
#
# Build, sign, notarize and package the app.
#
#   packaging/make_dmg.sh                  local build; notarizes when a Developer ID exists
#   NOTARIZE=0 packaging/make_dmg.sh       quick local build, no notarization
#   RELEASE=1 packaging/make_dmg.sh        the release build (see below)
#   RELEASE=1 DRY_RUN=1 packaging/make_dmg.sh
#                                          every release check and the signing, then stop
#                                          before anything is sent to Apple
#
# Everything is built in packaging/dist/stage. Files reach packaging/dist/ only
# after every check passed, so dist/ never holds a half-built or stale artifact:
#   <DIST_BASENAME>-<VERSION>-arm64.dmg            signed, notarized, stapled
#   <DIST_BASENAME>-<VERSION>-arm64-UNNOTARIZED.dmg  any DMG that is not (never release it)
#   <DIST_BASENAME>-<VERSION>-source.tar.gz        GPL corresponding source (git archive of HEAD)
#   SHA256SUMS
# The "SHA-256: `<hash>`" line for release notes prints only for a notarized DMG.
#
# RELEASE=1 requires: a Developer ID Application identity, a working notarytool
# profile, a clean git tree, notarization Accepted for the app and the DMG,
# and stapler validate + spctl passing on both. It fails otherwise.
#
# Environment:
#   RELEASE=1           release mode, as above (forces NOTARIZE=1)
#   DRY_RUN=1           stop before notarytool submit (the checks above still run)
#   NOTARIZE=0|1        default 1 when a Developer ID identity exists
#   SIGN_IDENTITY       override the codesign identity
#   NOTARY_PROFILE      notarytool keychain profile (default: see app.env, then backlot-notary)
#   SOURCE_DIR          build the Swift package from this directory instead of the repo
#                       (a git worktree, or an extracted archive for local tests)
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

RELEASE="${RELEASE:-0}"
DRY_RUN="${DRY_RUN:-0}"
SRC_DIR="${SOURCE_DIR:-$REPO}"
DIST="$PKG/dist"
RUNTIME="$PKG/vendor/runtime"
APP_FILE="$DISPLAY_NAME.app"
SRC_NAME="$DIST_BASENAME-$VERSION-source"
DMG_BASE="$DIST_BASENAME-$VERSION-arm64"

say() { printf '\n== %s\n' "$*"; }
die() { echo "FAILED: $*" >&2; exit 1; }
# Run a verification step; any failure stops the script. A bare `check && echo ok`
# would not, because set -e ignores the left side of &&.
must() { "$@" || die "$*"; }

# ---- 0. preflight and stale-artifact cleanup ---------------------------------
# The commit the source archive is made from: SOURCE_DIR's repo if it is one, else this repo.
if G="$(git -C "$SRC_DIR" rev-parse --show-toplevel 2>/dev/null)"; then SRC_GIT="$G"; else SRC_GIT="$REPO"; fi
COMMIT="$(git -C "$SRC_GIT" rev-parse HEAD)" || die "no git commit to archive source from"
if [ -n "$(git -C "$SRC_GIT" status --porcelain)" ]; then TREE_DIRTY=1; else TREE_DIRTY=0; fi

pick_signing_identity
NOTARIZE="${NOTARIZE:-$DEVELOPER_ID}"
if [ "$RELEASE" = "1" ]; then
    [ "$DEVELOPER_ID" = "1" ] || die "RELEASE=1 needs a Developer ID Application identity (found: $IDENTITY)"
    [ "$NOTARIZE" = "1" ] || die "RELEASE=1 cannot run with NOTARIZE=$NOTARIZE"
    [ "$TREE_DIRTY" = "0" ] || die "RELEASE=1 needs a clean git tree in $SRC_GIT:$(echo; git -C "$SRC_GIT" status --short)"
    if [ -n "${SOURCE_DIR:-}" ] && ! git -C "$SRC_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
        die "RELEASE=1 needs SOURCE_DIR (if set) to be inside a git repository, so the source archive matches the build"
    fi
    resolve_notary_profile || die "RELEASE=1 needs a working notarytool profile"
    echo "release preflight ok: identity, notary profile $NOTARY_PROFILE_RESOLVED, clean tree at ${COMMIT:0:12}"
fi
if [ "$NOTARIZE" = "1" ] && [ "$DEVELOPER_ID" != "1" ]; then
    echo "NOTARIZE=1 but no Developer ID identity; building an UNNOTARIZED DMG." >&2
    NOTARIZE=0
fi
if [ "$NOTARIZE" = "1" ]; then DMG_NAME="$DMG_BASE.dmg"; else DMG_NAME="$DMG_BASE-UNNOTARIZED.dmg"; fi

mkdir -p "$DIST"
rm -rf "$DIST/stage"
rm -f "$DIST/$DMG_BASE.dmg" "$DIST/$DMG_BASE-UNNOTARIZED.dmg" "$DIST/$SRC_NAME.tar.gz" "$DIST/SHA256SUMS"

# ---- 1. tool runtime ---------------------------------------------------------
say "tool runtime"
python3 "$PKG/prepare_runtime.py"
for t in ffmpeg ffprobe tsMuxeR; do
    [ -x "$RUNTIME/bin/$t" ] || die "missing $RUNTIME/bin/$t"
done
# Every file the runtime build recorded must still match its recorded hash.
python3 - "$RUNTIME" <<'PY' || die "runtime does not match MANIFEST.json (rebuild with prepare_runtime.py --force)"
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
manifest = json.loads((root / 'MANIFEST.json').read_text())
bad = [n for n, h in manifest.items() if not (root / n).is_file() or hashlib.sha256((root / n).read_bytes()).hexdigest() != h]
for need in ('bin/ffmpeg', 'bin/ffprobe', 'bin/tsMuxeR'):
    if need not in manifest:
        bad.append(need + ' (not in manifest)')
if bad:
    print('MANIFEST mismatch:', *bad, sep='\n  ')
    sys.exit(1)
print('ok: runtime matches MANIFEST.json (%d files)' % len(manifest))
PY

# ---- 2. Swift build ----------------------------------------------------------
say "swift build (arm64, release)"
swift build -c release --arch arm64 --package-path "$SRC_DIR"
BIN_DIR="$(swift build -c release --arch arm64 --package-path "$SRC_DIR" --show-bin-path)"
EXE="$BIN_DIR/$EXECUTABLE_NAME"
[ -x "$EXE" ] || die "built executable not found: $EXE"

# ---- 3. assemble bundle ------------------------------------------------------
say "assembling $APP_FILE"
STAGE="$DIST/stage"
mkdir -p "$STAGE"
APP="$STAGE/dmg/$APP_FILE"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
mkdir -p "$CONTENTS/MacOS" "$RES/bin" "$RES/legal"

cp "$EXE" "$CONTENTS/MacOS/$EXECUTABLE_NAME"
chmod 755 "$CONTENTS/MacOS/$EXECUTABLE_NAME"
# SwiftPM resource bundles, if the package ever gains resources.
for b in "$BIN_DIR"/*.bundle; do
    if [ -e "$b" ]; then cp -R "$b" "$RES/"; fi
done

cp "$RUNTIME/bin/ffmpeg" "$RUNTIME/bin/ffprobe" "$RUNTIME/bin/tsMuxeR" "$RES/bin/"
chmod 755 "$RES/bin/"*
# The static tools may link only Apple system libraries. No dylibs ship.
for t in ffmpeg ffprobe tsMuxeR; do
    bad="$(otool -L "$RES/bin/$t" | awk 'NR>1 {print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)"
    if [ -n "$bad" ]; then
        echo "$bad" >&2
        die "$t links outside /usr/lib and /System"
    fi
done
echo "ok: ffmpeg, ffprobe, tsMuxeR link only /usr/lib and /System"

cp "$REPO/LICENSE" "$REPO/NOTICE" "$REPO/THIRD_PARTY_NOTICES.md" "$RES/"
cp -R "$RUNTIME/legal/." "$RES/legal/"
# License texts with no pinned source archive to come from (FreeType's FTL,
# taken from the FreeType repository at VER-2-13-3, docs/FTL.TXT).
cp -R "$REPO/packaging/legal-static/." "$RES/legal/"
cat > "$RES/legal/SOURCE_OFFER.txt" <<OFFER
Written offer for source code

$DISPLAY_NAME $VERSION is free software under the GNU General Public License,
version 3. It bundles FFmpeg and x264, which are also under the GPL.

The complete corresponding source code is available at no charge from:

    $SOURCE_URL

as the file $SRC_NAME.tar.gz. It contains this app's source at git commit
$COMMIT, the unmodified FFmpeg, x264, zimg and tsMuxeR source archives, and the
scripts that build them (packaging/prepare_runtime.py). legal/BUILD.txt lists
the exact configure lines and the SHA-256 of each archive.

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
for t in ffmpeg ffprobe tsMuxeR; do
    sign_tool "$RES/bin/$t" "$BUNDLE_ID.$t"
done
sign_code -i "$BUNDLE_ID" "$CONTENTS/MacOS/$EXECUTABLE_NAME"
sign_code "$APP"
must codesign --verify --deep --strict --verbose=2 "$APP"
if [ "$DEVELOPER_ID" = "1" ]; then
    for f in "$RES/bin/ffmpeg" "$RES/bin/ffprobe" "$RES/bin/tsMuxeR" "$CONTENTS/MacOS/$EXECUTABLE_NAME"; do
        info="$(codesign -dvv "$f" 2>&1)" || die "codesign -dvv $f"
        grep -q 'flags=.*runtime' <<< "$info" || die "hardened runtime missing on $f"
        grep -q '^Timestamp=' <<< "$info" || die "secure timestamp missing on $f"
    done
    echo "ok: hardened runtime + secure timestamp on all executables"
fi

# ---- 5. smoke test the signed bundle's tools ---------------------------------
say "smoke test (signed, hardened tools)"
must "$PKG/smoke_test.sh" "$RES/bin"

if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "DRY_RUN=1: preflight, build, signing and smoke test passed. Stopping before notarytool submit."
    echo "Nothing was sent to Apple and nothing was written to $DIST."
    rm -rf "$STAGE"
    exit 0
fi

# ---- 6. notarize the app -----------------------------------------------------
APP_SUBMISSION_ID="-"; DMG_SUBMISSION_ID="-"
if [ "$NOTARIZE" = "1" ]; then
    say "notarize app"
    resolve_notary_profile || die "no working notarytool profile"
    notarize_app "$APP"
    must spctl -a -vv "$APP"
else
    echo "Not notarizing (NOTARIZE=$NOTARIZE): the DMG will be named -UNNOTARIZED."
fi

# ---- 7. DMG ------------------------------------------------------------------
say "dmg"
mkdir -p "$STAGE/out"
ln -s /Applications "$STAGE/dmg/Applications"
DMG="$STAGE/out/$DMG_NAME"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGE/dmg" -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG" || die "hdiutil create"
if [ "$DEVELOPER_ID" = "1" ]; then
    if [ "$NOTARIZE" = "1" ]; then
        notarize_dmg "$DMG"
    else
        sign_code --timestamp "$DMG"
    fi
else
    sign_code "$DMG"
fi

# ---- 8. GPL corresponding source ---------------------------------------------
say "source archive (git archive of ${COMMIT:0:12})"
SRC_STAGE="$STAGE/$SRC_NAME"
mkdir -p "$SRC_STAGE/app" "$SRC_STAGE/upstream"
# Only tracked files at the commit: no .claude/, no build products, no vendor/ or dist/.
git -C "$SRC_GIT" archive --format=tar HEAD | tar -x -C "$SRC_STAGE/app"
python3 "$PKG/prepare_runtime.py" --emit-sources "$SRC_STAGE/upstream" >/dev/null
cp "$RUNTIME/legal/BUILD.txt" "$SRC_STAGE/BUILD.txt"
cat > "$SRC_STAGE/README.txt" <<README
Corresponding source for $DISPLAY_NAME $VERSION (GPL-3.0).

app/        this app's source at the commit in GIT_REVISION.txt (git archive),
            including packaging/ and Scripts/
upstream/   unmodified FFmpeg, x264, zimg, libpng and tsMuxeR source archives, the
            FFmpeg signature and key, and runtime-sources.json with the pinned hashes
BUILD.txt   exact configure lines and toolchain used for the shipped tools
GIT_REVISION.txt  the commit archived into app/

Rebuild the command-line tools (works offline: prepare_runtime.py takes the
archives from ../upstream after checking each SHA-256):

    cd app
    python3 packaging/prepare_runtime.py --force

Then build the app and package it:

    packaging/make_dmg.sh

Toolchain: an Apple Silicon Mac (arm64, macOS $MIN_MACOS or later target), Xcode or
the Xcode command line tools (clang, make, Swift 5.9 or later), and Homebrew
packages autoconf, automake, libtool and pkg-config:

    brew install autoconf automake libtool pkg-config

gpg is optional; with it the build also verifies FFmpeg's release signature.
nasm is not needed: x264 and FFmpeg use clang's assembler for the arm64 NEON code.
The build tree defaults to /private/tmp/lacquer-runtime-build (set
RUNTIME_BUILD_DIR to move it; the path must not contain spaces).
README
{
    echo "git commit: $COMMIT"
    echo "archived with: git archive HEAD (tracked files only)"
    if [ "$TREE_DIRTY" = "1" ]; then
        echo "WARNING: the working tree had uncommitted changes when the app was built;"
        echo "         the app binary may differ from this commit."
    fi
} > "$SRC_STAGE/GIT_REVISION.txt"
SRC_TAR="$STAGE/out/$SRC_NAME.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$SRC_TAR" -C "$STAGE" "$SRC_NAME"
# The archive must not carry anything personal or untracked.
if tar -tzf "$SRC_TAR" | grep -E '/(\.claude|\.build|vendor|dist|menu_check)(/|$)' >/dev/null; then
    die "source archive contains build products or local folders"
fi

# ---- 9. verify the finished DMG (nothing has been published yet) -------------
say "verify DMG"
MNT="$(mktemp -d)"
must hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MNT" -quiet
trap 'hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true' EXIT
must codesign --verify --deep --strict "$MNT/$APP_FILE"
echo "ok: codesign verify (deep, strict) on the app inside the DMG"
if [ "$NOTARIZE" = "1" ]; then
    must spctl -a -vv "$MNT/$APP_FILE"
    must xcrun stapler validate "$MNT/$APP_FILE"
    must xcrun stapler validate "$DMG"
    must spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
du -sh "$MNT/$APP_FILE" | awk '{print "app bundle size: " $1}'
du -sh "$RES/bin" | awk '{print "bundled tools size: " $1}'
must hdiutil detach "$MNT" -quiet
trap - EXIT

# ---- 10. publish into dist/ --------------------------------------------------
say "checksums"
( cd "$STAGE/out" && shasum -a 256 "$DMG_NAME" "$SRC_NAME.tar.gz" > SHA256SUMS ) || die "shasum"
mv "$STAGE/out/$DMG_NAME" "$STAGE/out/$SRC_NAME.tar.gz" "$STAGE/out/SHA256SUMS" "$DIST/"
( cd "$DIST" && must shasum -a 256 -c SHA256SUMS )
DMG_SHA="$(awk -v n="$DMG_NAME" '$2==n {print $1}' "$DIST/SHA256SUMS")"
[ -n "$DMG_SHA" ] || die "no checksum for $DMG_NAME"
rm -rf "$STAGE"

echo
echo "Built:"
ls -lh "$DIST/$DMG_NAME" "$DIST/$SRC_NAME.tar.gz"
echo "source commit: $COMMIT (tree dirty: $TREE_DIRTY)"
echo "app notarization submission: $APP_SUBMISSION_ID"
echo "dmg notarization submission: $DMG_SUBMISSION_ID"
echo
if [ "$NOTARIZE" = "1" ]; then
    echo "SHA-256: \`$DMG_SHA\`"
else
    echo "UNNOTARIZED build: do not publish. No release SHA-256 line is printed."
fi
