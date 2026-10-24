#!/bin/zsh
# Builds Steinberg's VST3 validator (public.sdk/samples/vst-hosting/validator) from the fetched SDK, arm64 only,
# into .build/bridge/validator/validator. Used by validate-plugins.sh.
set -euo pipefail
cd "${0:A:h:h:h}"
[[ -d Bridge/ThirdParty/vst3sdk/public.sdk ]] || Bridge/scripts/fetch-sdks.sh
vst3=Bridge/ThirdParty/vst3sdk
out=.build/bridge/validator
mkdir -p "$out/obj"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
flags=(-isysroot "$sdk" -mmacosx-version-min=11.0 -arch arm64 -O1 -g0 -std=c++17 -DRELEASE=1 -I "$vst3" -w)
sources=(
    ${vst3}/public.sdk/samples/vst-hosting/validator/source/*.cpp(N)
    ${vst3}/public.sdk/source/vst/testsuite/**/*.cpp(N)
    ${vst3}/public.sdk/source/vst/hosting/{connectionproxy,eventlist,hostclasses,module,parameterchanges,pluginterfacesupport,plugprovider,processdata}.cpp
    ${vst3}/public.sdk/source/vst/hosting/module_mac.mm
    ${vst3}/public.sdk/source/vst/moduleinfo/moduleinfoparser.cpp
    ${vst3}/public.sdk/source/vst/utility/{stringconvert,testing,systemtime}.cpp
    ${vst3}/public.sdk/source/vst/{vstpresetfile,vstinitiids}.cpp
    ${vst3}/public.sdk/source/main/moduleinit.cpp
    ${vst3}/public.sdk/source/common/{commoniids,commonstringconvert,memorystream,readfile}.cpp
    ${vst3}/public.sdk/source/common/threadchecker_mac.mm
    ${vst3}/base/source/{baseiids,fbuffer,fdebug,fdynlib,fobject,fstreamer,fstring,timer,updatehandler}.cpp
    ${vst3}/base/thread/source/{flock,fcondition}.cpp
    ${vst3}/pluginterfaces/base/{conststringtable,coreiids,funknown,ustring}.cpp
)
typeset -a objects pids
for source in $sources; do
    object="$out/obj/${${source#$vst3/}//\//_}.o"
    objects+=("$object")
    if [[ ! -f "$object" || "$source" -nt "$object" ]]; then
        clang++ -c "$source" -o "$object" "${flags[@]}" $([[ $source == *.mm ]] && echo -fobjc-arc) &
        pids+=($!)
    fi
done
failed=0; for pid in $pids; do wait $pid || failed=1; done; (( ! failed ))
clang++ -isysroot "$sdk" -arch arm64 $objects -o "$out/validator" -framework Cocoa -framework CoreFoundation -framework CoreAudio
echo "$out/validator"
