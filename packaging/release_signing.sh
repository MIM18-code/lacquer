# Signing and notarization helpers for make_dmg.sh. Source this file; it
# defines functions and sets nothing until called. Adapted from Dumptruck's
# packaging/release_signing.sh.
#
# Identity order: SIGN_IDENTITY, then the first "Developer ID Application"
# identity in the keychain, then ad-hoc. Only a Developer ID identity gets the
# hardened runtime and a secure timestamp, and only a Developer ID build can be
# notarized.
#
# Notarization reads credentials from a notarytool keychain profile:
# NOTARY_PROFILE, else NOTARY_PROFILE_DEFAULT from app.env, else
# backlot-notary. The credentials belong to the MindInMotion team, not to one
# app. A profile is created once with
#   xcrun notarytool store-credentials <name> --apple-id <account> --team-id <TEAMID>
# The password is typed at that prompt and never appears in these scripts.
#
# The bundled tools (ffmpeg, ffprobe, tsMuxeR) and the app need no
# entitlements under the hardened runtime: none of them uses JIT, loads
# third-party plug-ins, or reads another app's data. The app is not sandboxed
# because it launches the tools and reads user-chosen files. If a tool ever
# needs an exception, add a plist under packaging/entitlements/ and pass it
# through sign_code --entitlements.

pick_signing_identity() {
    local identities developer_id
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    developer_id="$(sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<< "$identities" | head -1)"
    if [ -n "${SIGN_IDENTITY:-}" ]; then
        IDENTITY="$SIGN_IDENTITY"
    elif [ -n "$developer_id" ]; then
        IDENTITY="$developer_id"
    else
        IDENTITY="-"
    fi
    case "$IDENTITY" in
        "Developer ID Application:"*)
            DEVELOPER_ID=1
            SIGN_FLAGS=(--options runtime --timestamp) ;;
        *)
            DEVELOPER_ID=0
            SIGN_FLAGS=() ;;
    esac
    printf 'Signing identity: %s\n' "$IDENTITY"
}

# bash 3.2 treats an empty array as unbound under set -u, hence the guard.
sign_code() {
    codesign --force -s "$IDENTITY" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$@"
}

# Sign a standalone tool with an explicit identifier (BUNDLE_ID.<tool>) so the
# signature does not depend on the file name.
sign_tool() {
    local path="$1" ident="$2"
    sign_code -i "$ident" "$path"
}

# Choose the notarytool keychain profile into NOTARY_PROFILE_RESOLVED.
resolve_notary_profile() {
    local candidate
    NOTARY_PROFILE_RESOLVED=""
    for candidate in "${NOTARY_PROFILE:-}" "${NOTARY_PROFILE_DEFAULT:-}" backlot-notary; do
        [ -n "$candidate" ] || continue
        if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then
            NOTARY_PROFILE_RESOLVED="$candidate"
            return 0
        fi
    done
    echo "No working notarytool keychain profile (tried: ${NOTARY_PROFILE:-}, ${NOTARY_PROFILE_DEFAULT:-}, backlot-notary)." >&2
    echo "Create one with: xcrun notarytool store-credentials <name> --apple-id <account> --team-id <TEAMID>" >&2
    return 1
}

# Submit a .zip or .dmg, wait, print Apple's log on failure. Sets
# LAST_SUBMISSION_ID. Does not staple.
notarize_submit() {
    local file="$1" result status
    result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE_RESOLVED" --wait --output-format json)" \
        || { echo "notarytool submit failed for $file; check the '$NOTARY_PROFILE_RESOLVED' profile" >&2; return 1; }
    status="$(/usr/bin/plutil -extract status raw -o - - <<< "$result")"
    LAST_SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - - <<< "$result")"
    if [ "$status" != "Accepted" ]; then
        echo "Notarization $status for $file (submission $LAST_SUBMISSION_ID). Apple's log:" >&2
        xcrun notarytool log "$LAST_SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE_RESOLVED" >&2 || true
        return 1
    fi
}

# Notarize and staple a .app. The ticket travels inside the bundle, so the app
# still opens offline after it is dragged out of the DMG.
notarize_app() {
    local app="$1" zip
    zip="$(mktemp -d)/$(basename "$app").zip"
    ditto -c -k --keepParent "$app" "$zip"
    echo "== notarizing app with profile $NOTARY_PROFILE_RESOLVED (usually a few minutes)"
    notarize_submit "$zip" || { rm -f "$zip"; return 1; }
    rm -f "$zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    APP_SUBMISSION_ID="$LAST_SUBMISSION_ID"
    printf 'App notarized and stapled (submission %s)\n' "$APP_SUBMISSION_ID"
}

# Sign the DMG, submit it, staple, and check Gatekeeper accepts it.
notarize_dmg() {
    local dmg="$1"
    codesign --force -s "$IDENTITY" --timestamp "$dmg"
    echo "== notarizing DMG with profile $NOTARY_PROFILE_RESOLVED (usually a few minutes)"
    notarize_submit "$dmg" || return 1
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
    DMG_SUBMISSION_ID="$LAST_SUBMISSION_ID"
    printf 'DMG notarized and stapled (submission %s)\n' "$DMG_SUBMISSION_ID"
}
