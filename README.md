# Auraliscope

**Auraliscope is a real-time audio analysis and visualization tool designed for macOS.**

Auraliscope integrates loudness, level, spectrum, spectrogram, waveform, sound field, and stereo correlation into a single window, allowing you to observe sound dynamics, frequency distribution, and spatial relationships while you listen.

It is suitable for music production, mixing, and audio post-production, as well as for monitoring audio during everyday playback.

[Download App](https://github.com/jinboz12/Auraliscope/releases)
[View Changelog](https://github.com/jinboz12/Auraliscope/releases/tag/v1.1rc2)
[Report Issues](https://github.com/jinboz12/Auraliscope/issues)

## Key Features

### Loudness and Dynamics

View readings such as LUFS, Loudness Range (LRA), True Peak, and VU in one place to monitor overall loudness and dynamic changes. The main loudness reading supports Momentary, Short-term, or Integrated modes.

When True Peak exceeds 0 dBTP, the interface displays the clipping status and specific value, making it easy to identify peaks that require attention.

### Channel Levels

Independently displays Peak and RMS levels for each channel, featuring peak hold and True Peak clipping alerts to facilitate level comparison between channels. Click the red clipping indicator to clear the held warning.

### Spectrum, Spectrogram, and Waveform

- **Spectrogram and Spectrum**: Share a logarithmic frequency axis and a piano keyboard display, showing real-time energy alongside historical data; the keyboard highlights the estimated fundamental pitch. The panel layout can be mirrored in the settings to move the spectrum to the left side.
- **Channel Waveform**: Observe amplitude and transients with selectable time ranges of 2, 4, or 8 seconds.

### Sound Field and Correlation

Supports stereo and immersive audio display modes, visualizing the spatial distribution of channel energy dynamically. The stereo sound field display offers point, outline, or filled modes, with views available for full-band, 3-band, or 5-band analysis. The immersive sound field utilizes a lightweight 2D room view and supports channel layouts ranging from 3.0 to 9.1.6.

In stereo mode, a band-specific correlation display helps visualize the relationship between left and right channels and identify potential phase cancellation issues when downmixing to mono.

Mono mode is hidden by default but can be enabled in the settings.

> "Immersive sound" refers to the app's multi-channel visualization mode; it does not imply Dolby Atmos encoding, decoding, or certification capabilities.

### Input and Output Audio Analysis

Supports Core Audio input devices; on macOS 14.2 or later, output audio can be captured for analysis via the Core Audio Process Tap.

The app automatically selects the current macOS default output device upon launch, though the audio source can also be switched manually.

Supports channel layouts up to 9.1.6 and allows custom mapping of up to 64 physical channels to specific speaker roles.

### Appearance and Language

- Supports system-matching, light, and dark appearances.
- Supports both standard windowed and full-screen modes.
- Uses native Liquid Glass controls where supported by the system.
- Supports Simplified Chinese, English, and Korean.
- Settings changes provide an instant preview; click "Apply" to save or "Revert" to discard. Language switching does not require a restart, and the menu bar updates immediately.

## System Requirements

| Item | Requirement |
| --- | --- |
| Processor | Apple Silicon Mac |
| OS | macOS 13 or later |
| Output Audio Capture | macOS 14.2 or later |
| Tested System | macOS 27.0 (26A428), M1 Max MacBook Pro |

The target system deployment does not imply that compatibility has been verified for every version. Actual performance on other macOS versions remains to be tested. ## Download and Installation

1. Visit the [Releases page](https://github.com/jinboz12/Auraliscope/releases) to download the DMG file.
2. Open the DMG and drag Auraliscope into the Applications folder.
3. Launch the app from the Applications folder.
4. Grant audio capture permissions as needed and select the audio source to analyze.

The current version, **1.1 rc 2 (build 50)**, is a release candidate; it uses ad-hoc signing and has not yet been notarized by Apple. The downloaded file is `Auraliscope.dmg`, containing the application `Auraliscope.app`.

If macOS prevents the app from launching, please verify that the installation package comes from this project's official Releases, then go to:

**System Settings → Privacy & Security**

Check if the system offers an "Open Anyway" option.

## Permissions and Privacy

Auraliscope uses the following permissions based on the selected audio source:

| Audio Source | Required Permission |
| --- | --- |
| Input Device | Microphone permission |
| Output Audio | System audio recording permission |

The specific names and display of system permissions may vary depending on the macOS version.

**Audio is analyzed in real-time solely within the device's memory; the app does not save captured audio to a file or upload it.**

## Usage Tips

- Before starting analysis, ensure that the selected device and channel layout match the actual audio routing.
- When analyzing multi-channel audio, check the mapping between physical channels and speaker roles.
- Correlation readings help assess stereo compatibility; it is recommended to interpret them alongside actual mono listening tests.
- Sound field visualization reflects the channel energy relationships of the input signal; it is not equivalent to a measurement of room acoustics or the actual speaker sound field.

## Feedback

Feel free to submit issues or suggestions via [GitHub Issues](https://github.com/jinboz12/Auraliscope/issues). To facilitate reproduction, please provide the following information whenever possible:

- Auraliscope version and build numbers;
- macOS version and Mac model;
- Audio devices used and input/output modes;
- Channel layout and relevant routing settings;
- Steps to reproduce the issue, expected behavior, and actual behavior;
- Relevant screenshots or screen recordings.

Before submitting materials, please check for any information that should not be made public.

## License and Scope of Use

Copyright © 2026 JINBOZ.

Anyone may download, install, and run the Auraliscope application free of charge for professional or personal use.
Subject to the terms of the CC BY-NC-ND 4.0 license, you may share unmodified copies of this project for non-commercial purposes.

### Disclaimer

This software is provided "as is," without any express or implied warranties. To the extent permitted by applicable law, the author assumes no liability for any damages arising from the use of this software.
Third-party components and materials included in Auraliscope are subject to their respective licenses.

The spectrogram visualization in Auraliscope draws inspiration from the
[AudioSpectrogram](https://github.com/lmshao/AudioSpectrogram)
project regarding the design of the dB legend and the time/frequency markers.

Auraliscope's real-time analysis and rendering are implemented independently using Swift, Accelerate, and Metal;
it does not link to that project's Rust libraries.
