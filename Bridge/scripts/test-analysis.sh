#!/bin/zsh
# Builds and runs the Labs analysis checks (Bridge/Tests/AnalysisBreakTests.swift, ResultTests.swift): break marks
# in the capture ring, what each analyzer does at a break, the rules for finding the saved DAW plugin insert again,
# and plugin-side analysis and result delivery (StreamAnalyzer against the desktop pipeline, the RESULT encoding,
# the display-side assembly). Compiles the same analysis sources as scripts/test.sh, plus the Bridge's.
set -euo pipefail
cd "${0:A:h:h:h}"
out=.build/bridge/analysis-tests
mkdir -p "$out"
cache_key="$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12)"
clang -std=c11 -O2 -I Sources/AnalysisKernels/include -c Sources/AnalysisKernels/AnalysisKernels.c -o "$out/AnalysisKernels.o"
clang -std=c11 -O2 -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -c Sources/AudioRing/AudioRing.c -o "$out/AudioRing.o"
clang -std=c11 -O2 -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -c Sources/AudioRing/CaptureCallback.c -o "$out/CaptureCallback.o"
a=Sources/Auraliscope
swiftc -O -swift-version 5 -module-cache-path "$out/modules-$cache_key" -module-name AnalysisCore -package-name Auraliscope -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -framework AudioToolbox \
    Sources/AnalysisCore/LogFrequencyAxis.swift Sources/AnalysisCore/MultiFFTConfiguration.swift Sources/AnalysisCore/MultiFFTAnalyzer.swift Sources/AnalysisCore/SpectrumAnalyzer.swift Sources/AnalysisCore/SpectrogramAnalyzer.swift Sources/AnalysisCore/ReassignedSpectrogram.swift Sources/AnalysisCore/SpectralWindow.swift Sources/AnalysisCore/LoudnessAnalyzer.swift Sources/AnalysisCore/SignalHealth.swift $a/SpectrogramHistory.swift $a/DampedDisplayState.swift \
    $a/MeterScale.swift $a/SpeakerLayout.swift Sources/AnalysisCore/SpatialField.swift Sources/AnalysisCore/SpatialGeometry.swift Sources/AnalysisCore/SpatialObservations.swift Sources/AnalysisCore/SpatialConfigWire.swift Sources/AnalysisCore/Role.swift $a/FormatMode.swift $a/StereoBandLabels.swift Sources/AnalysisCore/FormatDetector.swift $a/VUScale.swift Sources/AnalysisCore/WaveformEnvelope.swift \
    $a/MinMaxPyramid.swift Sources/AnalysisCore/MeterPipeline.swift $a/Localizer.swift $a/SystemMenus.swift $a/BridgeRestoration.swift \
    Sources/AnalysisCore/StreamAnalyzer.swift Sources/AnalysisCore/ResultProtocol.swift Sources/AnalysisCore/ResultAssembler.swift \
    Bridge/Tests/ResultTests.swift Bridge/Tests/AnalysisBreakTests.swift "$out/AnalysisKernels.o" "$out/AudioRing.o" "$out/CaptureCallback.o" -o "$out/AnalysisBreakTests"
"$out/AnalysisBreakTests"
