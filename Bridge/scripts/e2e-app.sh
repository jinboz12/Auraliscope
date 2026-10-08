#!/bin/zsh
# Real plugin binaries → plugin-side analysis → results → Auraliscope Labs's displays, checked by the app's own
# --bridge-selftest against the known signal (and, with --compare-reference, against Labs' own analysis of it).
# Every measurement also checks that Labs shows the plugin's results and analyses nothing itself. Needs a logged-in GUI session; no microphone or system-audio
# permission (the app is pointed at a DAW source from launch). Logs go to .build/bridge/validation/app-*.txt.
set -uo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/prototype-version.sh
app="$ABR_DIST/Auraliscope LABS.app/Contents/MacOS/Auraliscope"
harness=.build/bridge/tools/HostHarness
vst3="$ABR_DIST/Auraliscope Bridge.vst3"
au="$ABR_DIST/Auraliscope Bridge.component"
logs=.build/bridge/validation
id=A1B2C3D4E5F60718293A4B5C6D7E8F90
# A private socket prevents the test app from taking over a running LABS receiver.
private="$(mktemp -d /tmp/abr-app-e2e-XXXXXX)"
trap 'rm -rf "$private"' EXIT
export AURALISCOPE_BRIDGE_SOCKET="$private/bridge.sock"
failed=0
typeset -a hosts

start_app() {  # start_app <label> <self-test arguments…>
    local label="$1"; shift
    # -bridgeSelection '': no saved context from an earlier run; only the saved identity, as build 1 kept it.
    "$app" --diagnostic "$@" -inputDeviceUID "daw.$id" -bridgeSelection '' -bridgeSourceName '' -showWelcomeOnLaunch NO > "$logs/app-$label.txt" 2>&1 &
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
    grep -hE '\[bridge-selftest\] (stream|peak|unanalysed|plugin|conditions|FAIL|disconnected|integrated|after|ambiguous|still|choosing|held|returned|compared|  |pause|resume|reset|while|controls)' "$logs/app-$label.txt" | sed 's/^/   /'
    grep -hE 'phase|PASS|FAIL' "$logs/host-$label.txt" 2>/dev/null | sed 's/^/   /'
}
rm -f $logs/app-*.txt(N) $logs/host-*.txt(N)

# 1. VST3 stereo 48 kHz; the plugin then goes away and the same insert returns (new session, same project ID).
start_app reconnect --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --expect-rate 48000 --expect-channels 2 --compare-reference --then-reconnect
"$harness" --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Harness --id $id --phases live:7 >> $logs/host-reconnect.txt 2>&1
sleep 2
host reconnect --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Harness --id $id --phases live:7
finish reconnect

# 2. AU mono 44.1 kHz: one channel, analysed on L only.
start_app au-mono --bridge-selftest Harness --expect-peak-db -6.02 --expect-rate 44100 --expect-channels 1 --compare-reference
host au-mono --format au --bundle "$au" --channels 1 --rate 44100 --block 128 --name Harness --phases live:7
finish au-mono

# 3. Three VST3 instances; the app selects the second (half the level of the first).
start_app multi --bridge-selftest "Multi 2" --expect-peak-db -12.04,-18.06 --expect-channels 2
host multi --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Multi --instances 3 --phases live:8
finish multi

# 4. AU stereo, then the host switches to 96 kHz mid-stream: analysis must be rebuilt for the new rate.
start_app rate-change --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --then-rate 96000
host rate-change --format au --bundle "$au" --channels 2 --rate 48000 --name Harness --phases live:6,rate=96000:8
finish rate-change

# 5. Bypass, offline render and a host that stops processing, as the status line shows them; the analysis counts
#    the break and its integrated loudness carries on across it.
start_app states --bridge-selftest Harness --measure-seconds 1 --watch 14 --expect-seen bypassed,offline,noAudio,streaming --expect-breaks 1
host states --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Harness --phases live:5,bypass:3,offline:3,idle:3,live:4
finish states

# 6. Auraliscope quits and starts again while the DAW keeps playing; the test host checks every output block.
host app-restart-2 --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Harness --phases live:24
start_app app-restart-1 --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --measure-seconds 1
wait $app_pid; first=$?
start_app app-restart-2 --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --measure-seconds 1
finish app-restart-2
(( first != 0 )) && { echo "   first app run failed"; failed=1; }

# 7. A duplicated track: a copy restored from the saved insert's state while it is live, identical in name and
#    host. The saved identity is then ambiguous: Labs must analyse neither until one is chosen; choosing the copy
#    (half the level) measures the copy.
start_app duplicate --expect-ambiguous 2 --bridge-selftest --expect-peak-db -12.04,-18.06
host duplicate --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Dup --id $id --copies 1 --phases live:16
finish duplicate

# 8. The same live insert reconnects (the host restores state into the running plugin, which announces itself
#    again): its measurement carries on across the reconnection (same generation), and so does the display.
start_app hold --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --then-hold
host hold --format au --bundle "$au" --channels 2 --rate 48000 --name Harness --id $id --phases live:6,reidentify:9
finish hold

# 9. The connection breaks (closed on the receiving side) and the plugin reconnects a second later: the display
#    is held meanwhile ("measurement held"); the plugin measured on, and the display carries on with its state.
start_app held --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --then-hold --drop-connection
host held --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Harness --id $id --phases live:16
finish held

# 10. Controls from Labs: pause (Labs' Pause Capture pauses the plugin's measurement and holds the display),
#     resume, reset true peak, reset (a new generation), each acknowledged by the plugin.
start_app controls --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --then-controls
host controls --format au --bundle "$au" --channels 2 --rate 48000 --name Harness --phases live:24
finish controls

# 11. The insert measured before Labs was launched: the first results already cover it.
host before-labs --format vst3 --bundle "$vst3" --channels 2 --rate 48000 --name Harness --phases live:16
sleep 5
start_app before-labs --bridge-selftest Harness --expect-peak-db -6.02,-12.04 --expect-analysed-min 5 --compare-reference
finish before-labs

echo; (( failed )) && echo "Some app-level checks FAILED" || echo "All app-level checks passed"
exit $failed
