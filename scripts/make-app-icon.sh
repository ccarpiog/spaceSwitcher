#!/bin/bash
#
# Builds Resources/spaceSwitcher.icns from the 1024 x 1024 master PNG.
#
# The master must already be squircle-shaped with transparent corners: macOS
# does not round a Mac app icon for you the way iOS does, so a full-bleed square
# would ship as a square. Resources/AppIcon-1024.png satisfies this.
#
# Run after replacing the master:  ./scripts/make-app-icon.sh

set -euo pipefail

cd "$(dirname "$0")/.."

MASTER="Resources/AppIcon-1024.png"
ICONSET="$(mktemp -d)/spaceSwitcher.iconset"
OUTPUT="Resources/spaceSwitcher.icns"

if [ ! -f "${MASTER}" ]; then
    echo "error: ${MASTER} not found" >&2
    exit 1
fi

mkdir -p "${ICONSET}"

# The ten entries a Mac .icns is expected to carry. Each @2x is the same point
# size at double resolution, so 32x32@2x and 64x64 are the same pixel count but
# are not interchangeable — iconutil keys off the file names.
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- ${spec}
    sips -z "$1" "$1" "${MASTER}" --out "${ICONSET}/$2.png" >/dev/null
done

iconutil --convert icns --output "${OUTPUT}" "${ICONSET}"
rm -rf "$(dirname "${ICONSET}")"

echo "Wrote ${OUTPUT} ($(du -h "${OUTPUT}" | cut -f1))"
