#!/bin/zsh
# Model self-tests in an isolated QA bundle (com.jinboz.SoundMeterJBZ.QA, never the user's preferences): the worker
# interface (--test-model-worker, on the demo signal) and the capture and DAW plugin states with stand-ins for devices,
# capture, analysis and plugins (--test-model-lifecycle). No audio device, DAW or permission is used, and the plugin
# socket is private (scripts/qa-env.sh), but the app launches, so a window server is needed.
# Logs: .build/model-checks/<test>.log.
set -euo pipefail
cd "${0:A:h:h}"
source scripts/qa-env.sh
trap 'rm -rf "$QA_PRIVATE"' EXIT
swift build
out=.build/model-checks
qa="$out/Auraliscope-QA.app"
mkdir -p "$out"
qa_bundle .build/debug/Auraliscope "$qa"
failed=0
for test in test-model-worker test-model-lifecycle; do
    log="$out/$test.log"
    # The worker test builds a real meter: the demo signal feeds it, so no device is opened.
    extra=(); [[ $test == test-model-worker ]] && extra=(--demo)
    if "$qa/Contents/MacOS/Auraliscope" -showWelcomeOnLaunch NO "${extra[@]}" "--$test" > "$log" 2>&1; then
        echo "pass  --$test  ($(grep -c '^PASS' "$log") checks)"
    else
        echo "FAIL  --$test  ($log)"
        grep -E '^(FAIL|status|journal)' "$log" | head -4
        failed=1
    fi
done
exit $failed
