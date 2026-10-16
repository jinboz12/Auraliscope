#!/bin/zsh
# Public installer: app plus optional VST3 and Audio Unit components.
set -euo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/release-version.sh
python3 scripts/check-release.py
dist="$ABR_DIST"
name="Auraliscope $ABR_LABEL build $ABR_BUILD"
for bundle in "Auraliscope.app" "Auraliscope Bridge.vst3" "Auraliscope Bridge.component"; do
    [[ -d "$dist/$bundle" ]] || { echo "missing $dist/$bundle: build it first" >&2; exit 1; }
done
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$dist/Auraliscope.app/Contents/Info.plist")"
[[ "$app_build" == "$ABR_BUILD" ]] || { echo "app build $app_build is not $ABR_BUILD: update Bridge/App/Info.plist" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
# component <bundle> <install location> <package identifier> <version>
component() {
    local bundle="$1" location="$2" identifier="$3" version="$4"
    local root="$stage/root-$identifier"
    mkdir -p "$root"
    ditto --norsrc "$dist/$bundle" "$root/$bundle"
    find "$root" -name '._*' -delete
    xattr -cr "$root/$bundle"
    # The external volume reports every folder as owner-only (drwx------); installed that way under root, no user
    # could open the app or read the plugins. Everyone reads and opens, only the owner writes.
    chmod -R u+rwX,go+rX,go-w "$root"
    codesign --verify --strict "$root/$bundle"
    pkgbuild --analyze --root "$root" "$stage/$identifier.plist" >/dev/null
    # Installed exactly here: never "upgrade" a copy elsewhere (a test build in Downloads, a build folder).
    plutil -replace 0.BundleIsRelocatable -bool NO "$stage/$identifier.plist"
    plutil -replace 0.BundleIsVersionChecked -bool YES "$stage/$identifier.plist"
    plutil -replace 0.BundleOverwriteAction -string upgrade "$stage/$identifier.plist"
    local scripts=()
    [[ -d "$stage/scripts-$identifier" ]] && scripts=(--scripts "$stage/scripts-$identifier")
    pkgbuild --root "$root" --ownership recommended --component-plist "$stage/$identifier.plist" --install-location "$location" \
        --identifier "$identifier" --version "$version" $scripts "$stage/$identifier.pkg" >/dev/null
    # pkgbuild turns every extended attribute into a "._" entry, and the com.apple.provenance attribute macOS puts on
    # files written here cannot be removed; installed, those entries break the bundles' sealed signatures. So the
    # payload is rewritten without attributes (root:wheel, the files' own modes) and the file list to match.
    local expanded="$stage/expanded-$identifier"
    pkgutil --expand "$stage/$identifier.pkg" "$expanded"
    python3 Bridge/scripts/payload-cpio.py "$root" "$expanded/Payload"
    lsbom "$expanded/Bom" | grep -v '/\._' > "$stage/$identifier.files"
    rm "$expanded/Bom" "$stage/$identifier.pkg"
    mkbom -i "$stage/$identifier.files" "$expanded/Bom"
    pkgutil --flatten "$expanded" "$stage/$identifier.pkg"
    echo "component $identifier $version → $location/$bundle"
}
# Hosts and auval see a new or replaced Audio Unit at once when the registrars restart.
mkdir -p "$stage/scripts-com.jinboz.AuraliscopeBridge.component"
cat > "$stage/scripts-com.jinboz.AuraliscopeBridge.component/postinstall" <<'EOF'
#!/bin/sh
killall -q AudioComponentRegistrar 2>/dev/null
exit 0
EOF
chmod +x "$stage/scripts-com.jinboz.AuraliscopeBridge.component/postinstall"

component "Auraliscope.app" /Applications com.jinboz.SoundMeterJBZ "$ABR_VERSION.$ABR_BUILD"
component "Auraliscope Bridge.vst3" /Library/Audio/Plug-Ins/VST3 com.jinboz.AuraliscopeBridge.vst3 "$ABR_PLUGIN_BUNDLE_VERSION"
component "Auraliscope Bridge.component" /Library/Audio/Plug-Ins/Components com.jinboz.AuraliscopeBridge.component "$ABR_PLUGIN_BUNDLE_VERSION"

mkdir -p "$stage/resources"
cat > "$stage/resources/welcome.html" <<EOF
<html><body style="font-family: -apple-system, sans-serif; font-size: 13px">
<h2>$name</h2>
<p>Audio metering, spatial analysis and loudness reports for macOS.</p>
<p>Choose the app and the plugin formats you use. The app installs in Applications; VST3 and Audio Unit plugins
install in /Library/Audio/Plug-Ins. Requires Apple silicon and macOS 13 or later.</p>
<p>Quit Auraliscope and your DAW before installing. This updates the normal Auraliscope app and earlier Bridge
plugins. Auraliscope LABS remains separate and is not removed.</p>
<p>Copyright © 2026 JINBOZ. All rights reserved. This package is unsigned and not notarized.</p>
</body></html>
EOF
cat > "$stage/resources/readme.html" <<EOF
<html><body style="font-family: -apple-system, sans-serif; font-size: 13px">
<p><b>Start</b>: open Auraliscope, choose Audio devices or Host plugins in Settings → Audio.
For a DAW source, insert Auraliscope Bridge and click Open Auraliscope.</p>
<p><b>Upgrading from LABS</b>: install both app and plugins. LABS settings remain separate. Remove duplicate Bridge
copies from your user Library only after confirming their location; rescan plugins in your DAW.</p>
<p><b>First launch</b>: if macOS blocks the download, use System Settings → Privacy &amp; Security → Open Anyway
for this package after verifying its source. Audio permissions are requested when needed.</p>
<p><b>Uninstall</b>: remove /Applications/Auraliscope.app and the Auraliscope Bridge bundles from
/Library/Audio/Plug-Ins/VST3 and /Library/Audio/Plug-Ins/Components.</p>
<p>Live audio is analyzed in memory. Reports and images are saved only when requested.</p>
</body></html>
EOF
cat > "$stage/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>$name</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <readme file="readme.html" mime-type="text/html"/>
    <options customize="allow" require-scripts="false" hostArchitectures="arm64" rootVolumeOnly="true"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check><allowed-os-versions><os-version min="13.0"/></allowed-os-versions></volume-check>
    <choices-outline>
        <line choice="app"/>
        <line choice="vst3"/>
        <line choice="au"/>
    </choices-outline>
    <choice id="app" title="Auraliscope (app)" description="The audio meter, in Applications. Updates earlier normal releases.">
        <pkg-ref id="com.jinboz.SoundMeterJBZ"/>
    </choice>
    <choice id="vst3" title="Auraliscope Bridge VST3" description="The VST3 plugin, in /Library/Audio/Plug-Ins/VST3.">
        <pkg-ref id="com.jinboz.AuraliscopeBridge.vst3"/>
    </choice>
    <choice id="au" title="Auraliscope Bridge Audio Unit" description="The Audio Unit, in /Library/Audio/Plug-Ins/Components.">
        <pkg-ref id="com.jinboz.AuraliscopeBridge.component"/>
    </choice>
    <pkg-ref id="com.jinboz.SoundMeterJBZ" version="$ABR_VERSION.$ABR_BUILD">com.jinboz.SoundMeterJBZ.pkg</pkg-ref>
    <pkg-ref id="com.jinboz.AuraliscopeBridge.vst3" version="$ABR_PLUGIN_BUNDLE_VERSION">com.jinboz.AuraliscopeBridge.vst3.pkg</pkg-ref>
    <pkg-ref id="com.jinboz.AuraliscopeBridge.component" version="$ABR_PLUGIN_BUNDLE_VERSION">com.jinboz.AuraliscopeBridge.component.pkg</pkg-ref>
</installer-gui-script>
EOF
productbuild --distribution "$stage/distribution.xml" --resources "$stage/resources" --package-path "$stage" \
    "$stage/$name.pkg" >/dev/null

# Check: the payload is the three bundles, byte for byte, still validly signed, installed where intended.
mkdir -p "$stage/check"
pkgutil --expand-full "$stage/$name.pkg" "$stage/check/pkg"
for entry in "com.jinboz.SoundMeterJBZ.pkg:Auraliscope.app" "com.jinboz.AuraliscopeBridge.vst3.pkg:Auraliscope Bridge.vst3" \
             "com.jinboz.AuraliscopeBridge.component.pkg:Auraliscope Bridge.component"; do
    part="${entry%%:*}" bundle="${entry#*:}"
    payload="$stage/check/pkg/$part/Payload/$bundle"
    codesign --verify --strict "$payload"
    diff -r "$stage/root-${part%.pkg}/$bundle" "$payload" >/dev/null
    if grep -q "<relocate>" "$stage/check/pkg/$part/PackageInfo"; then echo "$bundle is relocatable" >&2; exit 1; fi
    # What the installer writes: every item readable (and every folder openable) by all users, no "._" files.
    bom="$stage/check/pkg/$part/Bom"
    if lsbom -p f "$bom" | grep -q '/\._'; then echo "$bundle carries ._ files" >&2; exit 1; fi
    if lsbom -p M "$bom" | grep -qvE '^.r..r..r'; then echo "$bundle has items other users cannot read" >&2; exit 1; fi
    echo "checked $bundle: identical, signature valid, not relocatable, readable by all users, no ._ files"
done
cp "$stage/$name.pkg" "$dist/"
find "$dist" -name '._*' -delete
echo "$dist/$name.pkg"
