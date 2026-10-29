#!/bin/zsh
# Builds the iPad phase's test VST3, "Auraliscope Bridge Dev.vst3" (its own class ID, name and window class, so a host
# loads it beside an installed Auraliscope Bridge), labelled "2.1 iPad dev build 1", into .build/bridge/dev/. Its
# objects go to .build/bridge/obj-ipad-dev and the release-format bundles it builds on the way to
# .build/bridge/ipad-dev-dist: nothing is installed, and the released Build 120 artifacts are never written.
set -euo pipefail
cd "${0:A:h:h:h}"
export ABR_VERSION_FILE=Bridge/scripts/ipad-dev-version.sh
export ABR_OBJ=.build/bridge/obj-ipad-dev
export ABR_DIST="$PWD/.build/bridge/ipad-dev-dist"
zsh Bridge/scripts/build-dev-vst3.sh
