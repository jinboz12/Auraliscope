# Auraliscope 1.1

The 1.1 release (build 51). It follows the release candidates 1.1rc (build 49) and 1.1 rc 2 (build 50); everything in them below is part of this release.

## Changes since 1.1 rc 2

- **Spectrogram · Spectrum:** the top of the frequency axis is always labelled (20k at 44.1 kHz and above), so the full 20 Hz – 20 kHz range reads at a glance. The peak badge moved to the spectrogram's top corner, clear of the spectrum's labels, in both orientations.
- **Keyboard:** fewer, clearer notes. It lights at most 4 notes, only peaks within 18 dB of the loudest that stand at least 12 dB above their surroundings.
- **Waveform:** lane names are right-aligned against the lanes, so names of every width end at the same edge.

## Requirements

Apple Silicon, macOS 13 or later. Output capture requires macOS 14.2 or later and System Audio Recording permission; input capture requires Microphone permission.

## Validation

31 core checks and 301 localization keys in each of three languages pass. The packaged app's code signature, archive and disk image are checked. The changes were checked by snapshots with the demo signal in Stereo and 7.1.4, in both spectrum orientations.

## Distribution notice

`Auraliscope.dmg` (with "Read Me First") and `Auraliscope.zip`, both containing `Auraliscope.app`. Ad hoc signed and not notarized: approve the first launch in System Settings ▸ Privacy & Security (Open Anyway).

# Auraliscope 1.1 rc 2

The second 1.1 release candidate (build 50), a polish pass on 1.1rc (build 49). Everything in 1.1rc below is part of it.

## Changes since 1.1rc

- Channel Levels in dense layouts (9.1.6 in a small window): every reading and channel name stays inside its own column, at one size, instead of running into its neighbours.
- About fits its content: no empty space below the page, and it grows when the third-party notices open. Its Soundstage and Channel Levels lines describe the full band, 3 or 5 bands.
- Settings: the Color theme menu no longer shows the macOS blue arrow; the Monitoring mode switch sits at the end of its row like every other control; the colour theme note reads more clearly.
- A preview cut short by a crash or a force quit is undone at the next launch.

## Validation

31 core checks and 301 localization keys in each of three languages pass. The packaged app's code signature, archive and disk image are checked. The changes were checked by snapshots with the demo signal at the smallest window size in 9.1.6, and in Settings and About in English and Chinese, light and dark.

## Distribution notice

As for 1.1rc: ad hoc signed and not notarized. Open the disk image, drag the app to Applications, and approve the first launch in System Settings ▸ Privacy & Security (Open Anyway); "Read Me First" in the disk image has the steps.

# Auraliscope 1.1 rc 2

The second 1.1 release candidate, **build 50**, for private testing. This pass keeps the existing panel design and theme palettes while refining controls, settings and note detection.

## Changes since build 49

- **Settings reliability:** Apply now completes verification before accepting another edit. Closing Settings cancels its pending verification, so an old result cannot overwrite a new preview. Choosing an unchanged value no longer starts an empty preview.
- **Channel settings:** changing the source or immersive format discards routing edits for the previous configuration. Hiding Mono also clears a pending Mono selection, avoiding an Apply failure for a mode that is no longer offered.
- **Readable settings:** long labels and controls stack when a row is too narrow. Language help now describes the automatic preview correctly; loudness help distinguishes the 400 ms Momentary and 3 s Short-term readings from gated Integrated loudness.
- **Peak reset:** the red True Peak reading and channel clip lights use native button actions, including keyboard and accessibility activation. Clearing a warning wakes the paused display, and stale snapshots cannot immediately light it again; a new over still does.
- **Keyboard note display:** bass notes no longer disappear because of the FFT's lower boundary, especially at 96 kHz. The 8192-point analysis and the existing spectrum design are preserved. The keyboard is an estimate of prominent pitches, not a complete chord transcription.

## Validation

31 core checks, 301 localization keys in three languages, 13 settings regression assertions and the paused peak-reset check pass. The release executable renders all 13 Immersive layouts. Light/dark, mirrored-spectrum and localized Settings screenshots were reviewed using an isolated QA bundle. App signatures, ZIP/DMG integrity and checksums pass. A single synthetic DSP comparison is effectively unchanged from build 49. Real programme capture, physical routing and older macOS runtime behavior remain for tester validation; details are in `TEST_REPORT.md` beside the build.

## Test packages

`Auraliscope.app`, `Auraliscope.zip`, `Auraliscope.dmg` and SHA-256 checksums are in `dist/1.1 ver/1.1 rc 2 build 50/`. The DMG includes first-launch instructions. The build remains ad hoc signed and unnotarized, for Apple Silicon and macOS 13 or later; output capture requires macOS 14.2 or later.

