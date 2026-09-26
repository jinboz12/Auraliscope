# Auraliscope 1.1 rc 2 build 50 — test report

This is an ad hoc signed, unnotarized test build for Apple Silicon. The app metadata records macOS 13.0 as the minimum and SDK 27.0. Output capture requires macOS 14.2 or later.

## Changes since build 49

- Settings edits preview immediately. Apply verification finishes before another edit; closing the window cancels a pending verification. Source and format changes clear routing drafts for the former configuration.
- Long Settings rows adapt to narrow windows. Language and loudness help text was corrected in English, Chinese and Korean.
- True Peak and clip warning reset controls use native button actions. A paused reset clears red warnings; stale frames cannot relight them, while a new over can.
- The keyboard's note detector now catches bass notes near the FFT boundary without reducing its 8192-point transform.

## Checks performed

- 31 core checks and 301 localization keys in each of three languages passed.
- 13 Settings regression checks and the paused peak-reset check passed in the release executable using an isolated QA bundle.
- All 13 supported Immersive layouts rendered successfully in the release executable's offscreen Metal path.
- Release-build window screenshots were reviewed for light 9.1.6, dark Stereo with mirrored spectrum, Korean Panels, Chinese Channels and the pending Apply bar.
- The loose app and the app inside the DMG passed strict code-signature verification. ZIP, DMG and SHA-256 integrity checks passed.
- One synthetic benchmark run per version was effectively unchanged: Stereo 1.1629 s (build 49) vs 1.1549 s (50), and 16-channel 2.1661 s vs 2.1618 s, per 100 simulated audio seconds. This excludes capture, rendering and driver load.

Real programme capture, physical multichannel routing, another Mac's first-launch experience and macOS releases before 26 still need tester validation. The keyboard indicates prominent pitches; it is not a complete chord transcription.

## Testers

Install from `Auraliscope.dmg` and follow its Read Me First. Check the chosen input/output and routing against your DAW. Try Stereo and your Immersive layout, preview then Apply/Revert a visual setting, resize panels, and clear a clip warning while paused. Report the app build, macOS version, source, routing and reproduction steps. Help > Show Diagnostic Logs opens the event-only logs.
