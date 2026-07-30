#!/usr/bin/env bash
#
# Builds, signs, notarizes and staples spaceSwitcher for distribution.
#
# Follows the machine's SIGN_AND_NOTARIZE runbook. Idempotent: safe to re-run
# after a partial failure.
#
# Usage: ./scripts/release.sh

set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_ROOT="$PWD"

APP_NAME="spaceSwitcher"
APP_PATH="${PROJECT_ROOT}/build/${APP_NAME}.app"
ENTITLEMENTS="${PROJECT_ROOT}/Resources/spaceSwitcher.entitlements"
OUTPUT_DIR="${PROJECT_ROOT}/build"
NOTARY_PROFILE="AC_NOTARY_PROFILE"

CRED_ROOT="/Users/ccarpio/Library/CloudStorage/OneDrive-Personal/A07-Desarrollador"

# ---------- identity ----------
# The certificate's SHA-1 hash is used rather than its human-readable name:
# the name contains a non-ASCII character, and passing it through the shell
# mangles the encoding so codesign reports "no identity found".
IDENTITY_LINE="$(security find-identity -v -p codesigning \
    | grep 'Developer ID Application' | head -1)"
if [ -z "$IDENTITY_LINE" ]; then
    echo "No Developer ID Application identity in the keychain." >&2
    echo "Import ${CRED_ROOT}/Developer ID Application certificate/Certificates.p12 via Keychain Access first." >&2
    exit 2
fi
SIGNING_IDENTITY="$(printf '%s' "$IDENTITY_LINE" | awk '{print $2}')"
TEAM_ID="$(printf '%s' "$IDENTITY_LINE" | sed -E 's/.*\(([^)]+)\)".*/\1/')"
echo "==> Identity: ${SIGNING_IDENTITY} (team ${TEAM_ID})"

# ---------- notarytool profile ----------
# Created once and stored in the login keychain; never recreated blindly.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Creating notarytool keychain profile"
    KEY_ID="$(tr -d '[:space:]' < "${CRED_ROOT}/App Store Connect API/Key ID.txt")"
    ISSUER_ID="$(tr -d '[:space:]' < "${CRED_ROOT}/App Store Connect API/Issuer ID.txt")"
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \
        --key    "${CRED_ROOT}/App Store Connect API/AuthKey_${KEY_ID}.p8" \
        --key-id "$KEY_ID" \
        --issuer "$ISSUER_ID"
fi

# ---------- build ----------
echo "==> Building the app bundle"
"${PROJECT_ROOT}/build.sh" >/dev/null

# ---------- sign ----------
# Only one Mach-O here (no nested frameworks or helpers), but sign inside-out
# anyway so adding one later does not silently break notarization.
echo "==> Signing with hardened runtime and secure timestamp"
codesign --force --timestamp --options=runtime \
    --sign "$SIGNING_IDENTITY" \
    "${APP_PATH}/Contents/MacOS/SpaceSwitcher"

codesign --force --timestamp --options=runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=4 "$APP_PATH" 2>&1 \
    | grep -E 'Authority|TeamIdentifier|runtime' || true

# ---------- notarize ----------
ZIP_PATH="${OUTPUT_DIR}/${APP_NAME}.zip"
echo "==> Zipping for submission"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple (this usually takes 1-5 minutes)"
SUBMIT_JSON="${OUTPUT_DIR}/notarization.json"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 30m --output-format json \
    > "$SUBMIT_JSON"

STATUS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$SUBMIT_JSON")"
SUBMISSION_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$SUBMIT_JSON")"
echo "==> Notarization status: ${STATUS}"

if [ "$STATUS" != "Accepted" ]; then
    echo "Notarization failed. Fetching the log:" >&2
    xcrun notarytool log "$SUBMISSION_ID" \
        --keychain-profile "$NOTARY_PROFILE" \
        "${OUTPUT_DIR}/notarization-log.json" || true
    cat "${OUTPUT_DIR}/notarization-log.json" >&2 || true
    exit 1
fi

# ---------- staple ----------
echo "==> Stapling the ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Final Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo
echo "Done. Signed, notarized and stapled: ${APP_PATH}"
echo
echo "Note: the code signature changed, so macOS treats this as a new app."
echo "It will ask for Automation permission again the first time you jump."
