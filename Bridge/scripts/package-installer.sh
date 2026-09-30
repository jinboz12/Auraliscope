#!/bin/zsh
# Builds the early-test installer after build-plugins.sh and build-labs-app.sh:
#   experimental-dist/Auraliscope LABS <label> build <n>/Auraliscope LABS <label> build <n>.pkg
# One package, three choices (all selected), for every user of the Mac:
#   /Applications/Auraliscope LABS.app                          (independent of Auraliscope: own name and bundle ID)
#   /Library/Audio/Plug-Ins/VST3/Auraliscope Bridge.vst3
#   /Library/Audio/Plug-Ins/Components/Auraliscope Bridge.component
# The plugins are installed where, and under the names and bundle IDs, an official Auraliscope Bridge release would
# use, with bundle versions below any release (0.<build>, prototype-version.sh), so an official installer replaces
# them; this package never replaces a newer plugin. Nothing is relocated to another copy Launch Services knows of.
# Unsigned (no Developer ID on this Mac): Gatekeeper asks for Open Anyway. Nothing is uploaded or published.
set -euo pipefail
cd "${0:A:h:h:h}"
source Bridge/scripts/prototype-version.sh
dist="$ABR_DIST"
name="Auraliscope LABS $ABR_LABEL build $ABR_BUILD"
for bundle in "Auraliscope LABS.app" "Auraliscope Bridge.vst3" "Auraliscope Bridge.component"; do
    [[ -d "$dist/$bundle" ]] || { echo "missing $dist/$bundle: build it first" >&2; exit 1; }
done
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$dist/Auraliscope LABS.app/Contents/Info.plist")"
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
    codesign --verify --strict "$root/$bundle"
    pkgbuild --analyze --root "$root" "$stage/$identifier.plist" >/dev/null
    # Installed exactly here: never "upgrade" a copy elsewhere (a test build in Downloads, a build folder).
    plutil -replace 0.BundleIsRelocatable -bool NO "$stage/$identifier.plist"
    plutil -replace 0.BundleIsVersionChecked -bool YES "$stage/$identifier.plist"
    plutil -replace 0.BundleOverwriteAction -string upgrade "$stage/$identifier.plist"
    local scripts=()
    [[ -d "$stage/scripts-$identifier" ]] && scripts=(--scripts "$stage/scripts-$identifier")
    pkgbuild --root "$root" --component-plist "$stage/$identifier.plist" --install-location "$location" \
        --identifier "$identifier" --version "$version" $scripts "$stage/$identifier.pkg" >/dev/null
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

component "Auraliscope LABS.app" /Applications com.jinboz.SoundMeterJBZ.Labs "$ABR_VERSION.$ABR_BUILD"
component "Auraliscope Bridge.vst3" /Library/Audio/Plug-Ins/VST3 com.jinboz.AuraliscopeBridge.vst3 "$ABR_PLUGIN_BUNDLE_VERSION"
component "Auraliscope Bridge.component" /Library/Audio/Plug-Ins/Components com.jinboz.AuraliscopeBridge.component "$ABR_PLUGIN_BUNDLE_VERSION"

