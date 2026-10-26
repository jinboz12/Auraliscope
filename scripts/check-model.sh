#!/bin/zsh
# Model self-tests in an isolated QA bundle (com.jinboz.SoundMeterJBZ.QA, never the user's preferences): the worker
# interface (--test-model-worker) and the capture and DAW plugin states with stand-ins for devices, capture, analysis
# and plugins (--test-model-lifecycle). No audio device, DAW or permission is used, but the app launches, so a window
# server is needed. Logs: .build/model-checks/<test>.log.
set -euo pipefail
cd "${0:A:h:h}"
swift build
out=.build/model-checks
qa="$out/Auraliscope-QA.app"
rm -rf "$qa"
mkdir -p "$qa/Contents/MacOS" "$qa/Contents/Resources"
cp Resources/Info.plist "$qa/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.jinboz.SoundMeterJBZ.QA" "$qa/Contents/Info.plist"
cp Resources/Auraliscope.icns "$qa/Contents/Resources/"
cp -R Resources/Localization/*.lproj "$qa/Contents/Resources/"
cp .build/debug/Auraliscope "$qa/Contents/MacOS/Auraliscope"
codesign --force --sign - "$qa" >/dev/null 2>&1 || true
failed=0
for test in test-model-worker test-model-lifecycle; do
    log="$out/$test.log"
    if "$qa/Contents/MacOS/Auraliscope" -showWelcomeOnLaunch NO "--$test" > "$log" 2>&1; then
        echo "pass  --$test  ($(grep -c '^PASS' "$log") checks)"
    else
        echo "FAIL  --$test  ($log)"
        grep -E '^(FAIL|status|journal)' "$log" | head -4
        failed=1
    fi
done
exit $failed
