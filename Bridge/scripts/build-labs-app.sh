#!/bin/zsh
# Builds "Auraliscope Labs.app" (1.3dev), the test app with the DAW Plugin source, into
# experimental-dist/Auraliscope Labs <label> build <n>/. Identity com.jinboz.SoundMeterJBZ.Labs (Bridge/App/Info.plist)
# and its own beta icon, so it installs and runs beside Auraliscope without sharing preferences, logs or privacy grants.
#
# Not sandboxed: an ad hoc signed sandboxed process can neither bind nor connect to the Bridge's Unix socket
# outside its container (checked on macOS 27). See Bridge/ARCHITECTURE.md for the route to a sandboxed release.
set -euo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/prototype-version.sh
sdk="$(xcrun --sdk macosx --show-sdk-path)"
# As scripts/package-app.sh: record the real SDK version so AppKit uses the current window chrome.
link_sdk=(-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk")
swift build -c release -debug-info-format none "${link_sdk[@]}"
binary_directory="$(swift build -c release --show-bin-path "${link_sdk[@]}")"
identity="$(otool -s __TEXT __info_plist -v "$binary_directory/Auraliscope" | grep -c 'com.jinboz.SoundMeterJBZ.Labs' || true)"
(( identity > 0 )) || { echo "error: the binary does not carry the Labs identity" >&2; exit 1; }
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/Auraliscope Labs.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Bridge/App/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
cp Bridge/App/AuraliscopeLabs.icns "$app/Contents/Resources/AuraliscopeLabs.icns"
cp -R Resources/Localization/*.lproj "$app/Contents/Resources/"
cp docs/THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$binary_directory/Auraliscope" "$app/Contents/MacOS/Auraliscope"
find "$app" -name '._*' -delete
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
mkdir -p "$ABR_DIST"
rm -rf "$ABR_DIST/Auraliscope Labs.app"
ditto --norsrc "$app" "$ABR_DIST/Auraliscope Labs.app"
echo "$ABR_DIST/Auraliscope Labs.app"