# Auraliscope 1.1rc

The 1.1 release candidate (build 49), shared as a private, unnotarized test build. It follows 1.0.2 (build 21) and gathers the 1.1 development builds 22 to 48.

## Highlights

- **Immersive** replaces Atmos as the name of the multichannel mode, for every format from 3.0 to 9.1.6.
- **Spectrogram · Spectrum** is one panel: the live spectrum beside its history on one pitch axis, with a piano keyboard. The keyboard now lights every note sounding together (up to six, overtones folded into their note), the loudest with a hairline across the plot. Settings ▸ Panels can mirror the panel (spectrum on the left, keyboard on the right) and turn the spectrum's peak holds off.
- **Soundstage in Stereo** is a stereometer: every sample plotted between L, M and R by level, in the colours of its frequency band (full band, 3 or 5 bands), with an arc per band on the rim. It can draw the bands as dots, outlines, or tinted shapes with outlines (Settings ▸ Panels).
- **Soundstage in Immersive** is a flat, lightweight room: speaker markers with a level ring, peak dot and clip halo, a field lifted by how much the height layer carries, and a marker per frequency band. The BANDS menu can turn the band markers off in Immersive.
- **Channel Levels**: correlation in 3 or 5 frequency bands in Stereo. A red clip light can be clicked to clear the over warnings (with the held True Peak).
- **Loudness summary**: the main reading can be Momentary, Short-term or Integrated (Settings ▸ Panels); the other two move to the tiles.
- **Waveform**: a smoother outline that no longer shows more detail on dense screens than the eye needs, and a 2, 4 or 8 s span (Settings ▸ Panels).
- **Settings** is organised as General, Audio, Channels, Panels and Appearance. Changes show in the app at once as a preview; Apply keeps them, Revert (or closing Settings, or quitting) puts back what you had. The source and routing, which restart the audio, wait for Apply. Apply checks that every change took effect and names any that did not.
- **Language** changes apply without a restart, the menu bar included.
- The colour theme's accent now colours every control, the Settings sidebar and the switchers included, and the switchers and menus use the system's Liquid Glass on macOS 26.
- Reset measurements moved to the foot of the Settings sidebar.

## Requirements

Apple Silicon, macOS 13 or later. Output capture requires macOS 14.2 or later and System Audio Recording permission; input capture requires Microphone permission.

## Validation

30 core checks (including a chord-detection check: A3, C♯4 and E4 with overtones read as those three notes) and 301 localization keys in each of three languages pass. The packaged app's code signature and archive integrity are checked. Settings preview, revert and recovery after a forced quit were checked by scripted runs; the panels were checked by snapshots with the demo signal in English, Chinese and Korean, light and dark. Live capture with real programme material, real multichannel hardware and macOS releases before 26 were not tested for this candidate.

## Distribution notice

This build is ad hoc signed and has not been notarized by Apple. Open the disk image, drag the app to Applications, then open it once: macOS will refuse the first launch; approve it in System Settings ▸ Privacy & Security (Open Anyway). The disk image includes these steps in "Read Me First". It does not include a project-level source license.

# Auraliscope 1.0.2

A fix release (build 21) on top of 1.0.1.

## Fixes

- Channel Levels: a bar's colour follows the channel's current level only: the accent, and ochre while the channel peaks within 3 dB of full scale. An over no longer turns the whole bar red until the next reset; it shows only at the top, in the over zone above 0 dB, on the clip light and in the readout.

## Requirements

Apple Silicon, macOS 13 or later. Output capture requires macOS 14.2 or later and System Audio Recording permission; input capture requires Microphone permission.

## Validation

28 core checks and 241 localization keys in each of three languages pass. The packaged app's code signature and archive integrity are checked. The over display was checked with a demo signal pushed to +1.4 dBTP on one channel.

## Distribution notice

This archive is ad hoc signed and has not been notarized by Apple. On another Mac, macOS blocks the first launch; approve it in System Settings ▸ Privacy & Security (or Control-click the app and choose Open). It does not include a project-level source license.

# Auraliscope 1.0.1

The 1.0.1 release (build 20). It follows the 1.0.1rc release candidate (build 19); everything in 1.0.1rc below is part of this release.

## Changes since 1.0.1rc

- Full screen: the toolbar bar takes the backdrop's colour, so the header reads the same as in a window, without the system's grey band or the window title.
- Changing the colour theme or the appearance no longer moves the window back to an earlier position; the saved position is kept current on every move and resize.
- A small diagnostic log: one plain-text file per launch in the app's Logs folder, events only (launch, devices, capture status and errors, format and mode changes, dropped audio, full screen, theme, language, quit), never audio; each file stops at 256 KB and the five newest are kept. Help ▸ Show Diagnostic Logs and the About window open the folder.
- About is simpler: plain text without icons or cards, the current panels described (Soundstage and Channel Levels), the version and build on one line, and buttons to copy the version information and show the diagnostic logs.
- The release is packaged as `Auraliscope.app` and `Auraliscope-1.0.1-macOS.zip`; the folder name keeps the build number.

