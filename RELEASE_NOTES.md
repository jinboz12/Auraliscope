# Auraliscope 1.2.2

The 1.2.2 release (build 62), following 1.1 (build 51). It collects the 1.2 line: the release candidates 1.2 rc 1 (build 55), 1.2.1rc (build 57), 1.2.1rc2 (build 58) and 1.2.2rc (build 61), none of which was released on its own. Their sections below give the details; everything in them is part of this release. The source is unchanged from 1.2.2rc apart from the version.

## Changes since 1.1

- **Pause and resume.** Pause (Space, with the meter window in front) freezes every panel and reading as it was. Resume carries on the same measurement (Integrated loudness, loudness range, held peaks and histories) and leaves the paused time out. A change of source, routing or sample rate while paused, or Reset, starts a fresh measurement.
- **True peak.** Rewritten as locate-then-measure: a 4× stage (2× from 96 kHz) finds the crests, and a 64-tap interpolator with a parabolic fit measures them. 1.1's 12-tap 4× meter read an 18 kHz inter-sample peak 0.38 dB low (48 kHz) and more closer to 20 kHz, did not oversample 192 kHz streams, and dropped the tail of a burst that ended in digital silence. Tones from 15 to 20 kHz now read within 0.0002 dB of their crest at 44.1 to 192 kHz, and random 20-tone mixtures within 0.00034 dB, identically for every buffer split.
- **Loudness.** K-weighting runs in double precision; in single precision the low-frequency weighting drifted at high sample rates (20 Hz: −0.16 dB at 192 kHz, +0.24 dB at 384 kHz), and every rate from 44.1 to 384 kHz now matches the 48 kHz response within 0.01 dB for tones from 20 Hz to 10 kHz. The filter rests only after its state decays. Loudness range follows EBU Tech 3342 exactly (1.1 used 0.1 LU bins and a nearest-rank percentile), and the integrated gate is applied in the energy domain.
- **Band readings.** Band level, balance and width stay visible when only one side carries sound; bands entirely above Nyquist stay silent at low sample rates.
- **Robust input.** NaN and infinite samples from a driver become silence at the capture ring; finite overs above full scale stay measurable.
- **Output capture.** Metering an output no longer goes through the microphone path, so macOS asks only for System Audio Recording. An output that delivers only digital silence for 5 s shows **No sound from this output**, with how to allow System Audio Recording.
- **Small screens.** The meter window goes down to 1000 × 628 pt of content (about 680 pt with the toolbar) and fits a 1280 × 720 display; the summary, Channel Levels and the soundstage make room in turn.
- **Performance.** Five paired runs of the DSP benchmark (100 simulated seconds of 16-role 48 kHz audio), median CPU seconds: Stereo 1.150 → 0.610 (−47%), Spatial 2.166 → 1.224 (−43%) against 1.1. In Spatial, digitally silent roles skip the FFT. With a 6-channel 48 kHz input and a full-size window at 60 Hz, the whole app used about 21% of one core in both 1.1 and 1.2.2 on the test Mac; at that channel count drawing, not analysis, sets the cost.
- **Fixes and polish.** Space acts only while the meter window is in front; the welcome returns on the first launch of each new build; Settings and About no longer reopen at launch; the status says Standby before metering starts; 9.1.6 waveform lanes keep their names in the smallest window; the Stereo waveform legend sits flush right.
- **Rights.** About, the README and the third-party notices state that the service names in the loudness target menu are their owners' trademarks. The app uses documented Apple APIs only; `docs/IP_REVIEW.md` records the provenance and licence review (not a patent search).

## Requirements

Apple silicon, macOS 13 or later. Output capture requires macOS 14.2 or later and System Audio Recording permission; input capture requires Microphone permission.

## Validation

