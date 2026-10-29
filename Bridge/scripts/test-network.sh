#!/bin/zsh
# The Bridge's network carrier end to end, with the real VST3 binary (the iPad phase's dev build) in the test host on a
# real-time thread and a network display on this Mac (BridgeNetworkProbe: the iPad app's receiving path without the
# UI). Everything runs against a private state folder (AURALISCOPE_BRIDGE_SOCKET), so the person's own Bridge folder,
# pairings and a running Auraliscope are never touched. Logs and summaries go to .build/bridge/network-tests/.
#
# Cases: pairing with the plugin's own pairing code; results over TLS (rate, bandwidth, ACK round trip, order, values);
# a display that stops reading for 8 s; a dropped connection; a display that no longer holds the key. In every case the
# host's audio must pass unchanged, and the worst process() call is reported.
set -uo pipefail
cd "${0:A:h:h:h}"
zsh Bridge/scripts/build-ipad-dev-plugin.sh >/dev/null
zsh Bridge/scripts/build-network-tools.sh >/dev/null
ABR_DIST="$PWD/.build/bridge/ipad-dev-dist" ABR_VERSION_FILE=Bridge/scripts/ipad-dev-version.sh zsh Bridge/scripts/build-tools.sh >/dev/null
tools=.build/bridge/tools
plugin=".build/bridge/dev/Auraliscope Bridge Dev.vst3"
logs=.build/bridge/network-tests
rm -rf "$logs"; mkdir -p "$logs"
state="$(mktemp -d /tmp/abr-net-XXXXXX)"
trap 'rm -rf "$state"; pkill -f "BridgeNetworkProbe --state $state" 2>/dev/null' EXIT
export AURALISCOPE_BRIDGE_SOCKET="$state/bridge.sock"
name="Auraliscope Probe $$"
failed=0

summary() { grep '^SUMMARY ' "$1" | cut -d' ' -f2-; }
verdict() {  # verdict <label> <harness log> <probe log> <python condition on d (probe summary)>
    local label="$1" harness="$2" probe="$3" condition="$4"
    local audio="$(grep -c 'output identical to input' "$harness")" phases="$(grep -c '\] phase' "$harness")"
    local worst="$(grep -o 'worst process [0-9.]* µs' "$harness" | awk '{print $3}' | sort -n | tail -1)"
    local ok="$(summary "$probe" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if ($condition) else 'no')" 2>/dev/null)"
    local result=PASS
    [[ "$audio" == "$phases" && "$phases" -gt 0 && "$ok" == yes ]] || { result=FAIL; failed=1; }
    printf '%-10s %s | audio identical in %s/%s phases, worst process %s µs | %s\n' "$label" "$result" "$audio" "$phases" "$worst" \
        "$(summary "$probe" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['results']} results, {d['resultsPerSecond']:.0f}/s, {d['kBPerSecond']:.0f} kB/s, max gap {d['maxGapMs']:.0f} ms, RTT p50 {d['rttP50Ms']:.1f} ms p95 {d['rttP95Ms']:.1f} ms, invalid {d['invalidResults']}, column gaps {d['columnGaps']} (sender-reported {d['columnsDroppedBySender']}), connections {d['connections']}, refused {d['refusedHandshakes']}\")" 2>/dev/null)"
}

# Pairing: the probe opens pairing with a code and approves; NetworkPair runs the plugin's pairing code.
"$tools/BridgeNetworkProbe" --state "$state/probe" --name "$name" --pair-code 7K2M9QXA --seconds 15 > "$logs/pair-probe.txt" 2>&1 &
sleep 1.5
"$tools/NetworkPair" --pair "$name" --code 7k2m-9qxa > "$logs/pair.txt" 2>&1
pkill -f "BridgeNetworkProbe --state $state" 2>/dev/null; sleep 0.5
receiver="$(grep -o 'receiver [0-9a-f]*' "$logs/pair.txt" | awk '{print $2}')"
if [[ -z "$receiver" ]]; then echo "pairing    FAIL | $(tail -1 "$logs/pair.txt")"; exit 1; fi
wrong="$( { "$tools/BridgeNetworkProbe" --state "$state/probe" --name "$name" --pair-code AAAABBBB --seconds 6 >/dev/null 2>&1 & }; sleep 1.5; "$tools/NetworkPair" --pair "$name" --code 7K2M9QXA 2>&1 | head -1)"
pkill -f "BridgeNetworkProbe --state $state" 2>/dev/null; sleep 0.5
printf 'pairing    PASS | receiver %s, stored 0600: %s · a wrong code: "%s"\n' "$receiver" \
    "$(stat -f '%Sp' "$state/Receivers/$receiver.pairing")" "$wrong"
[[ "$wrong" == *"Wrong code"* ]] || { echo "pairing    FAIL | a wrong code was not refused"; failed=1; }

run() {  # run <label> <probe seconds> <harness phases> <condition> <probe options…>
    local label="$1" seconds="$2" phases="$3" condition="$4"; shift 4
    "$tools/BridgeNetworkProbe" --state "$state/probe" --name "$name" --seconds "$seconds" "$@" > "$logs/probe-$label.txt" 2>&1 &
    local probe=$!
    sleep 1
    "$tools/HostHarness" --format vst3 --bundle "$plugin" --receiver "$receiver" --name "Net $label" --phases "$phases" \
        > "$logs/harness-$label.txt" 2>&1
    wait $probe
    verdict "$label" "$logs/harness-$label.txt" "$logs/probe-$label.txt" "$condition"
}
run results 14 live:11 "d['results'] > 500 and d['invalidResults'] == 0 and d['columnGaps'] == 0 and d['lastPeakDB'][0] > -6.1 and d['lastPeakDB'][0] < -5.9 and d['lastPeakDB'][1] > -12.1 and d['lastPeakDB'][1] < -11.9 and d['rttCount'] > 50" --rtt
run stall 22 live:4,live:9,live:6 "d['results'] > 600 and d['invalidResults'] == 0 and d['maxGapMs'] > 7000 and d['columnGaps'] == d['columnsDroppedBySender']" --stall-at 5 --stall-for 8
run drop 14 live:12 "d['connections'] == 2 and d['invalidResults'] == 0 and d['results'] > 500" --drop-at 5
# The display forgets this Mac: a probe with the same receiver ID and no key for it.
mkdir -p "$state/forgot"
python3 -c "import json; d=json.load(open('$state/probe/probe-state.json')); d['macs']={}; json.dump(d, open('$state/forgot/probe-state.json','w'))"
"$tools/BridgeNetworkProbe" --state "$state/forgot" --name "$name" --seconds 9 > "$logs/probe-refused.txt" 2>&1 &
sleep 1
"$tools/HostHarness" --format vst3 --bundle "$plugin" --receiver "$receiver" --name "Net refused" --phases live:7 > "$logs/harness-refused.txt" 2>&1
wait
verdict refused "$logs/harness-refused.txt" "$logs/probe-refused.txt" "d['results'] == 0 and d['bytes'] == 0 and d['refusedHandshakes'] >= 1"
(( failed )) && echo "Network checks FAILED (logs in $logs)" || echo "All network checks passed (logs in $logs)"
exit $failed
