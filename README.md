# Auraliscope

Auraliscope is a native macOS audio meter for live input and output monitoring. It brings spectrum, spectrogram, waveform, loudness, channel levels, soundstage, and correlation into one resizable window. The interface supports English, Simplified Chinese, and Korean.

**Current public candidate:** 1.0.0rc (build 8). Earlier 1.0/1.1 beta labels were internal development versions.

## Features

- Monitor a Core Audio input, or an output through a Core Audio process tap on macOS 14.2 or later.
- Choose Mono, Stereo, or a multichannel layout through 9.1.6; route up to 64 physical channels to speaker roles.
- View 8192-point L/R spectrum and scrolling spectrogram, per-channel waveforms and peak/RMS levels, LUFS, loudness range, True Peak, VU, and stereo correlation.
- Switch between system-following, light, and dark appearances. The dashboard keeps its panel layout and native Liquid Glass controls where macOS supports them.
- Analyze audio in memory. The app does not save or upload audio.

## Requirements and permissions

The packaged build targets Apple Silicon and macOS 13 or later. Input monitoring needs **Microphone** permission. Output monitoring needs macOS 14.2 or later and **System Audio Recording** permission; macOS requests it when the selected output tap begins capture. The welcome screen offers a separate action for each source type. The app does not request screen image capture, Accessibility, Automation, or network permissions.

## Build locally

Install Apple Command Line Tools, then run:

```sh
./scripts/test.sh
./scripts/package-app.sh
open "dist/1.0.0rc/Auraliscope.app"
```

The packaging script creates `dist/1.0.0rc/Auraliscope.app` and `dist/1.0.0rc/Auraliscope-1.0.0rc-macOS.zip`. It uses a local ad hoc signature. This private release candidate is ad hoc signed and is intended for testing. It is not notarized, so macOS may block it on another Mac; check System Settings → Privacy & Security for the system-provided Open Anyway option. A future general-distribution build needs Developer ID signing and Apple notarization.

`./scripts/brand-assets.sh` rebuilds the app icon from `SoundmeterIcon/soundmeter Exports/soundmeter-macOS-Default-1024@1x.png` when needed. The vector brand mark used in the interface is defined in Swift.

## Project files

- `Sources/Auraliscope/`: SwiftUI interface, audio capture, DSP, and Metal renderers.
- `Sources/AudioRing/`: C audio callback and lock-free buffers.
- `Resources/`: app metadata, entitlements, icon, and three localizations.
- `Tests/AuraliscopeTests/`: core audio and DSP checks.
- `scripts/`: packaging, asset generation, localization checks, and tests.
- `docs/THIRD_PARTY_NOTICES.md`: attribution and bundled third-party license text.

Copyright © 2026 JINBOZ. All rights reserved. No project-level license is granted. The bundled third-party notice applies only to the listed third-party work.
