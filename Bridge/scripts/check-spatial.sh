#!/bin/zsh
# Builds and runs SpatialCheck (Bridge/Tools/SpatialCheck/main.swift): the spatial observations of the production
# analysis against an independent double-precision reference on controlled fixtures, the response to a step and a pan
# with the standard and multi-resolution windows, and three reductions compared. Compiles the same analysis sources as
# Bridge/scripts/test-analysis.sh.
#
#   check-spatial.sh [--export <dir>] [--only <fixture substring>]
set -euo pipefail
cd "${0:A:h:h:h}"
out=.build/bridge/spatial-check
mkdir -p "$out"
cache_key="$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12)"
clang -std=c11 -O2 -I Sources/AnalysisKernels/include -c Sources/AnalysisKernels/AnalysisKernels.c -o "$out/AnalysisKernels.o"
clang -std=c11 -O2 -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -c Sources/AudioRing/AudioRing.c -o "$out/AudioRing.o"
a=Sources/Auraliscope
swiftc -O -swift-version 5 -module-cache-path "$out/modules-$cache_key" -module-name AnalysisCore -package-name Auraliscope \
    -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -framework AudioToolbox \
    Sources/AnalysisCore/MultiFFTConfiguration.swift Sources/AnalysisCore/MultiFFTAnalyzer.swift Sources/AnalysisCore/SpectrumAnalyzer.swift Sources/AnalysisCore/SpectrogramAnalyzer.swift Sources/AnalysisCore/ReassignedSpectrogram.swift \
    Sources/AnalysisCore/SpectralWindow.swift Sources/AnalysisCore/LoudnessAnalyzer.swift Sources/AnalysisCore/SignalHealth.swift \
    Sources/AnalysisCore/SpatialField.swift Sources/AnalysisCore/SpatialGeometry.swift Sources/AnalysisCore/SpatialObservations.swift \
    Sources/AnalysisCore/Role.swift Sources/AnalysisCore/FormatDetector.swift Sources/AnalysisCore/WaveformEnvelope.swift \
    Sources/AnalysisCore/MeterPipeline.swift $a/StereoBandLabels.swift $a/FormatMode.swift $a/Localizer.swift $a/SystemMenus.swift \
    $a/SpectrogramHistory.swift $a/DampedDisplayState.swift $a/MeterScale.swift $a/SpeakerLayout.swift $a/VUScale.swift $a/MinMaxPyramid.swift \
    Bridge/Tools/SpatialCheck/main.swift "$out/AnalysisKernels.o" "$out/AudioRing.o" -o "$out/SpatialCheck"
"$out/SpatialCheck" "$@"
