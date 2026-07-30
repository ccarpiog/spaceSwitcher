#!/bin/bash
#
# Builds spaceSwitcher and assembles a proper macOS .app bundle.
#
# The app must stay non-sandboxed: it resolves private SkyLight symbols and
# sends Apple Events to System Events. It is ad-hoc signed, which is enough for
# macOS to remember the Automation and Accessibility grants across rebuilds as
# long as the bundle identifier does not change.

set -euo pipefail

APP_NAME="spaceSwitcher"
BINARY_NAME="SpaceSwitcher"
BUILD_DIR=".build/release"
APP_BUNDLE="build/${APP_NAME}.app"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${BINARY_NAME}" "${APP_BUNDLE}/Contents/MacOS/${BINARY_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Every Resources/*.lproj becomes an available language. Adding a translation
# means adding a directory here and nothing else.
for lproj in Resources/*.lproj; do
    [ -d "${lproj}" ] || continue
    cp -R "${lproj}" "${APP_BUNDLE}/Contents/Resources/"
    echo "    bundled $(basename "${lproj}")"
done

printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

# Sign with the Developer ID when one is available, rather than ad-hoc. Two
# reasons: macOS keys TCC grants to the signature, so a stable identity means the
# Automation permission survives rebuilds instead of being re-requested every
# time; and the hardened runtime plus the apple-events entitlement make a dev
# build behave exactly like a release one, so Apple Events cannot work here and
# fail there.
#
# The certificate is identified by SHA-1 hash, not name: the name contains a
# non-ASCII character that shell pipelines mangle, making codesign report
# "no identity found".
IDENTITY_LINE="$(security find-identity -v -p codesigning \
    | grep 'Developer ID Application' | head -1 || true)"

if [ -n "${IDENTITY_LINE}" ]; then
    SIGNING_IDENTITY="$(printf '%s' "${IDENTITY_LINE}" | awk '{print $2}')"
    echo "==> Signing with Developer ID (${SIGNING_IDENTITY})"
    codesign --force --timestamp --options=runtime \
        --entitlements "Resources/spaceSwitcher.entitlements" \
        --sign "${SIGNING_IDENTITY}" \
        "${APP_BUNDLE}"
else
    echo "==> No Developer ID found; ad-hoc signing"
    echo "    Note: the Automation permission will be re-requested after each rebuild."
    # No --options=runtime here: without the hardened runtime the app can still
    # send Apple Events without the entitlement, so an ad-hoc build stays usable.
    codesign --force --sign - "${APP_BUNDLE}"
fi

echo
echo "Built ${APP_BUNDLE}"
echo "Run it with:  open ${APP_BUNDLE}"
echo "Then press Ctrl+Option+Space."
