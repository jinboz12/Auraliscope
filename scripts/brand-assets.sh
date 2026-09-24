#!/bin/zsh
# Regenerates the application icon from the Icon Composer exports.
# Run after replacing anything in "SoundmeterIcon/soundmeter Exports"; the outputs are checked in.
set -euo pipefail
cd "${0:A:h:h}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -O -module-cache-path "$work/modules" scripts/brand-assets.swift -o "$work/brand-assets"
"$work/brand-assets" "SoundmeterIcon/soundmeter Exports" "$work/Auraliscope.iconset"
iconutil -c icns "$work/Auraliscope.iconset" -o Resources/Auraliscope.icns
echo "Resources/Auraliscope.icns"
