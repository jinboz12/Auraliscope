# Sourced by the scripts that launch the app, so a check never touches the person's own Auraliscope:
# - `qa_bundle <binary> <bundle path>` wraps a built executable in a QA-identity bundle (com.jinboz.SoundMeterJBZ.QA):
#   its preferences domain, diagnostic log and settings presets are separate from the user's (DiagnosticLog,
#   SettingsPresets), and it makes no update check (UpdateLaunchCheck);
# - the plugin socket is private (AURALISCOPE_BRIDGE_SOCKET), so DAW inserts never connect to a test app, unless the
#   caller already chose one;
# - `qa_demo_wrapper <bundle path> <wrapper path>` writes an executable that runs the bundle with --demo (no audio
#   device opened), for scripts that take a binary (check-file-analysis.sh).
# The caller removes $QA_PRIVATE (a temporary folder) when it exits: `trap 'rm -rf "$QA_PRIVATE"' EXIT`.
QA_PRIVATE="$(mktemp -d /tmp/auraliscope-qa-XXXXXX)"
export AURALISCOPE_BRIDGE_SOCKET="${AURALISCOPE_BRIDGE_SOCKET:-$QA_PRIVATE/bridge.sock}"

qa_bundle() {
    local binary="$1" bundle="$2"
    rm -rf "$bundle"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    cp Resources/Info.plist "$bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.jinboz.SoundMeterJBZ.QA" "$bundle/Contents/Info.plist"
    cp Resources/Auraliscope.icns "$bundle/Contents/Resources/"
    cp -R Resources/Localization/*.lproj "$bundle/Contents/Resources/"
    cp "$binary" "$bundle/Contents/MacOS/Auraliscope"
    codesign --force --sign - "$bundle" >/dev/null 2>&1 || true
}

qa_demo_wrapper() {
    local bundle="$1" wrapper="$2"
    printf '#!/bin/zsh\nexec "%s/Contents/MacOS/Auraliscope" --demo "$@"\n' "${bundle:A}" > "$wrapper"
    chmod +x "$wrapper"
}