42 core checks and 308 localization keys in each of three languages pass, also under Address Sanitizer and Thread Sanitizer. On the packaged candidate: capture self-test and pause/resume on a virtual input, pause/resume on an output process tap, source switching while paused, device removal and return (synthetic and a real aggregate device), sample-rate changes at 44.1, 96 and 192 kHz, settings regression and persistence, live language switching, full screen, the smallest window, a 15-minute sustained run with flat memory, and a leak check. Details are in `docs/1.2.2_TEST_REPORT.md` and in `TEST_REPORT.md` beside the build.

## Known limitations

- **Output capture content not verified here.** Tap creation, delivery, routing and pause/resume on an output were verified, but the test context had no System Audio Recording permission (TCC reported it undetermined), so macOS delivered silence. Hearing real programme through an output needs a manual check with the permission granted.
- **Not tested:** the System Audio Recording prompt and indicator on a clean Mac, macOS versions other than 27.2 (the minimum supported is 13), first launch on another Mac, sleep and wake while capturing, and physical multichannel interfaces.
- Loudness at rates other than 48 kHz and long-programme Integrated loudness have not been cross-checked against an external compliance meter.
- Integrated loudness and loudness range keep every 100 ms value for exactness, so their memory grows by under 1 MB per hour of continuous metering until Reset or a new source.
- A sample-rate change restarts capture twice in quick succession; metering continues at the new rate.

## Distribution notice

`Auraliscope.dmg` (with "Read Me First") and `Auraliscope.zip`, both containing `Auraliscope.app` (bundle ID `com.jinboz.SoundMeterJBZ`, so it replaces 1.1 and keeps its settings). Ad hoc signed and not notarized: approve the first launch in System Settings ▸ Privacy & Security (Open Anyway). macOS treats each build as a new app, so it asks for audio permissions again.

# Auraliscope 1.2.2rc

Release candidate, build 61, on 1.2.1rc2 (build 58): more precise measurement and about 40% less DSP CPU. It carries the work of the 1.2.2dev builds 59 and 60, plus two true-peak fixes from the release-candidate review.

## True peak

- **Rewritten as locate-then-measure.** A 4× stage (2× from 96 kHz) with 16 taps per phase now only finds the crests. It takes the local maxima of its magnitudes: the loudest in each 64-sample segment, plus the runner-up when it is within 1 dB, because a short filter can rank two near-equal crests the wrong way round. Around each one, a 64-tap Kaiser interpolator, flat within 0.004 dB to 20 kHz even at 44.1 kHz, evaluates the signal every 1/16 sample (1/8 at 2×) until it brackets the loudest value. A parabola through that value and its neighbours then places the crest between grid points.
- **Accuracy.**
  - Tones from 15 to 20 kHz at any phase read within 0.0002 dB of their crest at 44.1, 48, 88.2, 96 and 192 kHz, 20 kHz at 44.1 kHz included.
  - In 1,500 random 20-tone mixtures (20 Hz to 20 kHz) at 44.1, 48, 88.2, 96 and 192 kHz, the reading stayed within 0.00034 dB of the analytic crest, under or over, and every buffer split read the same.
  - For comparison: build 58's 12-tap 4× meter read an 18 kHz tone at 48 kHz 0.38 dB low. Build 59 read up to 0.054 dB low at 48 kHz, and its filter drooped 1.7 dB at 20 kHz at 44.1 kHz.
- 192 kHz streams, which had no oversampling in build 58, use 2× plus the same measurement.
- The reading never goes below the sample peak. It is independent of how the audio is split into buffers: segments are counted in absolute samples, a point is judged once both of its neighbours are known, and ties go to the earliest point.
- **Fixed in review (since build 60).**
  - The coarse grid that ranks crests now includes the samples themselves. Without them, the 2× grid used above 96 kHz had points a whole sample apart, and a 96 kHz mixture could read 0.007 dB low when the true crest ranked second.
  - The shortcut that skips points too quiet to matter now depends only on the segment's candidates. Its threshold had come from the current buffer, so a buffer split could, in principle, change which crests were measured.

## Loudness

