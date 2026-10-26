# Install Auraliscope 2.0 RC 3

## Installer

1. Download `Auraliscope 2.0 rc 3 build 120.pkg`. Quit Auraliscope, LABS and your DAW.
2. Open the package. If blocked, use System Settings → Privacy & Security → Open Anyway after checking the source.
   The installer is unsigned and not notarized. Administrator authentication takes place in macOS, never in chat.
3. Select the app, VST3 and/or Audio Unit. The app goes to `/Applications/Auraliscope.app`; plugins go to
   `/Library/Audio/Plug-Ins/VST3/Auraliscope Bridge.vst3` and
   `/Library/Audio/Plug-Ins/Components/Auraliscope Bridge.component`.
4. Open the app. For device capture, grant Microphone or Screen & System Audio Recording permission when requested.
   For Bridge, rescan plugins in the DAW, insert Auraliscope Bridge and click Open Auraliscope.

## Upgrades

The RC uses the normal Auraliscope identity and replaces Auraliscope 2.0 (build 91) and earlier releases at the
standard installation path, keeping their settings. On its first launch it also takes over every LABS setting that
Auraliscope never stored (layouts, panel settings, theme…). LABS itself stays installed until you remove it. Audio permissions may need to be granted again. Version 2.0 runs outside App Sandbox for
Bridge transport, so preferences from older sandboxed releases may need to be reconfigured.

Install the matching app and plugins together. The 2.0 plugins connect to the app over a separate socket from
LABS. Earlier LABS plugins are replaced at the same system plugin paths, preserving plugin IDs used in DAW projects.
User-installed copies under `~/Library/Audio/Plug-Ins` can shadow system copies: inspect and remove duplicates manually,
then rescan. The installer does not delete those copies, your LABS app, settings or DAW projects.

## Manual ZIP installation

Unzip the app into Applications. Unzip each plugin into the appropriate VST3 or Components directory under your user
`~/Library/Audio/Plug-Ins` or the system `/Library/Audio/Plug-Ins`. Use one location per format. Avoid mixing manual
user installs with the system installer. Redistribute GPL-covered copies with LICENSE, the included notices and the corresponding source as described in SOURCE_DISTRIBUTION.md. Image rights are tracked separately in ASSET_RIGHTS.md.

## Remove

Quit the app and DAW, then remove the app and plugin bundles from their installation locations. Settings and logs
remain in your Library; no project files or reports are deleted. LABS can be removed independently.
