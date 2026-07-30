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

echo "==> Ad-hoc signing"
# A stable identity matters: macOS keys TCC grants to the signature, so an
# unsigned rebuild would re-prompt for Automation every time.
codesign --force --deep --sign - "${APP_BUNDLE}"

echo
echo "Built ${APP_BUNDLE}"
echo "Run it with:  open ${APP_BUNDLE}"
echo "Then press Ctrl+Option+Space."
