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
# Every build gets its own folder, "<version label> build <build>" from Resources/Info.plist, grouped under the
# version line it belongs to, "dist/<major.minor> ver/" (e.g. dist/1.1 ver/1.1dev build 22). A pre-release
# (a label with "dev") carries the version on its app and archive. RC and release downloads use
# Auraliscope.app inside Auraliscope.zip and Auraliscope.dmg; Info.plist retains the version and build.
version_label="$(/usr/libexec/PlistBuddy -c 'Print :AuraliscopeVersionLabel' Resources/Info.plist)"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
name="$version_label build $build_number"
version_line="$(echo "$version_label" | grep -oE '^[0-9]+\.[0-9]+')"
release_dir="dist/$version_line ver/$name"
if [[ "$version_label" == *dev* ]]; then
    app_name="Auraliscope $name.app"
    archive_name="Auraliscope-${name// /-}-macOS.zip"
else
    app_name="Auraliscope.app"
    archive_name="Auraliscope.zip"
fi
# Assemble and sign on the local disk: a non-APFS volume (such as an external exFAT drive) adds "._" files
# inside the bundle, which invalidate the signature.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/$app_name"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
cp Resources/Auraliscope.icns "$app/Contents/Resources/Auraliscope.icns"
cp -R Resources/Localization/*.lproj "$app/Contents/Resources/"
for strings in "$app/Contents/Resources/"*.lproj/*.strings; do plutil -lint "$strings" >/dev/null; done
cp docs/THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$binary_directory/Auraliscope" "$app/Contents/MacOS/Auraliscope"
find "$app" -name '._*' -delete
xattr -cr "$app"
codesign --force --sign - --entitlements Resources/Auraliscope.entitlements "$app"
codesign --verify --strict "$app"
(cd "$stage" && ditto -c -k --norsrc --keepParent "$app_name" "$archive_name")
checksummed=("$archive_name")
# Anything shared beyond development (a release, or a candidate such as 1.1rc) also gets a disk image: the app,
# an Applications link to drag it onto, and the first-launch steps for an unnotarized build.
disk_image=""
if [[ "$version_label" != *dev* ]]; then
    disk_image="Auraliscope.dmg"
    dmg_root="$stage/dmg"
    mkdir -p "$dmg_root"
    ditto --norsrc "$app" "$dmg_root/$app_name"
    ln -s /Applications "$dmg_root/Applications"
    cp docs/DMG_README.txt "$dmg_root/Read Me First.txt"
    chmod 644 "$dmg_root/Read Me First.txt"
    hdiutil create -quiet -volname "Auraliscope $version_label" -srcfolder "$dmg_root" -fs HFS+ -format UDZO -ov \
        "$stage/$disk_image"
    hdiutil verify -quiet "$stage/$disk_image"
    checksummed+=("$disk_image")
fi
(cd "$stage" && shasum -a 256 "${checksummed[@]}" > SHA256SUMS.txt)
rm -rf "$release_dir"
mkdir -p "$release_dir"
ditto --norsrc "$app" "$release_dir/$app_name"
for file in "${checksummed[@]}" SHA256SUMS.txt; do cp "$stage/$file" "$release_dir/"; done
echo "$PWD/$release_dir/$app_name"
echo "$PWD/$release_dir/$archive_name"
[[ -n "$disk_image" ]] && echo "$PWD/$release_dir/$disk_image"
true
