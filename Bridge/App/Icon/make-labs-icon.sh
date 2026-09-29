#!/bin/zsh
# Regenerates Bridge/App/AuraliscopeLabs.icns (checked in) and its 1024 px preview from the release icon export.
set -euo pipefail
cd "${0:A:h:h:h:h}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -O -module-cache-path "$work/modules" Bridge/App/Icon/labs-icon.swift -o "$work/labs-icon"
"$work/labs-icon" "SoundmeterIcon/soundmeter Exports/soundmeter-macOS-Default-1024@1x.png" "$work/AuraliscopeLabs.iconset" \
    Bridge/App/Icon/AuraliscopeLabs-1024.png
iconutil -c icns "$work/AuraliscopeLabs.iconset" -o Bridge/App/AuraliscopeLabs.icns
find Bridge/App -name '._*' -delete
echo Bridge/App/AuraliscopeLabs.icns
