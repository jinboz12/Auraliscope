#!/bin/zsh
# Real plugin binaries → transport → Auraliscope Labs's analysis pipeline, checked by the app's own
# --bridge-selftest against the known signal. Needs a logged-in GUI session; no microphone or system-audio
# permission (the app is pointed at a DAW source from launch). Logs go to .build/bridge/validation/app-*.txt.
set -uo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/prototype-version.sh
app="$ABR_DIST/Auraliscope Labs.app/Contents/MacOS/Auraliscope"
harness=.build/bridge/tools/HostHarness
vst3="$ABR_DIST/Auraliscope Bridge.vst3"
logs=.build/bridge/validation
id=A1B2C3D4E5F60718293A4B5C6D7E8F90
failed=0
typeset -a hosts

start_app() {  # start_app <label> <self-test arguments…>
    local label="$1"; shift
    "$app" --diagnostic "$@" -inputDeviceUID "daw.$id" -showWelcomeOnLaunch NO > "$logs/app-$label.txt" 2>&1 &
    app_pid=$!
    ( sleep 90; kill $app_pid 2>/dev/null ) &
    sleep 2
}
host() {  # host <label> <harness arguments…>: runs a test host in the background
    local label="$1"; shift
    "$harness" "$@" >> "$logs/host-$label.txt" 2>&1 &
    hosts+=($!)
}
finish() {  # finish <label>
    local label="$1"
    wait $app_pid; local app_result=$?
    local host_result=0
    for pid in $hosts; do wait $pid || host_result=1; done
    hosts=()
    local verdict=PASS
    (( app_result != 0 || host_result != 0 )) && { verdict=FAIL; failed=1; }
    echo "== $label: $verdict (app $app_result, test host $host_result)"
    grep -hE '\[bridge-selftest\] (stream|peak|dropped|conditions|FAIL|analysis|disconnected)' "$logs/app-$label.txt" | sed 's/^/   /'
    grep -hE 'phase|PASS|FAIL' "$logs/host-$label.txt" 2>/dev/null | sed 's/^/   /'
}
rm -f $logs/app-*.txt(N) $logs/host-*.txt(N)

# 1. VST3 stereo 48 kHz; the plugin then goes away and the same insert returns (new session, same project ID).
start_app reconnect --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --expect-rate 48000 --expect-channels 2 --then-reconnect
"$harness" --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Harness --id $id --phases live:7 >> $logs/host-reconnect.txt 2>&1
sleep 2
host reconnect --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Harness --id $id --phases live:7
finish reconnect

# 2. AU mono 44.1 kHz: one channel, analysed on L only.
start_app au-mono --bridge-selftest Harness --expect-peak-db -6.02 --expect-rate 44100 --expect-channels 1
host au-mono --format au --channels 1 --rate 44100 --block 128 --name Harness --phases live:7
finish au-mono

# 3. Three VST3 instances; the app selects the second (half the level of the first).
start_app multi --bridge-selftest "Multi 2" --expect-peak-db -12.04,-18.06 --expect-channels 2
host multi --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Multi --instances 3 --phases live:8
finish multi

# 4. AU stereo, then the host switches to 96 kHz mid-stream: analysis must be rebuilt for the new rate.
start_app rate-change --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --then-rate 96000
host rate-change --format au --channels 2 --rate 48000 --name Harness --phases live:6,rate=96000:8
finish rate-change

# 5. Bypass, offline render and a host that stops processing, as the status line shows them.
start_app states --bridge-selftest Harness --measure-seconds 1 --watch 14 --expect-seen bypassed,offline,noAudio,streaming
host states --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Harness --phases live:5,bypass:3,offline:3,idle:3,live:4
finish states

# 6. Auraliscope quits and starts again while the DAW keeps playing; the test host checks every output block.
host app-restart-2 --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Harness --phases live:24
start_app app-restart-1 --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --measure-seconds 1
wait $app_pid; first=$?
start_app app-restart-2 --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --measure-seconds 1
finish app-restart-2
(( first != 0 )) && { echo "   first app run failed"; failed=1; }

echo; (( failed )) && echo "Some app-level checks FAILED" || echo "All app-level checks passed"
exit $failed
