#!/bin/zsh
# Builds and runs the transport tests (plugin core + receiver in one process, private socket).
set -euo pipefail
cd "${0:A:h:h:h}"
out=.build/bridge/tests
mkdir -p "$out"
clang -std=c11 -O2 -Wall -Wextra -I Sources/BridgeTransport/include -c Sources/BridgeTransport/BridgeServer.c -o "$out/BridgeServer.o"
clang -std=c11 -O2 -Wall -Wextra -I Sources/BridgeTransport/include -c Sources/BridgeTransport/BridgeDiscovery.c -o "$out/BridgeDiscovery.o"
clang++ -std=c++17 -O2 -Wall -Wextra -fsanitize=${ABR_SANITIZE:-undefined} \
    -I Sources/BridgeTransport/include -I Bridge/Plugin/Core \
    Bridge/Plugin/Core/BridgeCore.cpp Bridge/Plugin/Core/BridgeSender.cpp Bridge/Tests/TransportTests.cpp "$out/BridgeServer.o" "$out/BridgeDiscovery.o" \
    -o "$out/TransportTests"
"$out/TransportTests"
