#!/bin/zsh
# REAPER immersive check of the current source, without installing anything: builds "Auraliscope Bridge Dev.vst3"
# (build-dev-vst3.sh: the source under a class ID of its own, so REAPER cannot load an installed Bridge instead), and
# plays the 12-channel test WAV on a 12-channel track through it in the private REAPER profile (daw-reaper.sh vst3
# surround) twice: once watched by the probe (the plugin's results against Auraliscope's own analysis of the signal),
# once by Auraliscope (what it shows). REAPER must give the plugin all 12 channels as 7.1.4, and each channel must
# read its own level on its own speaker. Private sockets; REAPER and LABS must not be running. Logs:
# .build/bridge/validation/.
set -uo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/release-version.sh
logs=.build/bridge/validation
mkdir -p "$logs"
pgrep -xq REAPER && { echo "REAPER is running: quit it first" >&2; exit 1; }
dev="$(Bridge/scripts/build-dev-vst3.sh | tail -1)" || { echo "dev VST3 build failed" >&2; exit 1; }
Bridge/scripts/build-tools.sh >/dev/null
export ABR_REAPER_VST3="$dev" ABR_SECONDS=30
private="$(mktemp -d /tmp/abr-reaper-surround-XXXXXX)"
trap 'rm -rf "$private"' EXIT
export AURALISCOPE_BRIDGE_SOCKET="$private/bridge.sock"
roles=0,1,2,3,8,9,4,5,6,7,14,15
peaks=-6.02,-12.04,-15.56,-18.06,-20.00,-21.58,-22.92,-24.08,-25.11,-26.02,-26.85,-27.60
failed=0

# 1. The probe, ending while REAPER still plays (a stop mid-waveform is not the programme).
.build/bridge/tools/ResultProbe --seconds 20 --verify "REAPER vst3 track" --instance 0 --expect-roles $roles \
    --expect-layout 7.1.4 --immersive-after 3 --true-peak-onset 0.25 > "$logs/probe-reaper-surround.txt" 2>&1 &
probe=$!
sleep 1
Bridge/scripts/daw-reaper.sh vst3 surround > /dev/null 2>&1
wait $probe || failed=1
cp "$logs/reaper-vst3-surround.txt" "$logs/reaper-vst3-surround-probe.txt"
grep -q "the plugin takes all 12 channels" "$logs/reaper-vst3-surround.txt" || failed=1
grep -q "FAIL" "$logs/reaper-vst3-surround.txt" && failed=1
echo "== REAPER 7.1.4 track, probe: $(tail -1 "$logs/probe-reaper-surround.txt")"
grep -hE "pins|takes|playing\?" "$logs/reaper-vst3-surround.txt" | sed 's/^/   /'
grep -hE "STATUS|roles|names|switched|band energy|integrated|momentary|spectrum within|FAIL" "$logs/probe-reaper-surround.txt" | sed 's/^/   /'

# 2. Auraliscope: the plugin's own format, Immersive by Auto, every channel on its speaker.
app="$ABR_DIST/Auraliscope.app/Contents/MacOS/Auraliscope"
"$app" --diagnostic --bridge-selftest "REAPER vst3 track" --expect-layout 7.1.4 --expect-format spatial --expect-channels 12 \
    --expect-rate 48000 --expect-peak-db $peaks --measure-seconds 4 -formatMode auto -inputDeviceUID daw.00 \
    -showWelcomeOnLaunch NO > "$logs/app-reaper-surround.txt" 2>&1 &
app_pid=$!
sleep 1
Bridge/scripts/daw-reaper.sh vst3 surround > /dev/null 2>&1
waited=0
while kill -0 $app_pid 2>/dev/null && (( waited < 60 )); do sleep 1; (( ++waited )); done
kill $app_pid 2>/dev/null
wait $app_pid || failed=1
echo "== REAPER 7.1.4 track, Auraliscope: $(tail -1 "$logs/app-reaper-surround.txt")"
grep -hE '\[bridge-selftest\] (streaming|stream:|bus|integrated|FAIL)' "$logs/app-reaper-surround.txt" | sed 's/^/   /'
echo; (( failed )) && echo "REAPER immersive check FAILED" || echo "REAPER immersive check passed"
exit $failed
