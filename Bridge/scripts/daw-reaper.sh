#!/bin/zsh
# REAPER runtime test, in a private REAPER resource folder (.build/bridge/reaper-profile): the user's REAPER
# settings, plugin caches and projects are not touched, and audio goes to the silent "Pro Tools Audio Bridge 2-A"
# virtual device (set ABR_REAPER_DEVICE to use another).
#
#   daw-reaper.sh vst3|au live      play/editor/bypass/stop script (Bridge/Tools/reaper-bridge-test.lua)
#   daw-reaper.sh vst3|au render    offline render of the project saved by the live run
#   daw-reaper.sh vst3|au identity  duplicate, loop, seek, rate change, unload/reload (reaper-identity-test.lua)
#   daw-reaper.sh vst3|au reopen    reopen the project saved by the identity run and play it
#
# Run Auraliscope Lab alongside to see the stream (e2e-daw.sh does both). Logs: .build/bridge/validation/.
set -euo pipefail
cd "${0:A:h:h:h}"
format="${1:-vst3}" mode="${2:-live}"
reaper="/Applications/REAPER.app/Contents/MacOS/REAPER"
root="$PWD/.build/bridge/reaper-profile"
logs="$PWD/.build/bridge/validation"
mkdir -p "$root/vst3only" "$root/clap-none" "$root/render" "$logs"
# Only the Bridge VST3 is on REAPER's VST path; AUs come from the system registry, so a copy of the user's AU scan
# cache spares every other Audio Unit a rescan (the Bridge is new to it and gets scanned).
ln -sfn "$HOME/Library/Audio/Plug-Ins/VST3/Auraliscope Bridge.vst3" "$root/vst3only/Auraliscope Bridge.vst3"
# REAPER still scans its default VST folders, so the user's scan caches are copied too: every plugin already known
# to their REAPER stays cached, and only the Bridge is scanned (no third-party licence dialogs, no long scan).
for cache in "$HOME/Library/Application Support/REAPER"/reaper-{auplugins,vstplugins,vstshells}_arm64*.ini(N); do
    [[ -f "$root/${cache:t}" ]] || cp "$cache" "$root/"
done
device="${ABR_REAPER_DEVICE:-Pro Tools Audio Bridge 2-A}"
cat > "$root/reaper.ini" <<INI
[reaper]
coreaudioindevnew=$device
coreaudiooutdevnew=$device
coreaudiobs=256
coreaudiobsuse=1
coreaudiosrate=48000
coreaudiosrateuse=1
vstpath_arm64=$root/vst3only
clap_path_macos-aarch64=$root/clap-none
verchk=0
splash=0
INI
wav="$root/bridge-test-48k.wav"
[[ -f "$wav" ]] || python3 Bridge/Tools/make-test-wav.py "$wav" 48000 30
project="$root/bridge-$format.rpp"
fx="VST3:Auraliscope Bridge"; [[ "$format" == au ]] && fx="AU:Auraliscope Bridge"
export ABR_WAV="$wav" ABR_FX="$fx" ABR_TRACK="REAPER $format track" ABR_PROJECT="$project" ABR_RENDER_DIR="$root/render"
export ABR_LOG="$logs/reaper-$format-$mode.txt"
rm -f "$ABR_LOG"
# REAPER with the private profile, stopped by its process ID if it is still running after 100 s (a dialog).
run_reaper() {
    # A running REAPER would receive the project instead of a new, private instance.
    if pgrep -xq REAPER; then echo "REAPER is already running: quit it first" >&2; return 1; fi
    "$reaper" -newinst -cfgfile "$root/reaper.ini" -nosplash -ignoreerrors "$@" &
    local pid=$! waited=0
    while kill -0 $pid 2>/dev/null && (( waited < 100 )); do sleep 1; (( waited++ )); done
    kill $pid 2>/dev/null && echo "REAPER did not quit within 100 s; stopped it"
    wait $pid 2>/dev/null
    # REAPER can outlive the process it was launched as (it may relaunch itself): wait for every REAPER to be
    # gone, so the project is saved and the next run starts clean. None was running when this one started.
    while pgrep -xq REAPER && (( waited < 110 )); do sleep 1; (( waited++ )); done
    local left=($(pgrep -x REAPER))
    (( ${#left} )) && { kill $left 2>/dev/null; echo "REAPER still running after 110 s; stopped it"; }
    true
}
if [[ "$mode" == identity || "$mode" == reopen ]]; then
    project="$root/bridge-identity-$format.rpp"
    if [[ "$mode" == identity ]]; then
        printf '<REAPER_PROJECT 0.1 "7.80" 0\n  SAMPLERATE 48000 0 0\n>\n' > "$project"
    else
        [[ -f "$project" ]] || { echo "run the identity test first (it saves $project)" >&2; exit 1; }
    fi
    run_reaper "$project" "Bridge/Tools/reaper-$mode-test.lua" > "$logs/reaper-$format-$mode.stdout" 2>&1
elif [[ "$mode" == render ]]; then
    [[ -f "$project" ]] || { echo "run the live test first (it saves $project)" >&2; exit 1; }
    rm -f "$root/render/"*(N)
    start=$(date +%s)
    run_reaper -renderproject "$project" > "$ABR_LOG" 2>&1
    echo "render finished after $(( $(date +%s) - start )) s; output: $(ls "$root/render" | tr '\n' ' ')" >> "$ABR_LOG"
else
    # Start from an empty project file, so the script can save in place and REAPER quits without asking.
    printf '<REAPER_PROJECT 0.1 "7.80" 0\n  SAMPLERATE 48000 0 0\n>\n' > "$project"
    run_reaper "$project" Bridge/Tools/reaper-bridge-test.lua > "$logs/reaper-$format-$mode.stdout" 2>&1
fi
cat "$ABR_LOG"