- **K-weighting in double precision.** In single precision, the high-pass poles sit so close to the unit circle at high sample rates that rounding moved the response. At 20 Hz the weighting was off by −0.16 dB at 192 kHz and +0.24 dB at 384 kHz; at 100 Hz, by up to 0.07 dB. The filter now runs in double precision, eight channels per pass, and sums energy in the same loop. Every rate from 44.1 to 384 kHz now matches the 48 kHz response within 0.01 dB for tones from 20 Hz to 10 kHz.
- **Exact EBU Tech 3342 loudness range.** Build 58 read LRA from a 0.1 LU histogram with a nearest-rank percentile, and counted the whole bin at the relative gate. Every short-term value is now kept, sorted within its bin. The gate is applied value by value, and the 10th and 95th percentiles are picked as Tech 3342 specifies: the value at index round((n − 1) · p) of the sorted gated values. Checked against sorting everything, to 0.0001 LU.

## Performance

- Five paired DSP benchmark runs, median CPU seconds per 100 simulated seconds of 16-role 48 kHz audio:

  | Spectrum mode | Build 58 | Build 61 |
  | --- | ---: | ---: |
  | Stereo | 1.055 | 0.615 (−42%) |
  | Spatial | 2.024 | 1.243 (−39%) |

  These figures cover the DSP components only; the audio driver, rendering and WindowServer are not included.
- **De-interleaving.** `vDSP_mmov` with one-float rows called `memmove` once per sample, about a third of the DSP queue. A strided copy replaces it, and each delivery is de-interleaved once and shared by loudness, waveform, spectrum and band splitter.
- **Stereometer band splitter.** The ten Linkwitz–Riley cascades (five bands × L/R) run together as three four-lane vector groups instead of ten scalar filters.
- **Spectrum.**
  - The FFT ring copy and the Hann window are fused into one multiply, with the ¼ of the conjugate split carried exactly by a half-amplitude window.
  - The split of each packed pair into two power spectra is one vector pass.
  - Peak searches use vector maxima.
- **Silence skipping.** In Spatial analysis, roles whose whole FFT window is digital silence are left out of the transforms, and the remaining roles are paired among themselves. A 7.1.4 stream carrying stereo costs one transform instead of six, and full silence (a paused player) costs none. The result is exactly what the skipped transforms would have produced.
- **Readings.** Only true peak and loudness range change by design. The K-weighting now differs from build 58 only by rounding at 44.1 and 48 kHz (a small effect at 96 kHz); from 176.4 kHz up it is corrected. The benchmark checksum (which includes true peak) is −6886.990, against −6890.791 in build 58.

## Tooling

- `AURALISCOPE_DMG=1 scripts/package-app.sh` also builds a disk image for a development build, named like its archive.

Ad hoc signed; not notarized.

# Auraliscope 1.2.1rc2

Release candidate 2, build 58. Includes the fixes and compact-window refinements from 1.2.1rc (build 57).

- Fixed frequency-band level, balance and width readings disappearing when only the left or right channel carries audio. The Soundstage band marker now remains visible for a one-sided signal; correlation remains unavailable when either side is below the analysis gate.
- Fixed phantom high-band readings at low sample rates. Bands entirely above Nyquist now remain silent in both the FFT analysis and the band splitter.
- Optimized FFT power extraction and band accumulation using vector operations, retaining the 8192-point FFT. Analytic tone regressions verify band power and cross power at 8, 44.1, 48, 96 and 192 kHz.
- Improved integrated-loudness gate calculation by applying the relative gate directly in the energy domain. Per-bin bounds skip unnecessary history scans without approximating the accepted energies. Worst-case boundary-bin scans and history storage can still grow over time.
- Non-finite input samples (NaN and infinity) are replaced with silence at the multichannel capture ring, preventing invalid samples from poisoning subsequent analysis. Finite values above full scale remain measurable.
- Five paired DSP benchmark runs against build 57 reduced median CPU time from 1.1399 to 1.0667 seconds in Stereo (6.4%) and from 2.1773 to 2.0600 seconds in Spatial (5.4%), per 100 simulated seconds. These component results exclude the audio driver, rendering and WindowServer.
- Expanded sanitizer checks to instrument both Swift and the C ring/callback support code. All 39 core checks and 308 localization keys passed. Virtual-input routing and pause/resume checks also passed.

