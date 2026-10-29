# Auraliscope

**Real-time audio analysis for macOS from mono, stereo to 9.1.6, live, from daw or from a audio file.**

Auraliscope shows loudness, levels, spectrum, spectrogram, waveform and the spatial image of your audio in one window
while you listen. Meter any input, anything your Mac plays, or a DAW track through the Auraliscope Bridge plugin.
Analyse a whole file and get a printable loudness and master report.


## Features

**Loudness.** Momentary, short-term and integrated LUFS, loudness range, true peak and a VU meter. Readings are
checked against 14 delivery standards or your own target and ceiling, which you can type in directly. Options include
LU or LUFS, EBU +9/+18 scales, an overs counter and history from 15 s to the whole session. Passes EBU Tech 3341 and
3342 test cases.

**Spectrum and spectrogram.** One logarithmic frequency axis with a piano keyboard and note names on hover. The
display offers colour maps, Enhanced (reassigned) and 3D views, peak holds and an average spectrum. The optional
**Multi-FFT Spectrum (Beta)** fuses three FFT sizes into one calibrated curve, sharp in the bass and fast in the treble.

**Soundstage.** Stereo shows a stereometer (full band, 3 or 5 bands) with balance, width and per-band correlation.
Immersive shows a dome you can orbit, where each frequency band glows where its speakers place it. Formats go up to
9.1.6, or you can define your own speaker layout.

**Levels and waveform.** Peak and RMS per channel with holds and over warnings. Exact sample-peak waveforms over
2, 4 or 8 s.

**File analysis and reports.** Analyze Audio File… (⌘O) measures WAV, AIFF, CAF, MP3, AAC, ALAC, FLAC and more,
mono to 9.1.6. A five-minute file takes about two seconds. Export a four-page loudness and master report as PDF or
CSV for files or live sessions (⌘E).

**Auraliscope Bridge (VST3 / AU).** Insert it on a track or bus, from stereo up to 9.1.6 buses. It analyses inside
the DAW and passes the audio through unchanged. Pause and Reset reach the plugin too.

**Sources.** Any Core Audio input, or, on macOS 14.2+, any output through a process tap, without changing or
delaying the sound. Up to 64 channels can be routed to speaker roles. Routing follows Audio MIDI Setup, with a
Channel Order menu for SMPTE, Film (Pro Tools) and VST3 (Nuendo/Cubase) orders.

**Your layout.** Enlarge any panel (⌘1–⌘7), open it in its own window or hide it. Save layouts, or use **Dock mode**
(⌥⌘S) for a row of meters along the bottom of the screen. Settings presets are saved as files you can copy to
another Mac.

**Look and language.** Light and Dark, a dozen colour themes plus the hardware-style Studio Console, and ProMotion
120 fps. The interface is in English, 简体中文, 繁體中文, 한국어, 日本語 and Español.

**Updates.** Check for Updates looks at this repository's releases. Turn on **Include pre-releases** in Settings ▸
General to also get betas and release candidates.

## Requirements

| | |
| --- | --- |
| App | Apple silicon Mac, macOS 13 or later |
| Output capture | macOS 14.2 or later, System Audio Recording permission |
| Plugins | VST3 and AU, macOS 11 or later, Apple silicon and Intel |
| Display | 1280 × 720 or larger |

## Install

1. Download `.pkg` file from [Releases](https://github.com/jinboz12/Auraliscope/releases).
2. Quit Auraliscope and your DAW. Open the package and choose the app, VST3 and/or Audio Unit.
3. Open Auraliscope from Applications, allow audio access when asked, and pick a source.

The installer replaces any 2.0 build and keeps your settings. If macOS blocks the first launch, open
**System Settings ▸ Privacy & Security** and choose **Open Anyway**. See [installation](docs/INSTALLATION.md).

## Privacy

Audio is analysed in memory on your Mac, in real time. Auraliscope never records audio to a file or uploads it. It
asks only for the permission the chosen source needs: Microphone for an input, System Audio Recording for an output.
Update checks are anonymous requests to GitHub's public API, made only when you ask.

## Build from source

macOS 13+, Xcode with Swift 6. See [source distribution](docs/SOURCE_DISTRIBUTION.md) for details.

```sh
Bridge/scripts/fetch-sdks.sh      # pinned VST3/AU SDKs
scripts/test.sh                   # core, kernel and localization checks
Bridge/scripts/build-app.sh
Bridge/scripts/build-plugins.sh
Bridge/scripts/package-installer.sh
```

| Folder | Contents |
| --- | --- |
| `Sources/Auraliscope` | The app (SwiftUI, Metal) |
| `Sources/AnalysisCore`, `Sources/AnalysisKernels` | Shared DSP used by the app and the plugins |
| `Sources/BridgeTransport`, `Bridge/` | Plugin, transport protocol and their tools ([architecture](Bridge/ARCHITECTURE.md), [protocol](Bridge/PROTOCOL.md)) |
| `docs/` | Release notes, update log, installation, loudness references, licences |

## Feedback

Please report problems on [GitHub Issues](https://github.com/jinboz12/Auraliscope/issues). Include the version and
build, your macOS version and Mac, the audio device, the channel layout and the steps to reproduce. Help ▸ Show
Diagnostic Logs opens the app's event logs, which contain no audio. Questions and ideas are also welcome on the
Discord linked in Settings ▸ General ▸ Feedback.

## License

This project is a vibe coding project with multiple ai agents.
Copyright © 2026 JINBOZ. Licensed under **GPL-3.0-only**. See [LICENSE](LICENSE), [COPYRIGHT.md](COPYRIGHT.md),
[third-party notices](docs/THIRD_PARTY_NOTICES.md) and [image rights](docs/ASSET_RIGHTS.md).
The software is provided "as is", without warranty of any kind. Loudness standard and service names belong to
their owners.
