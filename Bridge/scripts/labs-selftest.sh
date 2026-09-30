#!/bin/zsh
# Runs this build's Auraliscope Labs with diagnostics and the given self-test arguments (see BridgeSelfTest.swift),
# for checks in DAWs driven by hand. Nothing is selected from an earlier run unless --restore is given.
#
#   labs-selftest.sh --list-bridge-sources
#   labs-selftest.sh --bridge-selftest "<track name>" --expect-peak-db -6.02,-12.04 --compare-reference --then-controls
set -uo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/prototype-version.sh
app="$ABR_DIST/Auraliscope Labs.app/Contents/MacOS/Auraliscope"
if [[ " $* " == *" --restore "* ]]; then
    exec "$app" --diagnostic "$@" -showWelcomeOnLaunch NO
fi
exec "$app" --diagnostic "$@" -inputDeviceUID daw.00 -showWelcomeOnLaunch NO
