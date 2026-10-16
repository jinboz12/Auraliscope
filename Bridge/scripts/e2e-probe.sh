#!/bin/zsh
# Real plugin binaries → plugin-side analysis → results → a receiver, without Auraliscope: the test host plays
# the built VST3 and the installed AU and checks that the output equals the input; the probe checks the results
# against Auraliscope's own analysis of the same signal, their order and the timeline. A private socket keeps it
# apart from a running Labs. Logs go to .build/bridge/validation/.
#
#   e2e-probe.sh [label-pattern]     run only the cases whose label matches (e.g. 'vst3-stereo-48k')
set -uo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/release-version.sh
tools=.build/bridge/tools
logs=.build/bridge/validation
mkdir -p "$logs"
vst3="$ABR_DIST/Auraliscope Bridge.vst3"
au="$ABR_DIST/Auraliscope Bridge.component"
filter="${1:-}"
private="$(mktemp -d /tmp/abr-e2e-XXXXXX)"
trap 'rm -rf "$private"' EXIT
export AURALISCOPE_BRIDGE_SOCKET="$private/bridge.sock"
failed=0
run() {  # run <label> <probe name> <probe instance> <probe options> <harness args…>
    local label="$1" name="$2" instance="$3" options="$4"; shift 4
    [[ -n "$filter" && "$label" != *$~filter* ]] && return
    "$tools/ResultProbe" --seconds 8 --verify "$name" --instance "$instance" ${=options} > "$logs/probe-$label.txt" 2>&1 &
    local probe=$!
    sleep 0.5
    "$tools/HostHarness" "$@" > "$logs/harness-$label.txt" 2>&1
    local harness=$?
    wait $probe
    local result=$?
    local verdict="PASS"
    (( harness != 0 || result != 0 )) && { verdict="FAIL"; failed=1; }
    printf '%-24s %s | %s | %s\n' "$label" "$verdict" \
        "$(grep -o 'output [a-z ]* input' "$logs/harness-$label.txt" | sort -u | tr '\n' ' ')" \
        "$(grep -o '[0-9]* results in .*analysed' "$logs/probe-$label.txt")"
    [[ $verdict == FAIL ]] && grep -E "FAIL" "$logs/probe-$label.txt" "$logs/harness-$label.txt" | head -5
}
live=(--phases live:7)
run vst3-stereo-48k   Harness 0 "" --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --block 256 --name Harness $live
run vst3-mono-44k1    Harness 0 "" --format vst3 --bundle "$vst3" --channels 1 --rate 44100 --block 128 --name Harness $live
run vst3-stereo-96k   Harness 0 "" --format vst3 --bundle "$vst3" --channels 2 --rate 96000 --block 512 --name Harness $live
run au-stereo-48k     Harness 0 "" --format au --bundle "$au" --channels 2 --rate 48000 --block 256 --name Harness $live
run au-mono-48k       Harness 0 "" --format au --bundle "$au" --channels 1 --rate 48000 --block 64 --name Harness $live
run au-stereo-192k    Harness 0 "" --format au --bundle "$au" --channels 2 --rate 192000 --block 1024 --name Harness $live
run vst3-3-instances  "Multi 2" 1 "" --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --block 256 --name Multi --instances 3 $live
run au-3-instances    "Multi 3" 2 "" --format au --bundle "$au" --channels 2 --rate 48000 --block 256 --name Multi --instances 3 $live
run vst3-enhanced     Harness 0 "--enhanced-after 2" --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --block 256 --name Harness $live
run au-enhanced-96k   Harness 0 "--enhanced-after 2" --format au --bundle "$au" --channels 2 --rate 96000 --block 512 --name Harness $live
run vst3-before-labs  Harness 0 "--subscribe-after 3" --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --block 256 --name Harness $live
# Immersive VST3 buses: every channel on its speaker role (Ls Rs are the rear pair beside Sl Sr; a lone top-side pair
# is the x.x.2 pair), the layout named, and with --immersive-after the spectrum summing every channel.
run vst3-7.1.4-48k    Harness 0 "--expect-roles 0,1,2,3,8,9,4,5,6,7,14,15 --expect-layout 7.1.4 --immersive-after 3" \
    --format vst3 --bundle "$vst3" --layout 7.1.4 --rate 48000 --block 256 --name Harness $live
run vst3-5.1-96k      Harness 0 "--expect-roles 0,1,2,3,4,5 --expect-layout 5.1" \
    --format vst3 --bundle "$vst3" --layout 5.1 --rate 96000 --block 512 --name Harness $live
run vst3-7.1.2-44k1   Harness 0 "--expect-roles 0,1,2,3,8,9,4,5,6,7 --expect-layout 7.1.2 --immersive-after 2" \
    --format vst3 --bundle "$vst3" --layout 7.1.2 --rate 44100 --block 128 --name Harness $live
run vst3-9.1.6-96k    Harness 0 "--expect-roles 0,1,2,3,8,9,4,5,6,7,14,15,12,13,10,11 --expect-layout 9.1.6 --immersive-after 2" \
    --format vst3 --bundle "$vst3" --layout 9.1.6 --rate 96000 --block 1024 --name Harness $live
run vst3-stereo-to-7.1.4 Harness 0 "--expect-roles 0,1,2,3,8,9,4,5,6,7,14,15 --expect-layout 7.1.4 --immersive-after 1" \
    --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --block 256 --name Harness --phases live:2,layout=7.1.4:5
run vst3-7.1.4-controls Harness 0 "--controls --seconds 3" --format vst3 --bundle "$vst3" --layout 7.1.4 --rate 48000 --block 256 \
    --name Harness --phases live:12
run au-controls       Harness 0 "--controls --seconds 3" --format au --bundle "$au" --channels 2 --rate 48000 --block 256 --name Harness --phases live:12
run vst3-editor-close Harness 0 "" --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --block 256 --name Harness $live \
    --editor-snapshot "$logs/editor-vst3.png" --editor-seconds 2
run au-editor-close   Harness 0 "" --format au --bundle "$au" --channels 2 --rate 48000 --block 256 --name Harness $live \
    --editor-snapshot "$logs/editor-au.png" --editor-seconds 2
exit $failed
