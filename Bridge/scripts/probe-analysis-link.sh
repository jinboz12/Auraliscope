#!/bin/zsh
# Feasibility check for plugin-side analysis: builds the shared analysis core as each format's static library,
# links each into a loadable bundle (standing in for the VST3 and the AU binary), loads both into one process, runs
# them at once on background threads, and reports cost, results and any Objective-C class clash.
#
#   probe-analysis-link.sh [seconds] [rate] [channels]
set -euo pipefail
cd "${0:A:h:h:h}"
seconds="${1:-20}" rate="${2:-48000}" channels="${3:-2}"
out=.build/bridge/probe
mkdir -p "$out"
Bridge/scripts/build-analysis-lib.sh AuraliscopeBridgeAnalysisVST3 .build/bridge/analysis/vst3.a >/dev/null
Bridge/scripts/build-analysis-lib.sh AuraliscopeBridgeAnalysisAU .build/bridge/analysis/au.a >/dev/null
sdk="$(xcrun --sdk macosx --show-sdk-path)"
toolchain="${$(xcrun -f swiftc):h:h}/lib/swift/macosx"
for format in vst3 au; do
    clang++ -std=c++17 -O2 -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -isysroot "$sdk" \
        -DABR_PROBE_LIBRARY -I Bridge/Plugin/Analysis/include Bridge/Tools/AnalysisLinkProbe.cpp \
        ".build/bridge/analysis/$format.a" -L/usr/lib/swift -L"$sdk/usr/lib/swift" -L"$toolchain" -o "$out/$format.bundle"
done
clang++ -std=c++17 -O2 -I Bridge/Plugin/Analysis/include Bridge/Tools/AnalysisLinkProbe.cpp -o "$out/AnalysisLinkProbe"
echo "Linked libraries of one bundle:"
otool -L "$out/vst3.bundle" | tail -n +2
"$out/AnalysisLinkProbe" "$out/vst3.bundle" "$out/au.bundle" "$seconds" "$rate" "$channels" 2>"$out/stderr.txt"
if grep -q "implemented in both" "$out/stderr.txt"; then
    echo "FAIL: Objective-C class clash:"; cat "$out/stderr.txt"; exit 1
fi
[[ -s "$out/stderr.txt" ]] && { echo "stderr:"; cat "$out/stderr.txt"; }
echo "PASS: both analysis copies loaded and ran in one process without a class clash"
