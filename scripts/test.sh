#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
sanitizer="${1:-}"
case "$sanitizer" in
    ""|address|thread) ;;
    *) echo 'usage: scripts/test.sh [address|thread]' >&2; exit 2 ;;
esac
check_dir=".build/core-checks${sanitizer:+-$sanitizer}"
mkdir -p "$check_dir"
c_flags=()
swift_flags=()
if [[ -n "$sanitizer" ]]; then
    c_flags=(-fsanitize="$sanitizer")
    swift_flags=(-sanitize="$sanitizer")
fi
# Clang's precompiled modules embed their absolute cache path. A checkout copied to another drive must not
# reuse modules from its old location; give each checkout location its own cache without discarding others.
cache_key="$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12)"
module_cache="$check_dir/modules-$cache_key"
clang -std=c11 -O2 "${c_flags[@]}" -I Sources/AnalysisKernels/include -c Sources/AnalysisKernels/AnalysisKernels.c -o "$check_dir/AnalysisKernels.o"
clang -std=c11 -O2 "${c_flags[@]}" -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -c Sources/AudioRing/AudioRing.c -o "$check_dir/AudioRing.o"
clang -std=c11 -O2 "${c_flags[@]}" -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -c Sources/AudioRing/CaptureCallback.c -o "$check_dir/CaptureCallback.o"
sources=(Sources/AnalysisCore/SpectrumAnalyzer.swift Sources/AnalysisCore/LoudnessAnalyzer.swift Sources/Auraliscope/SpectrogramHistory.swift Sources/Auraliscope/DampedDisplayState.swift Sources/Auraliscope/MeterScale.swift Sources/Auraliscope/SpeakerLayout.swift Sources/AnalysisCore/Role.swift Sources/Auraliscope/FormatMode.swift Sources/Auraliscope/StereoBandLabels.swift
    Sources/AnalysisCore/FormatDetector.swift Sources/Auraliscope/VUScale.swift Sources/AnalysisCore/WaveformEnvelope.swift Sources/Auraliscope/MinMaxPyramid.swift Sources/AnalysisCore/MeterPipeline.swift Sources/Auraliscope/Localizer.swift Sources/Auraliscope/SystemMenus.swift
    Tests/AuraliscopeTests/CoreTests.swift "$check_dir/AnalysisKernels.o" "$check_dir/AudioRing.o" "$check_dir/CaptureCallback.o")
compile() {
    swiftc -O -swift-version 5 "${swift_flags[@]}" -module-cache-path "$module_cache" -module-name AnalysisCore -package-name Auraliscope -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -framework AudioToolbox "$@" \
        "${sources[@]}" -o "$check_dir/CoreChecks"
}
# The Command Line Tools can ship a default SDK whose Swift interface was built by a newer compiler than the one
# installed; fall back to the other installed SDKs, newest first, until one compiles.
if ! compile 2>"$check_dir/compile.log"; then
    # A source error needs fixing, not recompilation against every SDK on the machine.
    if ! rg -q 'SDK is not supported|module cache path|could not build|no such module' "$check_dir/compile.log"; then
        cat "$check_dir/compile.log" >&2
        exit 1
    fi
    built=0
    for sdk in $(ls -d "$(xcode-select -p)"/SDKs/MacOSX[0-9]*.sdk(N) | sort -rV); do
        if compile -sdk "$sdk" 2>>"$check_dir/compile.log"; then built=1; echo "core checks built with $(basename "$sdk")"; break; fi
    done
    if (( ! built )); then cat "$check_dir/compile.log" >&2; exit 1; fi
fi
"$check_dir/CoreChecks"
# String tables against the code and the language policy (see Sources/Auraliscope/Localizer.swift).
python3 scripts/check-localization.py
