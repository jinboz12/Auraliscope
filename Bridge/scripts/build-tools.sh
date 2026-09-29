#!/bin/zsh
# Builds the test tools into .build/bridge/tools: HostHarness (loads the real VST3/AU binaries) and ReceiverProbe
# (a receiver without the app). The harness reuses the VST3 hosting objects of build-validator.sh.
set -euo pipefail
cd "${0:A:h:h:h}"
Bridge/scripts/build-validator.sh >/dev/null
out=.build/bridge/tools
mkdir -p "$out"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
vst3=Bridge/ThirdParty/vst3sdk
hosting=(.build/bridge/validator/obj/*.o(N))
hosting=(${hosting:#*validator_source_*})
hosting=(${hosting:#*testsuite_*})
clang++ -isysroot "$sdk" -arch arm64 -mmacosx-version-min=11.0 -O2 -std=c++17 -fobjc-arc -DRELEASE=1 -I "$vst3" -w \
    Bridge/Tools/HostHarness.mm $hosting -o "$out/HostHarness" \
    -framework Cocoa -framework AudioToolbox -framework AudioUnit -framework CoreAudio -framework CoreFoundation
clang -isysroot "$sdk" -arch arm64 -O2 -std=c11 -Wall -I Sources/BridgeTransport/include \
    Bridge/Tools/ReceiverProbe.c Sources/BridgeTransport/BridgeServer.c -o "$out/ReceiverProbe"
clang -isysroot "$sdk" -arch arm64 -O2 -std=c11 -Wall -I Sources/BridgeTransport/include \
    Bridge/Tools/DiscoveryBeacon.c Sources/BridgeTransport/BridgeDiscovery.c -o "$out/DiscoveryBeacon"
echo "$out/HostHarness"
echo "$out/ReceiverProbe"
