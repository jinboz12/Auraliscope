#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/core-checks
clang -std=c11 -O2 -I Sources/AudioRing/include -c Sources/AudioRing/AudioRing.c -o .build/core-checks/AudioRing.o
swiftc -O -swift-version 5 -module-cache-path .build/core-checks/modules \
    -I Sources/AudioRing/include Sources/Auraliscope/SpectrumAnalyzer.swift Sources/Auraliscope/LoudnessAnalyzer.swift Sources/Auraliscope/SpectrogramHistory.swift Sources/Auraliscope/DampedDisplayState.swift Sources/Auraliscope/MeterScale.swift Sources/Auraliscope/SpeakerLayout.swift \
    Sources/Auraliscope/FormatDetector.swift Sources/Auraliscope/VUScale.swift Sources/Auraliscope/WaveformEnvelope.swift Sources/Auraliscope/MinMaxPyramid.swift Sources/Auraliscope/MeterPipeline.swift Sources/Auraliscope/Localizer.swift \
    Tests/AuraliscopeTests/CoreTests.swift .build/core-checks/AudioRing.o -o .build/core-checks/CoreChecks
.build/core-checks/CoreChecks
# String tables against the code and the language policy (see Sources/Auraliscope/Localizer.swift).
python3 scripts/check-localization.py
