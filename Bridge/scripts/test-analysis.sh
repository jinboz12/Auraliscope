#!/bin/zsh
# Builds and runs the Labs analysis checks (Bridge/Tests/AnalysisBreakTests.swift): break marks in the capture
# ring, what each analyzer does at a break, and the rules for finding the saved DAW plugin insert again. Compiles
# the same analysis sources as scripts/test.sh (which stays as the release line has it), plus BridgeRestoration.
set -euo pipefail
cd "${0:A:h:h:h}"
out=.build/bridge/analysis-tests
mkdir -p "$out"
cache_key="$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12)"
clang -std=c11 -O2 -I Sources/AudioRing/include -c Sources/AudioRing/AudioRing.c -o "$out/AudioRing.o"
clang -std=c11 -O2 -I Sources/AudioRing/include -c Sources/AudioRing/CaptureCallback.c -o "$out/CaptureCallback.o"
a=Sources/Auraliscope
swiftc -O -swift-version 5 -module-cache-path "$out/modules-$cache_key" -I Sources/AudioRing/include -framework AudioToolbox \
    $a/SpectrumAnalyzer.swift $a/LoudnessAnalyzer.swift $a/SpectrogramHistory.swift $a/DampedDisplayState.swift \
    $a/MeterScale.swift $a/SpeakerLayout.swift $a/FormatDetector.swift $a/VUScale.swift $a/WaveformEnvelope.swift \
    $a/MinMaxPyramid.swift $a/MeterPipeline.swift $a/Localizer.swift $a/SystemMenus.swift $a/BridgeRestoration.swift \
    Bridge/Tests/AnalysisBreakTests.swift "$out/AudioRing.o" "$out/CaptureCallback.o" -o "$out/AnalysisBreakTests"
"$out/AnalysisBreakTests"
