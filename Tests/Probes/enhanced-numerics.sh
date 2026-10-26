#!/bin/zsh
# Enhanced spectrogram numerics (Phase 4, batch D): builds the analysis sources with one optimisation setting, runs
# Tests/Probes/EnhancedNumerics.swift and writes the Enhanced columns of fixed signals to .build/numerics/<name>/dump.
# Compare two variants with: python3 Tests/Probes/compare-numerics.py .build/numerics/<a>/dump .build/numerics/<b>/dump
#   enhanced-numerics.sh <name> <swift optimisation flag> [C optimisation flags...]
#   e.g.  enhanced-numerics.sh O -O -O2     enhanced-numerics.sh Onone -Onone -O0
set -euo pipefail
cd "${0:A:h:h:h}"
name=${1:?variant name}
swift_flag=${2:?swift optimisation flag, e.g. -O or -Onone}
shift 2
c_flags=("$@")
[[ ${#c_flags[@]} -gt 0 ]] || c_flags=(-O2)
out=.build/numerics/$name
rm -rf "$out"; mkdir -p "$out/dump"
sources=("${(@f)$(python3 Tests/Probes/analysis-sources.py)}")
clang -std=c11 "${c_flags[@]}" -I Sources/AnalysisKernels/include -c Sources/AnalysisKernels/AnalysisKernels.c -o "$out/AnalysisKernels.o"
clang -std=c11 "${c_flags[@]}" -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -c Sources/AudioRing/AudioRing.c -o "$out/AudioRing.o"
cp Tests/Probes/EnhancedNumerics.swift "$out/main.swift"
swiftc "$swift_flag" -swift-version 5 -module-cache-path "$out/modules" -module-name AnalysisCore -package-name Auraliscope \
    -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -framework AudioToolbox \
    "${sources[@]}" "$out/main.swift" "$out/AnalysisKernels.o" "$out/AudioRing.o" -o "$out/EnhancedNumerics"
"$out/EnhancedNumerics" "$out/dump"
