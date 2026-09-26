#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/core-checks
clang -std=c11 -O2 -I Sources/AudioRing/include -c Sources/AudioRing/AudioRing.c -o .build/core-checks/AudioRing.o
sources=(Sources/Auraliscope/SpectrumAnalyzer.swift Sources/Auraliscope/LoudnessAnalyzer.swift Sources/Auraliscope/SpectrogramHistory.swift Sources/Auraliscope/DampedDisplayState.swift Sources/Auraliscope/MeterScale.swift Sources/Auraliscope/SpeakerLayout.swift
    Sources/Auraliscope/FormatDetector.swift Sources/Auraliscope/VUScale.swift Sources/Auraliscope/WaveformEnvelope.swift Sources/Auraliscope/MinMaxPyramid.swift Sources/Auraliscope/MeterPipeline.swift Sources/Auraliscope/Localizer.swift Sources/Auraliscope/SystemMenus.swift
    Tests/AuraliscopeTests/CoreTests.swift .build/core-checks/AudioRing.o)
compile() {
    swiftc -O -swift-version 5 -module-cache-path .build/core-checks/modules -I Sources/AudioRing/include "$@" \
        "${sources[@]}" -o .build/core-checks/CoreChecks
}
# The Command Line Tools can ship a default SDK whose Swift interface was built by a newer compiler than the one
# installed; fall back to the other installed SDKs, newest first, until one compiles.
if ! compile 2>.build/core-checks/compile.log; then
    built=0
    for sdk in $(ls -d "$(xcode-select -p)"/SDKs/MacOSX[0-9]*.sdk(N) | sort -rV); do
        if compile -sdk "$sdk" 2>>.build/core-checks/compile.log; then built=1; echo "core checks built with $(basename "$sdk")"; break; fi
    done
    if (( ! built )); then cat .build/core-checks/compile.log >&2; exit 1; fi
fi
.build/core-checks/CoreChecks
# String tables against the code and the language policy (see Sources/Auraliscope/Localizer.swift).
python3 scripts/check-localization.py
