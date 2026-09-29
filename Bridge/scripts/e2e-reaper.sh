#!/bin/zsh
# REAPER runtime checks with Auraliscope Labs watching: for each format, the live script (play, plugin window open
# and closed, FX bypass, stop, play, quit), then an offline render of the saved project, whose output is compared
# with the source signal. Uses daw-reaper.sh (private REAPER profile, silent virtual output device).
set -uo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/prototype-version.sh
app="$ABR_DIST/Auraliscope Labs.app/Contents/MacOS/Auraliscope"
logs=.build/bridge/validation
failed=0
watch_app() {  # watch_app <log> <self-test arguments…>: runs the app in the background
    app_log="$1"; shift
    "$app" --diagnostic "$@" -inputDeviceUID daw.00 -showWelcomeOnLaunch NO > "$app_log.tmp" 2>&1 &
    app_pid=$!
    sleep 1
}
await_app() {  # waits up to 120 s for the app's verdict, then stops it by process ID
    local waited=0
    while kill -0 $app_pid 2>/dev/null && (( waited < 120 )); do sleep 1; (( waited++ )); done
    kill $app_pid 2>/dev/null
    wait $app_pid; local result=$?
    { cat "$app_log.tmp"; echo "app exit $result"; } > "$app_log"; rm -f "$app_log.tmp"
    (( result == 0 )) || failed=1
}
for format in vst3 au; do
    track="REAPER $format track"
    watch_app "$logs/app-reaper-$format-live.txt" --bridge-selftest "$track" --expect-peak-db -6.02,-12.04 --expect-rate 48000 \
        --expect-channels 2 --watch 40 --expect-seen streaming,noAudio,disconnected
    Bridge/scripts/daw-reaper.sh $format live > /dev/null 2>&1
    await_app
    echo "== REAPER $format live: $(tail -1 "$logs/app-reaper-$format-live.txt")"
    grep -hE 'found|stream:|peak|conditions|FAIL' "$logs/app-reaper-$format-live.txt" | sed 's/^/   /'
    grep -h 'inserted' "$logs/reaper-$format-live.txt" | sed 's/^/   /'

    # Offline render, traced by the probe (Labs must not be running): the insert must report offline throughout,
    # never deliver live audio, and the bounce must equal the source.
    trace="$logs/probe-reaper-$format-render.txt"
    .build/bridge/tools/ReceiverProbe --seconds 30 --trace 1 > "$trace" 2>&1 &
    probe_pid=$!
    sleep 1
    Bridge/scripts/daw-reaper.sh $format render > /dev/null 2>&1
    wait $probe_pid
    echo "== REAPER $format offline render"
    grep -h 's  ' "$trace" | sed 's/^/   /'
    # Pass: the insert reported offline, and no audio reached the receiver as a live stream. (REAPER sets an AU's
    # OfflineRender a moment after creating it, before rendering; that brief "live" state carries no audio.)
    if grep -q ' offline' "$trace" && ! grep -q '+audio' "$trace"; then
        echo "   offline reported, no audio delivered as live: PASS"
        grep -q ' live' "$trace" && echo "   (the host created the insert as live and flagged offline before rendering)"
    else echo "   live audio during the render: FAIL"; failed=1; fi
    python3 Bridge/Tools/check-render.py .build/bridge/reaper-profile/render/bridge-render.wav | sed 's/^/   /' || failed=1
done
(( failed )) && echo "Some REAPER checks FAILED" || echo "All REAPER checks passed"
exit $failed
