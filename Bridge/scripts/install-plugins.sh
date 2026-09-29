#!/bin/zsh
# Installs (or with --uninstall removes) the prototype plugins for the current user only:
#   ~/Library/Audio/Plug-Ins/VST3/Auraliscope Bridge.vst3
#   ~/Library/Audio/Plug-Ins/Components/Auraliscope Bridge.component
# Then restarts the per-user Audio Unit registrar so hosts and auval see the change without logging out.
set -euo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/prototype-version.sh
vst3_dir="$HOME/Library/Audio/Plug-Ins/VST3"
au_dir="$HOME/Library/Audio/Plug-Ins/Components"
if [[ "${1:-}" == "--uninstall" ]]; then
    rm -rf "$vst3_dir/Auraliscope Bridge.vst3" "$au_dir/Auraliscope Bridge.component"
    echo "Removed Auraliscope Bridge from $vst3_dir and $au_dir"
else
    [[ -d "$ABR_DIST/Auraliscope Bridge.vst3" ]] || { echo "Build first: Bridge/scripts/build-plugins.sh" >&2; exit 1; }
    mkdir -p "$vst3_dir" "$au_dir"
    for name in "Auraliscope Bridge.vst3:$vst3_dir" "Auraliscope Bridge.component:$au_dir"; do
        bundle="${name%%:*}" target="${name#*:}"
        rm -rf "$target/$bundle"
        ditto --norsrc "$ABR_DIST/$bundle" "$target/$bundle"
        # experimental-dist sits on an exFAT volume, whose "._" side files arrive as ordinary files.
        find "$target/$bundle" -name '._*' -delete
        xattr -cr "$target/$bundle"
        codesign --verify --strict "$target/$bundle"
        echo "Installed $target/$bundle"
    done
fi
killall -q AudioComponentRegistrar 2>/dev/null || true
