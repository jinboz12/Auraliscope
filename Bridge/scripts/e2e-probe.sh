#!/bin/zsh
# Real plugin binaries → transport → receiver, without Auraliscope: the test host plays the built VST3 and the
# installed AU; the probe checks every delivered sample against the signal. Quit Auraliscope Lab first (both
# listen on the same socket). Logs go to .build/bridge/validation/.
set -uo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/prototype-version.sh
tools=.build/bridge/tools
logs=.build/bridge/validation
mkdir -p "$logs"
vst3="$ABR_DIST/Auraliscope Bridge.vst3"
failed=0
run() {  # run <label> <probe name> <probe instance> <harness args…>
    local label="$1" name="$2" instance="$3"; shift 3
    "$tools/ReceiverProbe" --seconds 7 --verify "$name" --instance "$instance" > "$logs/probe-$label.txt" 2>&1 &
    local probe=$!
    sleep 0.5
    "$tools/HostHarness" "$@" --phases live:6 > "$logs/harness-$label.txt" 2>&1
    local harness=$?
    wait $probe
    local result=$?
    local verdict="PASS"
    (( harness != 0 || result != 0 )) && { verdict="FAIL"; failed=1; }
    printf '%-26s %s | %s | %s\n' "$label" "$verdict" "$(grep -o 'output [a-z ]* input' "$logs/harness-$label.txt" | sort -u | tr '\n' ' ')" \
        "$(grep -o '[0-9]* frames, [0-9] ch at [0-9]* Hz.*lost [0-9]*' "$logs/probe-$label.txt")"
}
run vst3-stereo-48k   "Harness" 0 --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --block 256 --name Harness
run vst3-mono-44k1    "Harness" 0 --format vst3 --bundle "$vst3" --channels 1 --rate 44100 --block 128 --name Harness
run vst3-stereo-96k   "Harness" 0 --format vst3 --bundle "$vst3" --channels 2 --rate 96000 --block 512 --name Harness
run au-stereo-48k     "Harness" 0 --format au --channels 2 --rate 48000 --block 256 --name Harness
run au-mono-48k       "Harness" 0 --format au --channels 1 --rate 48000 --block 64 --name Harness
run au-stereo-192k    "Harness" 0 --format au --channels 2 --rate 192000 --block 1024 --name Harness
run vst3-3-instances  "Multi 2" 1 --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --block 256 --name Multi --instances 3
run au-3-instances    "Multi 3" 2 --format au --channels 2 --rate 48000 --block 256 --name Multi --instances 3
run vst3-editor-close "Harness" 0 --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --block 256 --name Harness \
    --editor-snapshot "$logs/editor-vst3.png" --editor-seconds 2
run au-editor-close   "Harness" 0 --format au --channels 2 --rate 48000 --block 256 --name Harness \
    --editor-snapshot "$logs/editor-au.png" --editor-seconds 2
exit $failed