## Requirements

Apple Silicon, macOS 13 or later. Output capture requires macOS 14.2 or later and System Audio Recording permission; input capture requires Microphone permission.

## Validation

28 core checks and 241 localization keys in each of three languages pass. The packaged app's code signature and archive integrity are checked. The theme-switch window position, the full-screen header and the diagnostic log (rotation to five files) were checked on the development Mac with the demo signal. Live output capture, real multichannel routing and macOS releases before 26 were not tested for this release.

## Distribution notice

This archive is ad hoc signed and has not been notarized by Apple. On another Mac, macOS blocks the first launch; approve it in System Settings ▸ Privacy & Security (or Control-click the app and choose Open). It does not include a project-level source license.

# Auraliscope 1.0.1rc

The second release candidate (build 19), shared as a private, unnotarized test build. It follows 1.0.0rc (build 8).

## Highlights

- The toolbar is the window's only header, in a window and in full screen alike: the brand and the stream (sample rate, channels, layout) at the leading edge, the Stereo | Atmos selector in the centre, and the actions at the trailing edge. The former heading row is gone, and the panels take its height.
- The right-hand column is two panels: SOUNDSTAGE, the channel map, and CHANNEL LEVELS, vertical meters drawn like the loudness gauge with the peak, the peak hold, a true-peak over zone up to +3 dBTP and a clip light per channel.
- Correlation, redesigned around what the listener hears: coloured zones (Out of phase, Wide, Stereo, Mono), a one-line explanation of the reading, and IN MONO, the level change when L and R are summed to mono. It shows in Stereo and folds away in Atmos.
- True-peak overs are shown with their size: the TRUE PEAK tile reads a signed amount with an OVER badge, and each channel's over zone fills to its highest over until reset.
- Soundstage in Atmos: a larger room with azimuth ticks, spokes and glows that follow each speaker's level, smooth bed and height fields, and the mix's image direction. Switching modes still morphs between the room and the stereo stage.
- A sharper, higher-contrast spectrogram (−90…−12 dB).
- The loudness summary is recomposed on a grid with a LOUDNESS title; the TIME tile is gone.
- Multi Channel is now called Atmos. Mono is hidden by default; Settings ▸ Channels ▸ Show Mono mode brings it back.
- The whole window, theme names included, is translated into Simplified Chinese and Korean. After a language change, Settings offers Restart Now.
- At launch Auraliscope meters the current macOS default output, what the Mac is playing (the default input before macOS 14.2).

## Performance

- The window is opaque, so the window server no longer blends it with the desktop on every frame, and the spectrum's peak badge is a solid chip instead of glass over the live plot. With the demo signal on the development Mac, GPU load fell from about 50 % to about 21 %.
- One display link drives every canvas, at 60 Hz also on 120 Hz displays, with one command buffer per refresh; it stops when every canvas is at rest or the window is hidden. The spectrogram reads its history with hardware-filtered sampling.
- In the loudness summary only the views that print a reading re-render at 10 Hz.

## Requirements

Apple Silicon, macOS 13 or later. Output capture requires macOS 14.2 or later and System Audio Recording permission; input capture requires Microphone permission.

## Validation

28 core checks and 238 localization keys in each of three languages pass. The packaged app's code signature and archive integrity are checked. Layouts were reviewed in window and full-screen snapshots with the demo signal. Live output capture, real multichannel routing and macOS releases before 26 remain release-machine validation items.

## Test-build notice

This archive is ad hoc signed and has not been notarized by Apple. macOS may block it when downloaded on another Mac. It is intended only for invited testers. It does not include a project-level source license.

## Development builds toward 1.0.1rc

### Build 18

- Window heading: the stream information sits on the wordmark's baseline after a hairline divider, with values set firmly and units and separators quieter ("48 kHz · 8 ch · 5.1.2"); the LIVE dot aligns with its label.

### Build 17

- Soundstage in Atmos: the room is sized from where its labels actually sit, so it fills the panel's height (smaller only as far as rear speakers need); azimuth ticks every 30° on the ring; a spoke from the listener to every speaker that brightens with level; a glow per speaker in its group colour that grows with level; the bed and upper layers as smooth, softly shaded fields; the mix's image direction as a line from the listener to the energy centroid; a full ring per speaker that brightens with the peak (ember after a clip) instead of the partial arcs; height labels between the two rings.
- The mode animations are unchanged: the fields straighten into the stereo triangle as Stereo takes over, and receding speakers' spokes and glows fade with them.

### Build 16