mkdir -p "$stage/resources"
cat > "$stage/resources/welcome.html" <<EOF
<html><body style="font-family: -apple-system, sans-serif; font-size: 13px">
<p><b>$name</b> · <span style="color:#b8862e"><b>Prototype experiment only</b></span></p>
<p>An early test build. It installs, for every user of this Mac:</p>
<ul>
<li><b>Auraliscope LABS</b> in Applications: the test app. It is separate from Auraliscope (its own name, settings and
privacy permissions), so both can be installed and used side by side.</li>
<li><b>Auraliscope Bridge</b> VST3 and Audio Unit plugins in /Library/Audio/Plug-Ins. Each insert measures its own audio
inside your DAW; Auraliscope LABS shows the results. Audio passes through unchanged.</li>
</ul>
<p>In Auraliscope LABS, Settings → Audio → <b>Source type</b> chooses between your <b>Audio devices</b> (inputs, or what
apps play to an output, as in Auraliscope) and <b>Host plugins</b> (the Bridge inserts in your DAW).</p>
<p>A later official Auraliscope Bridge installer replaces these test plugins. Requires macOS 13 or later on Apple silicon.</p>
</body></html>
EOF
cat > "$stage/resources/readme.html" <<EOF
<html><body style="font-family: -apple-system, sans-serif; font-size: 13px">
<p><b>After installing</b>: rescan plugins in your DAW if it was open, insert <i>Auraliscope Bridge</i> on a track, bus or
master, and click <i>Open Auraliscope LABS</i> in the plugin window.</p>
<p><b>Earlier test builds</b>: remove any Auraliscope Bridge copies from ~/Library/Audio/Plug-Ins (VST3 and Components)
and older Auraliscope LABS copies, so hosts and macOS see only this build.</p>
<p><b>To uninstall</b>, delete /Applications/Auraliscope LABS.app, /Library/Audio/Plug-Ins/VST3/Auraliscope Bridge.vst3 and
/Library/Audio/Plug-Ins/Components/Auraliscope Bridge.component.</p>
<p>Not for distribution. Nothing is recorded or uploaded.</p>
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
    <choice id="app" title="Auraliscope LABS (app)" description="The test app, in Applications. Independent of Auraliscope.">
        <pkg-ref id="com.jinboz.SoundMeterJBZ.Labs"/>
    </choice>
    <choice id="vst3" title="Auraliscope Bridge VST3" description="The VST3 plugin, in /Library/Audio/Plug-Ins/VST3.">
        <pkg-ref id="com.jinboz.AuraliscopeBridge.vst3"/>
    </choice>
    <choice id="au" title="Auraliscope Bridge Audio Unit" description="The Audio Unit, in /Library/Audio/Plug-Ins/Components.">
        <pkg-ref id="com.jinboz.AuraliscopeBridge.component"/>
    </choice>
    <pkg-ref id="com.jinboz.SoundMeterJBZ.Labs" version="$ABR_VERSION.$ABR_BUILD">com.jinboz.SoundMeterJBZ.Labs.pkg</pkg-ref>
    <pkg-ref id="com.jinboz.AuraliscopeBridge.vst3" version="$ABR_PLUGIN_BUNDLE_VERSION">com.jinboz.AuraliscopeBridge.vst3.pkg</pkg-ref>
    <pkg-ref id="com.jinboz.AuraliscopeBridge.component" version="$ABR_PLUGIN_BUNDLE_VERSION">com.jinboz.AuraliscopeBridge.component.pkg</pkg-ref>
</installer-gui-script>
EOF
productbuild --distribution "$stage/distribution.xml" --resources "$stage/resources" --package-path "$stage" \
    "$stage/$name.pkg" >/dev/null

# Check: the payload is the three bundles, byte for byte, still validly signed, installed where intended.
mkdir -p "$stage/check"
pkgutil --expand-full "$stage/$name.pkg" "$stage/check/pkg"
for entry in "com.jinboz.SoundMeterJBZ.Labs.pkg:Auraliscope LABS.app" "com.jinboz.AuraliscopeBridge.vst3.pkg:Auraliscope Bridge.vst3" \
             "com.jinboz.AuraliscopeBridge.component.pkg:Auraliscope Bridge.component"; do
    part="${entry%%:*}" bundle="${entry#*:}"
    payload="$stage/check/pkg/$part/Payload/$bundle"
    codesign --verify --strict "$payload"
    diff -r "$stage/root-${part%.pkg}/$bundle" "$payload" >/dev/null
    if grep -q "<relocate>" "$stage/check/pkg/$part/PackageInfo"; then echo "$bundle is relocatable" >&2; exit 1; fi
    echo "checked $bundle: identical, signature valid, not relocatable"
done
cp "$stage/$name.pkg" "$dist/"
find "$dist" -name '._*' -delete
echo "$dist/$name.pkg"
