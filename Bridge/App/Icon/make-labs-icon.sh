#!/bin/zsh
# Regenerates the LABS icon's fallback Bridge/App/AuraliscopeLabs.icns (checked in, for macOS 13 to 15) and its 1024 px
# preview from the Icon Composer document Bridge/App/AuraliscopeLabs.icon (2.0 design, from SoundmeterIcon/2.0). On
# macOS 26 the app shows the document itself, compiled by build-labs-app.sh into Assets.car, with its dark, clear and
# tinted renditions. Needs Icon Composer (in Xcode or /Applications); run outside the sandbox.
set -euo pipefail
cd "${0:A:h:h:h:h}"
ictool="/Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ictool" ]] || ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/AuraliscopeLabs.iconset"
for points in 16 32 128 256 512; do
    for scale in 1 2; do
        suffix=""
        if [[ $scale == 2 ]]; then suffix="@2x"; fi
        "$ictool" Bridge/App/AuraliscopeLabs.icon --export-image --output-file "$work/AuraliscopeLabs.iconset/icon_${points}x${points}${suffix}.png" \
            --platform macOS --rendition Default --width $points --height $points --scale $scale >/dev/null
    done
done
"$ictool" Bridge/App/AuraliscopeLabs.icon --export-image --output-file Bridge/App/Icon/AuraliscopeLabs-1024.png \
    --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
# Before macOS 26 the system draws an .icns as it is: put the full-bleed renders on the 824 / 1024 px grid.
swiftc -O -module-cache-path "$work/modules" Bridge/App/Icon/pad-icon.swift -o "$work/pad-icon"
"$work/pad-icon" "$work/AuraliscopeLabs.iconset"
iconutil -c icns "$work/AuraliscopeLabs.iconset" -o Bridge/App/AuraliscopeLabs.icns
find Bridge/App -name '._*' -delete
echo Bridge/App/AuraliscopeLabs.icns
