#!/bin/zsh
# Builds the test tools into .build/bridge/tools: HostHarness (loads the real VST3/AU binaries), ResultProbe (a
# receiver of analysis results without the app, with the shared analysis core as its reference) and
# DiscoveryBeacon. The harness reuses the VST3 hosting objects of build-validator.sh.
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
    -c Sources/BridgeTransport/BridgeServer.c -o "$out/BridgeServer.o"
clang -isysroot "$sdk" -arch arm64 -O2 -std=c11 -I Sources/AnalysisKernels/include \
    -c Sources/AnalysisKernels/AnalysisKernels.c -o "$out/AnalysisKernels.o"
swiftc -O -swift-version 5 -module-name ResultProbe -package-name Auraliscope -module-cache-path "$out/modules" \
    -I Sources/BridgeTransport/include -I Sources/AnalysisKernels/include \
    Bridge/Tools/ResultProbe/main.swift Sources/AnalysisCore/*.swift "$out/BridgeServer.o" "$out/AnalysisKernels.o" \
    -o "$out/ResultProbe"
clang -isysroot "$sdk" -arch arm64 -O2 -std=c11 -Wall -I Sources/BridgeTransport/include \
    Bridge/Tools/DiscoveryBeacon.c Sources/BridgeTransport/BridgeDiscovery.c -o "$out/DiscoveryBeacon"
echo "$out/HostHarness"
echo "$out/ResultProbe"
