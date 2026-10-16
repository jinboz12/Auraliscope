#!/bin/zsh
# Builds and runs the transport tests: the plugin core (with its analysis thread and the shared analysis core) and
# the receiver in one process, over a private socket.
set -euo pipefail
cd "${0:A:h:h:h}"
out=.build/bridge/tests
mkdir -p "$out"
# ABR_SANITIZE=thread (or address) instruments the C and C++ parts, the receiver included. The Swift analysis core
# is linked as built for the plugins (not instrumented).
sanitize=(-fsanitize=${ABR_SANITIZE:-undefined})
Bridge/scripts/build-analysis-lib.sh AuraliscopeBridgeAnalysisTest .build/bridge/analysis/test.a >/dev/null
sdk="$(xcrun --sdk macosx --show-sdk-path)"
swift_libs=(-L/usr/lib/swift -L"$sdk/usr/lib/swift" -L"${$(xcrun -f swiftc):h:h}/lib/swift/macosx")
clang -std=c11 -O2 -g -Wall -Wextra $sanitize -I Sources/BridgeTransport/include -c Sources/BridgeTransport/BridgeServer.c -o "$out/BridgeServer.o"
clang -std=c11 -O2 -g -Wall -Wextra $sanitize -I Sources/BridgeTransport/include -c Sources/BridgeTransport/BridgeDiscovery.c -o "$out/BridgeDiscovery.o"
clang++ -std=c++17 -O2 -g -Wall -Wextra -Wno-unused-parameter $sanitize \
    -I Sources/BridgeTransport/include -I Bridge/Plugin/Core -I Bridge/Plugin/Analysis/include -framework CoreFoundation \
    -framework Accelerate $swift_libs \
    Bridge/Plugin/Core/BridgeCore.cpp Bridge/Plugin/Core/BridgeSender.cpp Bridge/Plugin/Core/BridgeAnalysisHub.cpp \
    Bridge/Tests/TransportTests.cpp "$out/BridgeServer.o" "$out/BridgeDiscovery.o" .build/bridge/analysis/test.a \
    -o "$out/TransportTests"
"$out/TransportTests"
