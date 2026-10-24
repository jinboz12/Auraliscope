#!/bin/zsh
# Build the public app without App Sandbox, required for the local Bridge socket.
set -euo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/release-version.sh
sdk="$(xcrun --sdk macosx --show-sdk-path)"
# As scripts/package-app.sh: record the real SDK version so AppKit uses the current window chrome.
link_sdk=(-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk")
# A verified release binary can be staged by CI or a sandboxed build using its own scratch directory.
# Ordinary source builds still compile here. ABR_BINARY_DIRECTORY is a directory, never shell arguments.
if [[ -n "${ABR_BINARY_DIRECTORY:-}" ]]; then
    binary_directory="$ABR_BINARY_DIRECTORY"
    [[ -x "$binary_directory/Auraliscope" ]] || { echo "missing release binary: $binary_directory/Auraliscope" >&2; exit 1; }
else
    swift build -c release -debug-info-format none "${link_sdk[@]}"
    binary_directory="$(swift build -c release --show-bin-path "${link_sdk[@]}")"
fi
identity="$(otool -s __TEXT __info_plist -v "$binary_directory/Auraliscope" | grep -c 'com.jinboz.SoundMeterJBZ' || true)"
(( identity > 0 )) || { echo "error: the binary does not carry the release identity" >&2; exit 1; }
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/Auraliscope.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
cp Resources/Auraliscope.icns "$app/Contents/Resources/Auraliscope.icns"
# The 2.0 icon as an Icon Composer document: compiled into Assets.car, macOS 26 draws it with its dark, clear and tinted
# renditions (CFBundleIconName); earlier systems use the .icns above (CFBundleIconFile).
icon_source="$stage/icon/Auraliscope.icon"
mkdir -p "$stage/icon/out"
ditto --norsrc Resources/Auraliscope.icon "$icon_source"
find "$stage/icon" -name '._*' -delete
xcrun actool "$icon_source" --compile "$stage/icon/out" --platform macosx --minimum-deployment-target 13.0 \
    --app-icon Auraliscope --output-partial-info-plist "$stage/icon/partial.plist" >/dev/null
cp "$stage/icon/out/Assets.car" "$app/Contents/Resources/Assets.car"
cp -R Resources/Localization/*.lproj "$app/Contents/Resources/"
# Public source builds can omit separately supplied artwork; ThemeArtwork uses the existing gradient fallback.
if [[ -d Resources/ThemeAssets ]]; then cp -R Resources/ThemeAssets "$app/Contents/Resources/ThemeAssets"; fi
for strings in "$app"/Contents/Resources/*.lproj/*.strings; do
    plutil -lint "$strings" >/dev/null
done
cp COPYRIGHT.md "$app/Contents/Resources/COPYRIGHT.md"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp docs/ASSET_RIGHTS.md docs/SOURCE_DISTRIBUTION.md "$app/Contents/Resources/"
cp docs/THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$binary_directory/Auraliscope" "$app/Contents/MacOS/Auraliscope"
# The symbol table is over half the linked binary and nothing reads it at run time; the unstripped binary stays in
# the build folder for reading crash reports.
strip "$app/Contents/MacOS/Auraliscope"
find "$app" -name '._*' -delete
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
mkdir -p "$ABR_DIST"
rm -rf "$ABR_DIST/Auraliscope.app"
ditto --norsrc "$app" "$ABR_DIST/Auraliscope.app"
echo "$ABR_DIST/Auraliscope.app"
