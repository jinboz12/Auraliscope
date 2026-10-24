#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
out=.build/app-feature-checks
mkdir -p "$out"
swiftc -O -swift-version 5 -module-cache-path "$out/modules" \
    Sources/Auraliscope/GitHubUpdateCore.swift Sources/Auraliscope/PanelRenderPolicy.swift Sources/Auraliscope/MultiFFTLayoutPolicy.swift \
    Tests/AppFeatureChecks.swift -o "$out/AppFeatureChecks"
"$out/AppFeatureChecks" "$@"