Known test boundary: the virtual-output self-test blocked inside Core Audio IOProc registration and was stopped. Output capture is not marked as verified for this candidate. See the accompanying test report for details. Ad hoc signed; not notarized.

# Auraliscope 1.2.1rc

Release candidate, build 57, following development build 56.

- Fixed True Peak under-reading at the end of short bursts: digitally silent buffers now drain the interpolator tail instead of discarding it. Verified against a scalar convolution reference at 44.1–192 kHz and buffer sizes down to one sample.
- K-weighting now rests only once its filter state has decayed, rather than after two silent buffers. This preserves the decay through short buffers and prevents stale state returning with the next signal.
- Pausing preserves the final dropped-frame count, including drops since the last readout refresh.
- Soundstage fitting reuses per-layout geometry. Stereometer dots use direct vector projection, with equivalent positions, avoiding angle-to-vector round trips.
- Dense speaker layouts in very short Soundstage panels use smaller markers and fewer orientation labels. Channel Levels retains the complete channel names; enlarging the Soundstage restores all labels.
- Checked source, resources, tests, scripts and documentation for agent self-attributions: none found in the build 56 baseline. Existing author credits and required third-party copyright notices are retained.
- Five paired DSP benchmark runs remained effectively unchanged (Stereo 1.1372 → 1.1357 s; Spatial 2.1654 → 2.1640 s per 100 simulated seconds). The isolated layout benchmark improved from 0.3279 to 0.1834 s for 100,000 layouts, with an identical checksum. These are component measurements, not whole-app CPU percentages.

Includes the build 56 small-window refinements and the 1.2 pause/freeze/continuation fixes. FFT resolution remains 8192. No audio-device buffer or DAW signal-path changes.

See `TEST_REPORT.md` beside the DMG for verification and remaining runtime boundaries. Ad hoc signed; not notarized.

# Auraliscope 1.2.1dev

Development build 56 on 1.2 rc 1 (build 55): small screens, layout fixes and a lighter true-peak meter.

## Small screens

