#!/bin/zsh
# Builds Auraliscope Bridge as a VST3 and an AUv2 bundle (universal: arm64 + x86_64), signs them ad hoc and puts
# them in experimental-dist/Auraliscope Labs <label> build <n>/. Nothing is installed; see install-plugins.sh.
#
# Plain clang, no CMake: the VST3 SDK and AudioUnitSDK sources the wrappers need are compiled directly.
set -euo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/prototype-version.sh
[[ -d Bridge/ThirdParty/vst3sdk/public.sdk && -d Bridge/ThirdParty/AudioUnitSDK/src ]] || Bridge/scripts/fetch-sdks.sh

obj=.build/bridge/obj
mkdir -p "$obj"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
vst3=Bridge/ThirdParty/vst3sdk
ausdk=Bridge/ThirdParty/AudioUnitSDK
arch=(-arch arm64 -arch x86_64)
base=(-isysroot "$sdk" -mmacosx-version-min=11.0 $arch -O2 -g0 -fvisibility=hidden -fvisibility-inlines-hidden
      -Wall -Wno-unused-parameter -DABR_PLUGIN_VERSION="\"$ABR_LABEL build $ABR_BUILD\"")
ours=(-I Sources/BridgeTransport/include -I Bridge/Plugin/Core -I Bridge/Plugin/Editor -I Bridge/Plugin/AU)
vst3_flags=(-std=c++17 -DRELEASE=1 -I "$vst3" -Wno-deprecated-declarations -Wno-unknown-pragmas -Wno-unused-variable
            -Wno-unused-function -Wno-overloaded-virtual -Wno-extra-tokens)
au_flags=(-std=c++20 -I "$ausdk/include")
editor_vst3=(-DABR_EDITOR_CLASS=AuraliscopeBridgeEditorVST3_${ABR_BUILD})
editor_au=(-DABR_EDITOR_CLASS=AuraliscopeBridgeEditorAU_${ABR_BUILD} -DABR_AU_VIEW_FACTORY=AuraliscopeBridgeAUViewFactory_${ABR_BUILD})

# compile <object> <source> <flags…>: rebuilds when the source or any of our headers is newer.
typeset -a objects_vst3 objects_au pids
newest_header="$(ls -t Bridge/Plugin/*/*.h Sources/BridgeTransport/include/*.h | head -1)"
compile() {
    local object="$obj/$1" source="$2"; shift 2
    mkdir -p "${object:h}"
    if [[ ! -f "$object" || "$source" -nt "$object" || "$newest_header" -nt "$object" || "$0" -nt "$object" ]]; then
        clang++ -c "$source" -o "$object" "${base[@]}" "$@" &
        pids+=($!)
    fi
}
wait_all() { local failed=0; for pid in $pids; do wait $pid || failed=1; done; pids=(); (( ! failed )); }

vst3_sources=(
    base/source/baseiids.cpp base/source/fbuffer.cpp base/source/fdebug.cpp base/source/fobject.cpp
    base/source/fstreamer.cpp base/source/fstring.cpp base/source/updatehandler.cpp base/source/timer.cpp
    base/thread/source/flock.cpp base/thread/source/fcondition.cpp
    pluginterfaces/base/conststringtable.cpp pluginterfaces/base/coreiids.cpp pluginterfaces/base/funknown.cpp
    pluginterfaces/base/ustring.cpp
    public.sdk/source/common/commoniids.cpp public.sdk/source/common/pluginview.cpp
    public.sdk/source/common/commonstringconvert.cpp
    public.sdk/source/main/pluginfactory.cpp public.sdk/source/main/macmain.cpp public.sdk/source/main/moduleinit.cpp
    public.sdk/source/vst/vstsinglecomponenteffect.cpp public.sdk/source/vst/vstcomponentbase.cpp
    public.sdk/source/vst/vstbus.cpp public.sdk/source/vst/vstparameters.cpp  # vstsinglecomponenteffect.cpp includes vsteditcontroller.cpp
    public.sdk/source/vst/vstinitiids.cpp public.sdk/source/vst/utility/stringconvert.cpp
)
for source in $vst3_sources; do
    compile "sdk-vst3/${source//\//_}.o" "$vst3/$source" $vst3_flags
    objects_vst3+=("$obj/sdk-vst3/${source//\//_}.o")
