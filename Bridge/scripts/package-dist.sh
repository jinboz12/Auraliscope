#!/bin/zsh
# Completes the experimental distribution folder after build-plugins.sh and build-labs-app.sh: documentation, the Labs
# icon, one zip per bundle (made and checked on the local disk, so the external volume's "._" files never get in),
# and SHA256SUMS.txt. Nothing is uploaded or published.
set -euo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/prototype-version.sh
dist="$ABR_DIST"
for bundle in "Auraliscope LABS.app" "Auraliscope Bridge.vst3" "Auraliscope Bridge.component"; do
    [[ -d "$dist/$bundle" ]] || { echo "missing $dist/$bundle: build it first" >&2; exit 1; }
done
cp Bridge/README.md Bridge/ARCHITECTURE.md Bridge/PROTOCOL.md Bridge/VALIDATION.md Bridge/TESTING-zh.md Bridge/THIRD_PARTY_NOTICES.md "$dist/"
cp Bridge/App/Icon/AuraliscopeLabs-1024.png "$dist/"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
for bundle in "Auraliscope LABS.app" "Auraliscope Bridge.vst3" "Auraliscope Bridge.component"; do
    ditto --norsrc "$dist/$bundle" "$stage/$bundle"
    find "$stage/$bundle" -name '._*' -delete
    # The external volume reports folders as owner-only; unzipped as such, other users could not open the bundle.
    chmod -R u+rwX,go+rX,go-w "$stage/$bundle"
    codesign --verify --strict "$stage/$bundle"
    ditto -c -k --norsrc --keepParent "$stage/$bundle" "$stage/$bundle.zip"
    mkdir -p "$stage/check"
    ditto -x -k "$stage/$bundle.zip" "$stage/check"
    codesign --verify --strict "$stage/check/$bundle"
    diff -r "$stage/$bundle" "$stage/check/$bundle" >/dev/null
    rm -rf "$stage/check"
    cp "$stage/$bundle.zip" "$dist/"
    echo "zipped and verified: $bundle"
done
find "$dist" -name '._*' -delete
(cd "$dist" && shasum -a 256 *.pkg(N) *.zip *.md *.png > SHA256SUMS.txt)
cat "$dist/SHA256SUMS.txt"
