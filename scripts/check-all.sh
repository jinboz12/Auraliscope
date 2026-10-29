#!/bin/zsh
# Runs the repository's checks in one go and prints one line per step: what ran, its exit status and time, and the
# log to read when it fails. Nothing here replaces the individual scripts; it only calls them in a fixed order.
#
#   scripts/check-all.sh           builds (debug, release), core checks, app feature checks, file analysis,
#                                  plugin-side analysis, spatial report, plugin transport
#   scripts/check-all.sh --quick   debug build and core checks only
#
# Logs: .build/check-all/<step>.log. Exit status: 0 when every step passed or was skipped, 1 otherwise. A step is
# skipped (not failed) when its environment is absent: no Metal device for the shader check. Steps that need hardware,
# a window, the VST3 SDK or a DAW (capture self-tests, snapshots, plugin builds, REAPER) are not part of it.
set -uo pipefail
cd "${0:A:h:h}"
# Every app launch below uses a QA identity and a private plugin socket (scripts/qa-env.sh).
source scripts/qa-env.sh
trap 'rm -rf "$QA_PRIVATE"' EXIT
logs=.build/check-all
mkdir -p "$logs"
failed=0
step() {
    local name=$1; shift
    local start=$SECONDS
    "$@" > "$logs/$name.log" 2>&1
    local rc=$?
    # 77: the step found its environment absent (scripts/check-shaders.sh: no Metal device). Not a failure.
    (( rc == 0 || rc == 77 )) || failed=1
    local result=FAIL
    (( rc == 0 )) && result=pass
    (( rc == 77 )) && result=skip
    printf '%-18s %-4s %4ds  %s\n' "$name" "$result" $(( SECONDS - start )) "$logs/$name.log"
}
step build-debug swift build
step shaders scripts/check-shaders.sh
step core-checks scripts/test.sh
if [[ "${1:-}" != "--quick" ]]; then
    step build-release swift build -c release
    step app-features scripts/check-app-features.sh
    step file-analysis scripts/check-file-analysis.sh
    step bridge-analysis Bridge/scripts/test-analysis.sh
    step spatial-report Bridge/scripts/check-spatial.sh
    step bridge-transport Bridge/scripts/test-transport.sh
fi
exit $failed
