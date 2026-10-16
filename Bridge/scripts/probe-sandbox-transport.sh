#!/bin/zsh
# Production transport feasibility: can a sandboxed Auraliscope reach plugins running unsandboxed inside DAWs?
# Builds Bridge/Tools/SandboxTransportProbe.c twice into .build/bridge/sandbox-probe: once as a sandboxed app
# bundle with an application group (the receiver), once plain (the plugin), and runs them against each other.
#
#   probe-sandbox-transport.sh [signing identity]    default "-" (ad hoc); pass a team identity to repeat the test
#                                                   as a signed release would run (set ABR_PROBE_GROUP to its
#                                                   team-prefixed group, e.g. TEAMID.com.jinboz.SoundMeterJBZ)
set -euo pipefail
cd "${0:A:h:h:h}"
identity="${1:--}"
group="${ABR_PROBE_GROUP:-ABCDE12345.com.jinboz.SoundMeterJBZ.bridgeprobe}"
results=.build/bridge/sandbox-probe
mkdir -p "$results"
# Built and signed on the startup disk: codesign refuses the extended-attribute files an external volume adds.
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/Receiver.app/Contents/MacOS"
clang -O2 -Wall -framework CoreFoundation Bridge/Tools/SandboxTransportProbe.c -o "$out/plugin"
cp "$out/plugin" "$out/Receiver.app/Contents/MacOS/Receiver"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.jinboz.SoundMeterJBZ.bridgeprobe" \
    -c "Add :CFBundleExecutable string Receiver" -c "Add :CFBundlePackageType string APPL" \
    "$out/Receiver.app/Contents/Info.plist" > /dev/null
cat > "$out/receiver.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.application-groups</key><array><string>$group</string></array>
</dict></plist>
PLIST
codesign --force --sign "$identity" --entitlements "$out/receiver.entitlements" "$out/Receiver.app" 2> /dev/null
codesign --force --sign "$identity" "$out/plugin" 2> /dev/null
echo "signing: $identity; group: $group; $(sw_vers -productName) $(sw_vers -productVersion)"
"$out/Receiver.app/Contents/MacOS/Receiver" receiver "$group" 9 > "$out/receiver.txt" 2>&1 &
receiver=$!
sleep 2
"$out/plugin" plugin "$group" > "$out/plugin.txt" 2>&1
wait $receiver || true
cat "$out/receiver.txt" "$out/plugin.txt" | tee "$results/result.txt"
