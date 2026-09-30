#!/bin/zsh
# Installs Auraliscope Labs beside Auraliscope (different name and bundle ID, so neither replaces the other):
# ~/Applications by default, /Applications with --system; --uninstall removes it from both. Registers it with
# Launch Services, so a plugin's "Open Auraliscope Labs" button can find it.
set -euo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/prototype-version.sh
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ "${1:-}" == "--uninstall" ]]; then
    for folder in "$HOME/Applications" /Applications; do
        [[ -d "$folder/Auraliscope LABS.app" ]] && { "$lsregister" -u "$folder/Auraliscope LABS.app" || true; rm -rf "$folder/Auraliscope LABS.app"; echo "Removed $folder/Auraliscope LABS.app"; }
    done
    exit 0
fi
target="$HOME/Applications"; [[ "${1:-}" == "--system" ]] && target=/Applications
mkdir -p "$target"
rm -rf "$target/Auraliscope LABS.app"
ditto --norsrc "$ABR_DIST/Auraliscope LABS.app" "$target/Auraliscope LABS.app"
find "$target/Auraliscope LABS.app" -name '._*' -delete
xattr -cr "$target/Auraliscope LABS.app"
codesign --verify --strict "$target/Auraliscope LABS.app"
"$lsregister" -f "$target/Auraliscope LABS.app"
echo "Installed $target/Auraliscope LABS.app"
