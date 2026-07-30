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

# The .icns is a build product rather than a source file, so it is regenerated
# whenever the master is newer. Replacing the artwork and forgetting to rebuild
# the icon would otherwise ship the previous one silently. sips and iconutil are
# part of macOS, so this needs nothing installed — unlike the menu bar PNGs,
# which are committed because generating those needs Pillow.
if [ ! -f "Resources/spaceSwitcher.icns" ] \
    || [ "Resources/AppIcon-1024.png" -nt "Resources/spaceSwitcher.icns" ]; then
    echo "==> Regenerating app icon from master"
    ./scripts/make-app-icon.sh
fi

# Icons. The .icns is named by CFBundleIconFile in Info.plist; the menu bar
# template is found by NSImage(named:), which pairs the two PNGs into one image
# by their @2x suffix. Only these belong in the bundle — AppIcon-1024.png and
# MenuBarIcon.svg are the editable masters and stay in the source tree.
cp "Resources/spaceSwitcher.icns" "${APP_BUNDLE}/Contents/Resources/"
cp "Resources/MenuBarIcon.png" "Resources/MenuBarIcon@2x.png" \
    "${APP_BUNDLE}/Contents/Resources/"

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
