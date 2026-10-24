#!/bin/zsh
# Completes the RC distribution after build-app.sh and build-plugins.sh: documentation and
# one zip per bundle (made and checked locally so the external volume's "._" files never get in),
# and SHA256SUMS.txt. Nothing is uploaded or published.
set -euo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/release-version.sh
dist="$ABR_DIST"
for bundle in "Auraliscope.app" "Auraliscope Bridge.vst3" "Auraliscope Bridge.component"; do
    [[ -d "$dist/$bundle" ]] || { echo "missing $dist/$bundle: build it first" >&2; exit 1; }
done
cp docs/2.0_RC2_RELEASE_NOTES.md docs/MULTIFFT_ARCHITECTURE.md LICENSE COPYRIGHT.md docs/THIRD_PARTY_NOTICES.md docs/INSTALLATION.md docs/LOUDNESS_REFERENCES.md docs/2.0_RC1_RELEASE_NOTES.md docs/UPDATE_LOG_since_1.2.2.md docs/SOURCE_DISTRIBUTION.md docs/ASSET_RIGHTS.md "$dist/"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
for bundle in "Auraliscope.app" "Auraliscope Bridge.vst3" "Auraliscope Bridge.component"; do
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
(cd "$dist" && shasum -a 256 LICENSE *.pkg(N) *.zip *.md > SHA256SUMS.txt)
cat "$dist/SHA256SUMS.txt"
