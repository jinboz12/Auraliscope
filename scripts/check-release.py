#!/usr/bin/env python3
"""Check the app/plugin release identity before assembling distributable assets."""
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parents[1]
label, version, build, plugin_version = subprocess.check_output(
    ['zsh', '-c', 'source Bridge/scripts/release-version.sh; print -l "$ABR_LABEL" "$ABR_VERSION" "$ABR_BUILD" "$ABR_PLUGIN_BUNDLE_VERSION"'],
    cwd=root, text=True).splitlines()
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
assert info['AuraliscopeVersionLabel'] == label
assert info['CFBundleShortVersionString'] == version
assert info['CFBundleVersion'] == build
assert info['CFBundleIdentifier'] == 'com.jinboz.SoundMeterJBZ'
assert info['CFBundleDisplayName'] == info['CFBundleName'] == 'Auraliscope'
assert plugin_version == f'{version}.{build}'
assert plistlib.loads((root / 'Bridge/App/Info.plist').read_bytes()) == info
assert 'Resources/Info.plist' in (root / 'Package.swift').read_text()
print(f'PASS: Auraliscope {label} build {build}, Bridge {plugin_version}; release identity synchronized')
