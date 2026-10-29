#!/bin/zsh
# Builds a test-only VST3 of the current source, "Auraliscope Bridge Dev.vst3", into .build/bridge/dev/: the same
# plugin with a class ID, name, Swift module and window class of its own, so a host can load it next to an installed
# Auraliscope Bridge (a host resolves a VST3 by its class ID, and would load the installed one instead). Nothing is
# installed; daw-reaper.sh puts it on a private REAPER profile's VST path (ABR_REAPER_VST3).
set -euo pipefail
cd "${0:A:h:h:h}"
# ABR_VERSION_FILE: another version identity (Bridge/scripts/ipad-dev-version.sh for the iPad development builds), with
# ABR_OBJ its own object folder so the two never mix.
version_file="${ABR_VERSION_FILE:-Bridge/scripts/release-version.sh}"
source "$version_file"
Bridge/scripts/build-plugins.sh >/dev/null  # the shared objects, up to date
obj="${ABR_OBJ:-.build/bridge/obj}"
dev=.build/bridge/dev
mkdir -p "$obj/dev" "$dev"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
vst3=Bridge/ThirdParty/vst3sdk
arch=(-arch arm64 -arch x86_64)
base=(-isysroot "$sdk" -mmacosx-version-min=11.0 $arch -O2 -g0 -fvisibility=hidden -fvisibility-inlines-hidden
      -Wall -Wno-unused-parameter -DABR_PLUGIN_VERSION="\"$ABR_LABEL build $ABR_BUILD dev\"")
ours=(-I Sources/BridgeTransport/include -I Bridge/Plugin/Core -I Bridge/Plugin/Editor -I Bridge/Plugin/Analysis/include)
vst3_flags=(-std=c++17 -DRELEASE=1 -I "$vst3" -Wno-deprecated-declarations -Wno-unknown-pragmas -Wno-unused-variable
            -Wno-unused-function -Wno-overloaded-virtual -Wno-extra-tokens)
clang++ -c Bridge/Plugin/VST3/BridgeVST3.cpp -o "$obj/dev/BridgeVST3.o" "${base[@]}" $vst3_flags $ours \
    -DABR_VST3_UID=0x03A87F06,0x69544B23,0xB85B74F8,0x248F8E77 -DABR_VST3_NAME="\"Auraliscope Bridge Dev\""
clang++ -c Bridge/Plugin/Editor/BridgeEditor.mm -o "$obj/dev/BridgeEditor.o" "${base[@]}" -std=c++17 -fobjc-arc $ours \
    -DABR_EDITOR_CLASS=AuraliscopeBridgeEditorVST3Dev_${ABR_BUILD}
analysis=.build/bridge/analysis/vst3-dev.a
Bridge/scripts/build-analysis-lib.sh AuraliscopeBridgeAnalysisVST3Dev "$analysis" >/dev/null
objects=($obj/sdk-vst3/*.o(N) $obj/common/BridgeDiscovery.o $obj/common/BridgeCore.o $obj/common/BridgeSender.o
         $obj/common/BridgeAnalysisHub.o $obj/common/BridgeNetLink.o $obj/common/BridgeRemote.o $obj/dev/BridgeVST3.o $obj/dev/BridgeEditor.o $analysis)

# Assembled and signed on the local disk (the exFAT volume adds "._" files that invalidate signatures).
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
name="Auraliscope Bridge Dev.vst3"
contents="$stage/$name/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
sed -e "s/@VERSION@/$ABR_PLUGIN_BUNDLE_VERSION/g" -e "s/@BUILD@/$ABR_BUILD/g" \
    -e "s/com.jinboz.AuraliscopeBridge.vst3/com.jinboz.AuraliscopeBridge.dev.vst3/" \
    Bridge/Plugin/Resources/VST3-Info.plist > "$contents/Info.plist"
plutil -replace CFBundleName -string "Auraliscope Bridge Dev" "$contents/Info.plist"
plutil -lint "$contents/Info.plist" >/dev/null
printf 'BNDL????' > "$contents/PkgInfo"
swift_libs=(-L/usr/lib/swift -L"$sdk/usr/lib/swift" -L"${$(xcrun -f swiftc):h:h}/lib/swift/macosx")
clang++ -isysroot "$sdk" -mmacosx-version-min=11.0 $arch -bundle -dead_strip $swift_libs -framework Cocoa \
    -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -framework Accelerate \
    -framework Network -framework Security -framework SystemConfiguration \
    -exported_symbols_list "$vst3/public.sdk/source/main/macexport.exp" $objects -o "$contents/MacOS/Auraliscope Bridge"
cp Bridge/THIRD_PARTY_NOTICES.md "$contents/Resources/"
xattr -cr "$stage/$name"
codesign --force --sign - --timestamp=none "$stage/$name"
codesign --verify --strict "$stage/$name"
rm -rf "$dev/$name"
ditto --norsrc "$stage/$name" "$dev/$name"
echo "$PWD/$dev/$name"
