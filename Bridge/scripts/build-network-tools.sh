#!/bin/zsh
# Builds the network test tools into .build/bridge/tools: NetworkPair (the plugin's pairing code, from the command line)
# and BridgeNetworkProbe (a network display on the Mac, built on AuraliscopeDisplayCore like the iPad app).
set -euo pipefail
cd "${0:A:h:h:h}"
out=.build/bridge/tools
mkdir -p "$out"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
clang -isysroot "$sdk" -arch arm64 -mmacosx-version-min=11.0 -O2 -std=c11 -Wall -I Sources/BridgeTransport/include \
    -c Sources/BridgeTransport/BridgeDiscovery.c -o "$out/BridgeDiscovery-net.o"
clang++ -isysroot "$sdk" -arch arm64 -mmacosx-version-min=11.0 -O2 -std=c++17 -Wall -Wno-unused-parameter \
    -I Sources/BridgeTransport/include -I Bridge/Plugin/Core \
    Bridge/Tools/NetworkPair.cpp Bridge/Plugin/Core/BridgeRemote.cpp Bridge/Plugin/Core/BridgeNetLink.cpp "$out/BridgeDiscovery-net.o" \
    -framework CoreFoundation -framework Network -framework Security -framework SystemConfiguration -o "$out/NetworkPair"
swift build -c release --product BridgeNetworkProbe >/dev/null
cp "$(swift build -c release --show-bin-path)/BridgeNetworkProbe" "$out/BridgeNetworkProbe"
echo "$out/NetworkPair"
echo "$out/BridgeNetworkProbe"
