#!/bin/zsh
# Legacy command name: installs the public Auraliscope app, replacing the copy at the selected location:
# ~/Applications by default, /Applications with --system; --uninstall removes it from both. Registers it with
# Launch Services, so a plugin's "Open Auraliscope" button can find it.
set -euo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/release-version.sh
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ "${1:-}" == "--uninstall" ]]; then
    for folder in "$HOME/Applications" /Applications; do
        [[ -d "$folder/Auraliscope.app" ]] && { "$lsregister" -u "$folder/Auraliscope.app" || true; rm -rf "$folder/Auraliscope.app"; echo "Removed $folder/Auraliscope.app"; }
    done
    exit 0
fi
target="$HOME/Applications"; [[ "${1:-}" == "--system" ]] && target=/Applications
mkdir -p "$target"
rm -rf "$target/Auraliscope.app"
ditto --norsrc "$ABR_DIST/Auraliscope.app" "$target/Auraliscope.app"
find "$target/Auraliscope.app" -name '._*' -delete
xattr -cr "$target/Auraliscope.app"
codesign --verify --strict "$target/Auraliscope.app"
"$lsregister" -f "$target/Auraliscope.app"
echo "Installed $target/Auraliscope.app"