- Channel Levels redrawn in the style of the loudness gauge on the summary: slim capsule tracks with a hairline edge, one solid fill per channel in a status colour (the accent; ochre once the channel peaks within 3 dB of full scale; ember for an over), the peak as the same colour translucent behind it, and the peak hold as a thin ink mark across the bar like the gauge's target mark. No gradients, notches or glows; a single hairline at 0 dB. The legend and the readouts follow the same colours.
- At launch Auraliscope meters the current macOS default output, what the Mac is playing (the default input before macOS 14.2). An explicit "No device" choice is kept.

### Build 15

- Spectrogram sharper and higher in contrast: each pixel shows the loudest of the frequency rows it covers, so narrow partials no longer fall between rows; a capped unsharp mask, mostly across frequency, lifts partials above the analysis window's skirt; the display range is −90…−12 dB with a steeper S-curve, so the noise floor stays black.
- Channel Levels refined: a slim peak bar behind a wide RMS body, so peak and RMS read apart by shape; faint guides at the scale steps across all channels; the clip light is a ring until an over lights it solid; a legend in the panel header (RMS, Peak, Hold).

### Build 14

- At launch Auraliscope switches to the current macOS default device: the default output if an output was metered last time, otherwise the default input. An explicit "No device" choice is kept. Settings ▸ Audio explains this.
- Channel Levels indicators refined to match the rest of the window: capsule tracks like the loudness gauge, a solid RMS body in the level colours with a translucent peak tail, a pill-shaped peak hold, notches at the scale steps, a separate over capsule above 0 dB, a round clip light like the LIVE dot, and an over readout as an ember pill.

### Build 13

- The multichannel mode is now called Atmos everywhere: the mode selector, the Meter menu, Settings and tooltips. In Chinese and Korean it stays "Atmos", as a product name.
- Channel Levels indicators redesigned as LED columns: wider bars of segments lit to the RMS in the level colours, dimmer from there to the peak, one bright segment at the peak hold, and ember segments above 0 dB up to the highest true-peak over.
- A clip light over each bar lights up after a true-peak over or a full-scale sample and stays lit until reset.

### Build 12

- The right-hand column is two panels: SOUNDSTAGE (the channel map) above CHANNEL LEVELS (vertical Peak and RMS meters with true-peak overs, and the correlation section). Drag the divider between them to share the height; double-click it to reset.
- Correlation shows in Stereo only. It folds away in Multi Channel (and Mono), and the channel meters take the height.
- Mono is hidden by default. Settings ▸ Channels ▸ Show Mono mode brings it back to the mode selector, the Meter menu and Auto. While hidden, Auto follows the programme between Stereo and Multi Channel, and a previously pinned Mono opens as Stereo.

### Build 11

- Soundstage channel meters stand vertically: one column per channel under FRONT / LFE / SURROUND / HEIGHT, the held peak above each column, the channel name below, and the dB scale on the left. Columns narrow and dissolve with the Mono / Stereo / Multi-Ch transitions as the rows did.
- True-peak overs: the meters read up to +3 dBTP. A channel that goes above 0 dBTP fills its over zone to the highest over, lights up, and its readout switches to the amount in ember (e.g. +1.4) until reset. The TRUE PEAK tile on the loudness summary shows a signed amount, an OVER badge and an ember tint.
- Correlation redesigned around what the listener hears: the track is split into coloured zones (Out of phase, Wide, Stereo, Mono) with the current zone lit, a one-line explanation of what the reading means on playback, and IN MONO, the level change when L and R are summed to mono (0 dB for mono, about −3 dB for unrelated sides, a large drop when the sides cancel).
- `scripts/test.sh` falls back to an installed SDK the compiler can read, so the core checks run again with these Command Line Tools.

### Build 10

- Loudness summary recomposed as one grid: the title, status and TARGET/CEILING menus share the top row; the gauge sits over the tiles; each tile's reading is flush left under its title, with the unit after it; the short-term reading is centred beside the tiles.
- The whole meter window is now translated into Simplified Chinese and Korean: panel titles, measurement names, status, legends, correlation and speaker group names, the mode selector and AUTO. Units, channel labels, layouts, standards and FFT stay as printed.
- Color theme names are translated.
- The restart notice after a language change has a Restart Now button, which relaunches Auraliscope.
- Build folders and apps are now named "<version> build <build>", e.g. `dist/1.0.1 build 10/Auraliscope 1.0.1 build 10.app`.

### Build 9 (1.0.1dev)

- The loudness summary at the top of the window now carries a LOUDNESS panel title, like the cards below it.
- Removed the TIME tile from the loudness summary; the peak readings (TRUE PEAK, PEAK) share the second row.
- Changing the language in Settings now shows a notice: "To apply the change, please restart the program."

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
