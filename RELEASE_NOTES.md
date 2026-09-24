# Auraliscope 1.0.0rc

This is the first 1.0.0 release candidate, shared as a private, unnotarized test build. Earlier version numbers were used for internal development.

## Highlights

- A single resizable meter window for spectrum, spectrogram, per-channel waveforms, loudness, channel levels, soundstage, and correlation.
- Input monitoring and macOS 14.2+ output monitoring through a Core Audio process tap, with source-specific permission actions on the welcome screen.
- Mono, Stereo, and multichannel layouts through 9.1.6, with manual routing from up to 64 physical channels.
- System-following appearance plus manual light and dark modes. Native Liquid Glass controls on supported macOS releases.
- English, Simplified Chinese, and Korean interface text.
- Fixed the Settings Channels layout so controls stay in the detail column instead of sliding under the sidebar at the minimum window size.

## Requirements

Apple Silicon, macOS 13 or later. Output capture requires macOS 14.2 or later and System Audio Recording permission; input capture requires Microphone permission.

## Validation

27 core checks and 173 localization keys in each of three languages pass. The packaged app's code signature and archive integrity are checked. Live output capture after granting System Audio Recording, all supported macOS releases, and real multichannel routing remain release-machine validation items.

## Test-build notice

This archive is ad hoc signed and has not been notarized by Apple. macOS may block it when downloaded on another Mac. It is intended only for invited testers. It does not include a project-level source license.