done
for source in AUBase AUBuffer AUBufferAllocator AUEffectBase AUInputElement AUOutputElement AUPlugInDispatch AUScopeElement ComponentBase; do
    compile "sdk-au/$source.o" "$ausdk/src/AudioUnitSDK/$source.cpp" $au_flags
    objects_au+=("$obj/sdk-au/$source.o")
done
# Network discovery (C): compiled once, linked into both formats.
if [[ ! -f "$obj/common/BridgeDiscovery.o" || Sources/BridgeTransport/BridgeDiscovery.c -nt "$obj/common/BridgeDiscovery.o" ]]; then
    mkdir -p "$obj/common"
    clang -c Sources/BridgeTransport/BridgeDiscovery.c -o "$obj/common/BridgeDiscovery.o" -isysroot "$sdk" \
        -mmacosx-version-min=11.0 $arch -O2 -std=c11 -fvisibility=hidden -Wall -I Sources/BridgeTransport/include
fi
objects_vst3+=("$obj/common/BridgeDiscovery.o")
objects_au+=("$obj/common/BridgeDiscovery.o")
for part in BridgeCore BridgeSender; do
    compile "common/$part.o" "Bridge/Plugin/Core/$part.cpp" -std=c++17 $ours
    objects_vst3+=("$obj/common/$part.o")
    objects_au+=("$obj/common/$part.o")
done
compile vst3/BridgeVST3.o Bridge/Plugin/VST3/BridgeVST3.cpp $vst3_flags $ours
compile vst3/BridgeEditor.o Bridge/Plugin/Editor/BridgeEditor.mm -std=c++17 -fobjc-arc $ours $editor_vst3
compile au/BridgeAU.o Bridge/Plugin/AU/BridgeAU.cpp $au_flags $ours $editor_au
compile au/BridgeAUView.o Bridge/Plugin/AU/BridgeAUView.mm -std=c++20 -fobjc-arc $au_flags $ours $editor_au
compile au/BridgeEditor.o Bridge/Plugin/Editor/BridgeEditor.mm -std=c++17 -fobjc-arc $ours $editor_au
objects_vst3+=("$obj/vst3/BridgeVST3.o" "$obj/vst3/BridgeEditor.o")
objects_au+=("$obj/au/BridgeAU.o" "$obj/au/BridgeAUView.o" "$obj/au/BridgeEditor.o")
wait_all

# Assemble and sign on the local disk: the exFAT volume adds "._" files that invalidate signatures.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
link_flags=(-isysroot "$sdk" -mmacosx-version-min=11.0 $arch -bundle -dead_strip
            -framework Cocoa -framework AudioToolbox -framework AudioUnit -framework CoreFoundation)
bundle() {  # bundle <name.ext> <plist> <exports> <objects…>
    local name="$1" plist="$2" exports="$3"; shift 3
    local contents="$stage/$name/Contents"
    mkdir -p "$contents/MacOS" "$contents/Resources"
    sed -e "s/@VERSION@/$ABR_VERSION/g" -e "s/@BUILD@/$ABR_BUILD/g" -e "s/@AU_VERSION@/$ABR_AU_VERSION/g" "$plist" > "$contents/Info.plist"
    plutil -lint "$contents/Info.plist" >/dev/null
    printf 'BNDL????' > "$contents/PkgInfo"
    clang++ "${link_flags[@]}" -exported_symbols_list "$exports" "$@" -o "$contents/MacOS/Auraliscope Bridge"
    cp Bridge/THIRD_PARTY_NOTICES.md "$contents/Resources/"
    find "$stage/$name" -name '._*' -delete
    xattr -cr "$stage/$name"
    codesign --force --sign - --timestamp=none "$stage/$name"
    codesign --verify --strict "$stage/$name"
}
printf '_BridgeAUFactory\n' > "$stage/au.exp"
bundle "Auraliscope Bridge.vst3" Bridge/Plugin/Resources/VST3-Info.plist "$vst3/public.sdk/source/main/macexport.exp" $objects_vst3
bundle "Auraliscope Bridge.component" Bridge/Plugin/Resources/AU-Info.plist "$stage/au.exp" $objects_au

mkdir -p "$ABR_DIST"
for name in "Auraliscope Bridge.vst3" "Auraliscope Bridge.component"; do
    rm -rf "$ABR_DIST/$name"
    ditto --norsrc "$stage/$name" "$ABR_DIST/$name"
done
echo "$ABR_DIST/Auraliscope Bridge.vst3"
echo "$ABR_DIST/Auraliscope Bridge.component"
