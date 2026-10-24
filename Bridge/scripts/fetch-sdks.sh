#!/bin/zsh
# Downloads the two plugin SDKs the Bridge builds against into Bridge/ThirdParty (gitignored), pinned to exact
# commits. Tarballs rather than git clones: the repository lives on an exFAT volume, whose "._" side files corrupt
# git pack indexes.
#   VST3 SDK 3.8.0 build 66 (MIT): base, pluginterfaces and public.sdk at the commits that tag pins.
#   AudioUnitSDK 1.4.0 (Apache-2.0).
set -euo pipefail
cd "${0:A:h:h}"
third_party=ThirdParty
typeset -A pins=(
    vst3sdk/base            "steinbergmedia/vst3_base 3d2e82f8e6bff59c1d8b7a27491a29c2286b5206"
    vst3sdk/pluginterfaces  "steinbergmedia/vst3_pluginterfaces 31d6eeba6daaa3e2a8bfbe3e7a90ca0b7fbfbc1c"
    vst3sdk/public.sdk      "steinbergmedia/vst3_public_sdk a3911a4615dabbfdfd9d181ee26b05c70c289a95"
    AudioUnitSDK            "apple/AudioUnitSDK e789bc83ddc07cbf80e7bfaf84f1ade975287400"
)
mkdir -p "$third_party"
for destination in ${(k)pins}; do
    parts=(${=pins[$destination]})
    repository=$parts[1] commit=$parts[2]
    target="$third_party/$destination"
    if [[ -f "$target/.pinned" && "$(<"$target/.pinned")" == "$commit" ]]; then continue; fi
    rm -rf "$target"
    mkdir -p "$target"
    echo "Fetching $repository @ ${commit:0:12}"
    curl -fsSL "https://codeload.github.com/$repository/tar.gz/$commit" | tar -xz --strip-components 1 -C "$target"
    find "$target" -name '._*' -delete
    echo "$commit" > "$target/.pinned"
done
echo "SDKs ready in Bridge/$third_party"