- **The meter window fits a 720p screen.** Its minimum height was 820 pt, taller than a 1280 × 720 display, so the status bar and the bottom of every panel sat off screen. The window now goes down to 1000 × 628 pt of content (about 666 pt with the toolbar), and on a short screen the panels make room in order:
  - The loudness summary starts at its minimum height; its loudness bar folds away and the tiles keep their size. Dragged taller (180 pt or more), the bar returns.
  - Channel Levels gives up height before the Soundstage room, down to its short minimum.
  - Whenever the full correlation section would leave the Stereo bars under 90 pt, the section becomes compact: the lit zone's name and the mono fold-down share one row under the bar, and the listener hint moves to the zone name's tooltip. This also applies to a short Channel Levels panel in a larger window (about 355 pt or less), where the bars used to shrink to about 46 pt; they now keep about twice that.
  - A short room folds its band legend away (the rims' colours still name the bands) and the stereometer's dB marks thin out, so they no longer overlap.
- **The summary's tiles no longer run past its edge.** At the regular height (182 pt) with the wide arrangement (a window 1240 pt or wider and under 940 pt tall, such as a 1440 × 900 screen), the second row of tiles touched the bottom of the card. The top and bottom padding now close in before the tiles do.
- **Dragging the summary taller no longer crushes Channel Levels.** Its limit left room for the analyzer column's minimum, not the taller Soundstage column's, so a tall summary squeezed Channel Levels well below its minimum. The limit now keeps both columns at their minimum.

## Performance

- The true-peak meter no longer runs the oversampling phase that reproduces the input samples, whose peak it already has: a quarter less filtering at 44.1, 48 and 88.2 kHz, half at 96 and 176.4 kHz, with the same readings.

# Auraliscope 1.2 rc 1

The first 1.2 release candidate (build 55): a refinement release on 1.1 (build 51), with fixes for what testers found in 1.1, a pause that holds and resumes, and polish throughout. The 1.2dev builds 52–54 were internal.

## New

- **Pause holds the picture.** Pause (Space) freezes every panel exactly as it was: the spectrum and its peak holds, the spectrogram, the waveform, the stereometer and its trail, channel levels and clip lights, correlation, the VU needle and every reading. A moment can be studied at leisure; switching Stereo, Immersive or the band count still animates.
- **Resume carries on.** Resume continues the same measurement: Integrated loudness, loudness range, held peaks and the histories continue, and the time spent paused is left out. A change of source, routing or sample rate while paused, or Reset, starts a fresh measurement instead. While paused, the toolbar and the Meter menu offer Resume Capture.

## Fixes

- **Resume and Reset after a pause:** the spectrum, spectrogram, waveform, soundstage and level panels stayed frozen after resuming, and Reset seemed to do nothing. Paused panels went to rest and nothing woke them.
- **Welcome on first launch:** "Don't show this again" from an earlier build is kept in the app's container, which survives reinstalling, so the welcome never came back. The first launch of each new build now shows it.
- **Microphone use while metering an output:** macOS treated Auraliscope as using the microphone (orange indicator, microphone permission check) whatever source was chosen. Outputs are now read without the microphone path, so macOS asks only for System Audio Recording. On the test Mac the built-in microphone was never opened, before or after.
- **Waveform legend:** in Stereo it kept invisible space for Height and LFE and did not sit flush right.
- **Microphone access indicator:** Settings ▸ Audio checks it at every launch, whenever the app comes forward, when the pane opens and after each request; the diagnostic log records it at launch.
- **Space in Settings and the welcome:** Space paused or started capture from anywhere in the app, so in Settings (with Full Keyboard Access) it never reached the focused control, and behind the welcome it started metering. It now pauses and resumes only while the meter window is focused.

## Polish

- Before metering starts, the summary chip and the status line say **Standby**, not "Paused" or "Choose an input device".
- An output that delivers only digital silence for 5 seconds shows **No sound from this output** in the status bar and in Settings ▸ Audio, with how to allow System Audio Recording if an app is playing to it.
- Settings and About no longer reopen by themselves at launch.
- The 16 waveform lanes of 9.1.6 keep their channel names in the smallest window.
- The dropped-frames count carries across a resume.
- About, the README and the third-party notices state that the service names in the loudness target menu are their owners' trademarks and that Auraliscope is not affiliated with them.

## Rights and platform

The 1.2dev builds read the System Audio Recording permission through a private macOS function. It has been removed: the app uses documented Apple APIs only. `docs/IP_REVIEW.md` records the review of code provenance, licenses, trademarks and platform terms, and its open points; it is not a patent search.

## Requirements

Apple Silicon, macOS 13 or later. Output capture requires macOS 14.2 or later and System Audio Recording permission; input capture requires Microphone permission.

## Validation

32 core checks (one new, for the output-tap reader) and 308 localization keys in each of three languages pass, with 13 settings checks. Pause and resume (10 checks, including 30 rapid toggles) pass on the demo signal and on a real output tap, as do a real-hardware source switch, the Space shortcut, device removal and return, the paused peak reset and the capture self-test on a Pro Tools Audio Bridge. All 13 Immersive layouts render offscreen. Thread Sanitizer and Address Sanitizer runs of these flows report no issues. The DSP benchmark is unchanged from 1.1 rc 2; the live app uses about 13–21 % of one core in a full-size window at 60 Hz, and about 0.1 % while paused. Details are in `TEST_REPORT.md` beside the build.

Not yet validated: the System Audio Recording prompt and indicator on a clean Mac and on macOS versions before 26, and first launch on other Macs.

## Distribution notice

Ad hoc signed and not notarized. Open the disk image, drag the app to Applications, and approve the first launch in System Settings ▸ Privacy & Security (Open Anyway); "Read Me First" in the disk image has the steps. macOS treats each build as a new app, so it asks for audio permissions again.

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
