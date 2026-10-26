#!/bin/zsh
# Builds and runs Tests/Probes/CaptureRenderProbe.swift (P0-1) on one input device: a matched-rate control, then two
# runs with the capture format's rate apart from the device's. Pick an input nobody else is using (an idle loopback
# such as a Pro Tools Audio Bridge); the probe only reads it and changes nothing outside this process.
set -euo pipefail
cd "${0:A:h:h:h}"
out=.build/probes
mkdir -p "$out"
clang -std=c11 -O2 -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -c Sources/AudioRing/AudioRing.c -o "$out/AudioRing.o"
clang -std=c11 -O2 -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -c Sources/AudioRing/CaptureCallback.c -o "$out/CaptureCallback.o"
cp Tests/Probes/CaptureRenderProbe.swift "$out/main.swift"
swiftc -O -swift-version 5 -I Sources/AnalysisKernels/include -I Sources/AudioRing/include -framework AudioToolbox \
    "$out/main.swift" "$out/AudioRing.o" "$out/CaptureCallback.o" -o "$out/capture-render-probe"
device=${1:?usage: capture-render-probe.sh <input device ID>}
"$out/capture-render-probe" "$device" 0 512 4096
"$out/capture-render-probe" "$device" 96000 2048 4096
"$out/capture-render-probe" "$device" 44100 4096 4096
