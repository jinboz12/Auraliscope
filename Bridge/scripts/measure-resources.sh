#!/bin/zsh
# CPU and memory cost of plugin-side analysis, measured with the real VST3 in the test host: the same host run
# with this build's plugin and with a plugin that does not analyse (build 2, passed as the baseline), so the
# difference is what the analysis costs. No receiver is running: every insert analyses on its own, as it does with
# Labs closed. A private socket keeps a running Labs out of it.
#
#   measure-resources.sh <baseline.vst3> [seconds]
set -uo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/release-version.sh
baseline="$1"
seconds="${2:-20}"
current="$ABR_DIST/Auraliscope Bridge.vst3"
harness=.build/bridge/tools/HostHarness
private="$(mktemp -d /tmp/abr-measure-XXXXXX)"
trap 'rm -rf "$private"' EXIT
export AURALISCOPE_BRIDGE_SOCKET="$private/bridge.sock"
cores=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.physicalcpu)
echo "$(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion); $seconds s per run"
printf '%-26s %12s %12s %14s %14s %12s\n' "case" "CPU base" "CPU build" "extra CPU" "extra memory" "worst proc"
measure() {  # measure <bundle> <harness args…> → "cpu_seconds max_rss_bytes worst_process_us"
    local bundle="$1"; shift
    local out="$private/run.txt"
    /usr/bin/time -l "$harness" --format vst3 --bundle "$bundle" "$@" --phases live:$seconds > "$out" 2>&1
    local line=$(grep -E 'real .* user .* sys' "$out")
    local user=$(echo "$line" | awk '{print $3}') sys=$(echo "$line" | awk '{print $5}')
    local rss=$(awk '/maximum resident set size/{print $1}' "$out")
    local worst=$(grep -o 'worst process [0-9.]*' "$out" | awk '{print $3}' | sort -n | tail -1)
    echo "$(( user + sys )) $rss $worst"
}
row() {  # row <label> <harness args…>
    local label="$1"; shift
    local b=($(measure "$baseline" "$@")) c=($(measure "$current" "$@"))
    local extra_cpu=$(( (c[1] - b[1]) / seconds * 100 )) extra_mem=$(( (c[2] - b[2]) / 1048576.0 ))
    printf '%-26s %11.1f%% %11.1f%% %13.2f%% %12.1f MB %9s µs\n' "$label" $(( b[1] / seconds * 100 )) \
        $(( c[1] / seconds * 100 )) $extra_cpu $extra_mem "${c[3]}"
}
row "1 × 48 kHz stereo"     --channels 2 --rate 48000 --block 256 --instances 1
row "8 × 48 kHz stereo"     --channels 2 --rate 48000 --block 256 --instances 8
row "32 × 48 kHz stereo"    --channels 2 --rate 48000 --block 256 --instances 32
row "8 × 44.1 kHz mono"     --channels 1 --rate 44100 --block 256 --instances 8
row "8 × 96 kHz stereo"     --channels 2 --rate 96000 --block 512 --instances 8
row "8 × 192 kHz stereo"    --channels 2 --rate 192000 --block 1024 --instances 8
row "8 × 48 kHz, block 4096" --channels 2 --rate 48000 --block 4096 --instances 8
echo "CPU is the host process's CPU time over the run as a percentage of one core ($cores performance cores here);"
echo "'extra' is this build minus the baseline: the plugin-side analysis, its threads and result encoding."
