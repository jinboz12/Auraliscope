#!/bin/zsh
# Headless Metal check: compiles the canvases' shader library and builds every pipeline state (`--check-shaders`).
# It proves compilation and struct layout only; it draws no frame. Exit status: 0 pass, 1 fail, 77 skipped (no Metal
# device on this machine).
set -euo pipefail
cd "${0:A:h:h}"
swift build
.build/debug/Auraliscope --check-shaders
