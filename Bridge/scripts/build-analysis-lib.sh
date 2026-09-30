#!/bin/zsh
# Compiles the shared analysis core (Sources/AnalysisCore, Sources/AnalysisKernels) and the plugins' C entry points
# (Bridge/Plugin/Analysis) into one universal static library for one plugin format.
#
#   build-analysis-lib.sh <SwiftModuleName> <output.a>
#
# Each format gets its own Swift module name (AuraliscopeBridgeAnalysisVST3, …AU): Swift type names are mangled
# with the module, so a host that loads both plugins never finds two classes of the same name. The Swift runtime is
# the one in macOS (ABI-stable since 10.14.4); the library links against it, it is not bundled.
set -euo pipefail
cd "${0:A:h:h:h}"
module="$1" output="$2"
work=".build/bridge/analysis/$module"
mkdir -p "$work" "${output:h}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
minimum=11.0
swift_sources=(Sources/AnalysisCore/*.swift Bridge/Plugin/Analysis/BridgeAnalysisABI.swift)
newest="$(ls -t $swift_sources Sources/AnalysisKernels/AnalysisKernels.c Sources/AnalysisKernels/include/*.h Bridge/Plugin/Analysis/include/* "$0" | head -1)"
if [[ -f "$output" && "$output" -nt "$newest" ]]; then echo "$output"; exit 0; fi
archives=()
for arch in arm64 x86_64; do
    swiftc -parse-as-library -wmo -O -emit-object -module-name "$module" -package-name Auraliscope -swift-version 5 \
        -target "$arch-apple-macos$minimum" -sdk "$sdk" -module-cache-path "$work/modules" \
        -I Sources/AnalysisKernels/include -I Bridge/Plugin/Analysis/include \
        $swift_sources -o "$work/$arch-swift.o"
    clang -c Sources/AnalysisKernels/AnalysisKernels.c -o "$work/$arch-kernels.o" -arch "$arch" -isysroot "$sdk" \
        -mmacosx-version-min=$minimum -O2 -std=c11 -fvisibility=hidden -I Sources/AnalysisKernels/include
    rm -f "$work/$arch.a"
    libtool -static -o "$work/$arch.a" "$work/$arch-swift.o" "$work/$arch-kernels.o" 2>/dev/null
    archives+=("$work/$arch.a")
done
lipo -create $archives -output "$output"
echo "$output"
