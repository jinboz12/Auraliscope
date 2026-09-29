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
        [[ -d "$folder/Auraliscope Labs.app" ]] && { "$lsregister" -u "$folder/Auraliscope Labs.app" || true; rm -rf "$folder/Auraliscope Labs.app"; echo "Removed $folder/Auraliscope Labs.app"; }
    done
    exit 0
fi
target="$HOME/Applications"; [[ "${1:-}" == "--system" ]] && target=/Applications
mkdir -p "$target"
rm -rf "$target/Auraliscope Labs.app"
ditto --norsrc "$ABR_DIST/Auraliscope Labs.app" "$target/Auraliscope Labs.app"
find "$target/Auraliscope Labs.app" -name '._*' -delete
xattr -cr "$target/Auraliscope Labs.app"
codesign --verify --strict "$target/Auraliscope Labs.app"
"$lsregister" -f "$target/Auraliscope Labs.app"
echo "Installed $target/Auraliscope Labs.app"
