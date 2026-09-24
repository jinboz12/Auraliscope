#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# swift-driver links through clang with --sysroot, which leaves the Mach-O SDK version at the deployment
# target (13.0). AppKit then treats the app as pre-macOS 26 and keeps the legacy window chrome, so hand
# clang -isysroot to record the real SDK version in LC_BUILD_VERSION.
sdk="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
link_sdk=(-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk")
swift build -c release -debug-info-format none "${link_sdk[@]}" "$@"
binary_directory="$(swift build -c release --show-bin-path "${link_sdk[@]}" "$@")"
linked_sdk="$(otool -l "$binary_directory/Auraliscope" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "sdk" { print $2; found = 0 }')"
if [[ "$linked_sdk" != "$sdk_version" ]]; then
    echo "error: binary records SDK $linked_sdk, expected $sdk_version (legacy window chrome would be used)" >&2
    exit 1
fi
# Every release gets its own folder, named by its version label (e.g. "dist/1.1 Beta 1/").
version_label="$(/usr/libexec/PlistBuddy -c 'Print :AuraliscopeVersionLabel' Resources/Info.plist)"
release_dir="dist/$version_label"
app="$release_dir/Auraliscope.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
rm -f "$app/Icon"$'\r'
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
cp Resources/Auraliscope.icns "$app/Contents/Resources/Auraliscope.icns"
rm -rf "$app/Contents/Resources/"*.lproj(N)
cp -R Resources/Localization/*.lproj "$app/Contents/Resources/"
for strings in "$app/Contents/Resources/"*.lproj/*.strings; do plutil -lint "$strings" >/dev/null; done
cp docs/THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$binary_directory/Auraliscope" "$app/Contents/MacOS/Auraliscope"
xattr -cr "$app"
codesign --force --sign - --entitlements Resources/Auraliscope.entitlements "$app"
codesign --verify --strict "$app"
archive="$release_dir/Auraliscope-${version_label// /-}-macOS.zip"
rm -f "$archive"
ditto -c -k --norsrc --keepParent "$app" "$archive"
echo "$PWD/$app"
echo "$PWD/$archive"
