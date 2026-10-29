#!/bin/zsh
# The app's own self-tests that need a window server but no audio device, DAW or user state: each runs in a QA bundle
# (scripts/qa-env.sh: its own preferences, logs and settings presets, a private plugin socket, no update check) on the
# demo signal or the lifecycle stand-ins. A test passes when it exits 0 with no FAIL line.
# Logs: .build/selftests/<test>.log.
set -uo pipefail
cd "${0:A:h:h}"
source scripts/qa-env.sh
trap 'rm -rf "$QA_PRIVATE"' EXIT
swift build >/dev/null || exit 1
out=.build/selftests
mkdir -p "$out"
qa="$out/Auraliscope-QA.app"
qa_bundle .build/debug/Auraliscope "$qa"
app="$qa/Contents/MacOS/Auraliscope"
failed=0
selftest() {  # selftest <label> <args…>
    local label="$1"; shift
    local start=$SECONDS
    "$app" -showWelcomeOnLaunch NO "$@" > "$out/$label.log" 2>&1
    # Some self-tests prefix their lines ("[multifft-layout] PASS: …"): count the verdicts wherever they stand.
    local code=$? fails=$(grep -cE '(^|[] ])FAIL:' "$out/$label.log") passes=$(grep -cE '(^|[] ])PASS:' "$out/$label.log")
    if (( code == 0 && fails == 0 )); then printf 'pass  %-20s %4ds  (%d PASS)\n' "$label" $(( SECONDS - start )) $passes
    else printf 'FAIL  %-20s %4ds  (exit %d, %d PASS, %d FAIL, %s)\n' "$label" $(( SECONDS - start )) $code $passes $fails "$out/$label.log"; failed=1; fi
}
selftest shaders --check-shaders
selftest model-worker --demo --test-model-worker
selftest model-lifecycle --test-model-lifecycle
selftest settings-draft --demo --show-settings --test-settings-draft
selftest settings-presets --demo --test-settings-presets
selftest multifft-layout --demo --diagnostic --multifft-test-tone --test-multifft-layout
selftest pause --demo --test-pause-resume
selftest spectrum-average --demo --test-spectrum-average
selftest peak-reset --demo --test-peak-reset
selftest nebula-gpu --demo --test-nebula-gpu
selftest spatial-projection --demo --test-spatial-projection
exit $failed
