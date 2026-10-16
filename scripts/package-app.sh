#!/bin/zsh
# Build the complete public app and Bridge distribution.
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/check-release.py
python3 scripts/check-localization.py
Bridge/scripts/build-app.sh
Bridge/scripts/build-plugins.sh
Bridge/scripts/package-installer.sh
Bridge/scripts/package-dist.sh
