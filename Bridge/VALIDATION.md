# Auraliscope Bridge / Auraliscope LABS 1.3dev: validation report


## Build 71 — 2026-10-08

Build 70 is the baseline. The spectrogram's analysis (FFT sizes, windows, zones, cadence, calibration) and the 64
published spectrum bands are unchanged; this round changes how the waterfall and the live spectrum are drawn and
adds 128 fine spectrum bands.

### Findings and changes

| Area | Finding (build 70) | Change (build 71) |
|---|---|---|
| Waterfall cells | A 1/30 s column is 8–12 device pixels wide in a typical window; one-pixel hard edges turned music into tiles and a sweep into a staircase | Cells ease into their neighbours (smoothstep over one cell, centre to centre, never below one device pixel); each centre keeps its exact level; minified pixels still take the loudest covered cell |
| Colour | One-hue ramp: level steps differ only in brightness | Heat (default), Theme and Gray maps; light appearance runs paper → ink; shader reads 33 stops (each Heat stop exact) from a uniform buffer; legend, fill and export use the same map |
| Live spectrum | 64 bands (about 1/6.4 octave) merge neighbouring notes in the low mids | 128 fine bands from the same 8192-point transform (RESULT tag 51), about 1/13 octave; curve, holds, average and hover use them |
| Calibration choice | — | The fine bands are not taken from the waterfall column: its short treble windows read broadband sound ~3 dB higher per halving, which bent a pink-noise average flat above ~1.5 kHz in a trial. With the single transform pink noise averages to a straight −3 dB/octave line (rendered check) |
| Ballistics | Fixed 22/s critically damped filter | Response setting: Fast 22/s (build 70), Medium 10/s (default), Slow 4/s; holds and average unaffected |
| Silence | Curve collapsed onto the floor edge and outlined it | Segments on the floor are not drawn |
| Export | 2 px per column: a 6 s image was 418 px wide and cut off its caption; no colour scale | At least 900 px plot, colour scale under the caption |

### Validation

- 48 core checks (new: fine bands read a sine within 0.1 dB at 55 Hz–12.3 kHz at 44.1/48/96 kHz and agree with the
  64 bands within 0.1 dB), scalar/SIMD kernels and 368 localization keys passed; AddressSanitizer passed the 48
  core checks and kernels.
- Bridge analysis tests (new: tag 51 carried in full; a result without it shows each of the 64 bands across its two
  halves) and transport tests passed. `--test-spectrum-average` passed with the fine bands.
- `Bridge/Tools/SpectralRegression.swift` built from build 70 and build 71 sources: all **2,080,800 float
  measurements bitwise identical** (64-band spectrum, 512-row spectrogram, peak frequency and level, 44.1–192 kHz).
- `Bridge/Tools/CheckSpectrogramRendering.swift`: 9,519 GPU/CPU comparisons passed (footprints, ring wrap, borders,
  tilt, hard and eased edges at 1–20 device pixels per cell, the plateau-free whole-cell easing).
- Rendered checks (offscreen `--render-preview` with a real song, synthetic chords/vibrato/sweep at 48 and 96 kHz and
  pink noise; window snapshots in dark and light, Stereo and Immersive, mirrored, inspector over waterfall and
  spectrum; Settings ▸ Panels). No seams at the zone boundaries in pink noise.
- VST3 validator: 537 passed, 0 failed. Plugin to receiver (`e2e-probe.sh`): 12/12 with bitwise passthrough
  (VST3 and AU, mono/stereo, 44.1–192 kHz, three instances, controls, editor close). Plugin to Labs
  (`e2e-app.sh`): 11/11 scenarios (reconnect, AU mono, multiple inserts, rate change, states, restart, duplicate,
  hold, held, controls, plugin before Labs); Labs' self-test now also compares the fine bands with its own
  analysis of the same signal: largest difference 0.001 dB.

### Cost

`refreshSpectrum` (one 8192-point transform with its bands, notes and peak), P-core micro-benchmark at 48 kHz:
build 70 19.7 µs; build 71 21.2 µs with both band sets. The first build 71 version took 24.3 µs: the band loop's
per-access runtime checks and estimator retains dominated, and reading through buffer pointers removed them (the
64-band results stay bitwise identical).
Plugin CPU, `Bridge/Tools/CompareResources.py`, three alternating 15-second pairs per case against the build 70
VST3, same synthetic host, one Mac, percent of one logical core including host overhead; every run had bitwise
passthrough. This Mac's run-to-run spread was large in this session (up to ±20 % within a pair), so these medians
show no measurable change in either direction; the micro-benchmark above is the precise figure (1.5 µs per
transform, 60 transforms a second: about 0.01 % of a core per insert).

| Scenario | Build 70 median | Build 71 median | Relative change |
|---|---:|---:|---:|
| 8 mono, 48 kHz | 16.121% | 14.481% | −10.2% |
| 32 stereo, 48 kHz | 33.267% | 33.695% | +1.3% |
| 8 stereo, 96 kHz | 27.308% | 27.058% | −0.9% |
| 8 stereo, 192 kHz | 33.151% | 31.413% | −5.2% |

### Limits

Bass resolution, the ~85 ms centre delay (93 ms at 44.1 kHz), broadband levels that depend on the zone's window in
the waterfall, and sweep attenuation remain as in build 70. Eased cells are a display reconstruction between
measured cells, not added resolution; a fast glide still shows one step per column. The fine bands share the
64 bands' semantics (loudest bin, sine-calibrated), so noise reads per bin, not as a PSD. Heat is a hand-tuned
inferno-like map, not a published colour standard. Installer and bundles are ad hoc signed or unsigned, not
notarized; automated checks do not replace real DAW sessions, Intel hardware or older macOS.

## Build 70 — 2026-10-08

Build 69 is the checked-in baseline for this round. The FFT sizes, windows, normalization, frequency zones,
30 Hz spectrogram cadence, protocol and amplitude semantics remain unchanged. The changes are in display
sampling, curve interpolation, readouts and average lifecycle. No new work runs on the audio callback.

### Confirmed causes and changes

- The compressed waterfall sampled at most six cells along each axis. This can skip an isolated peak when a
  pixel covers more cells. It now visits every intersecting cell and preserves the maximum tilted level.
- Magnified cells had a minimum edge ramp of 0.3 cell. A 20-pixel-wide column therefore had a six-pixel ramp.
  Edges now use one physical pixel of antialiasing, independent of magnification.
- Age faded the color by up to 14%, so equal levels at different times had unequal colors. That fade is removed.
  Range, tilt and the existing tone curve still control display color; numeric levels remain untilted dBFS.
- Catmull–Rom could overshoot the endpoints between spectrum bands. For example, neighboring bands at -12 dB
  with -96 dB outside them produce a -1.5 dB midpoint: an invented 10.5 dB peak. Both live and average traces now
  use monotone cubic Hermite interpolation with harmonic-mean slopes. It is a drawing change, not added resolution.
- Hover metadata previously allocated a full extra FFT analyzer on the UI thread and named only the shorter window
  in a transition. A shared lightweight row plan now supplies labels, including both contributing windows.
- Spectrum hover reports the selected band's center and bounds. Waterfall hover uses the selected column's center
  and scroll phase, plus the existing half-span analysis delay. A narrow header no longer truncates technical text.
- The average now restarts when sample rate or Stereo/Immersive aggregation changes, and waits for a fresh snapshot
  after reset/configuration changes. Settings describe an average of received measurements, not every audio frame.

### Validation

- 47 core checks, scalar/SIMD kernel checks, and 358 localization keys passed. AddressSanitizer passed the same
  47 core checks and kernels before the final header/readout/text-only refinements.
- Bridge analysis and transport suites passed; VST3 validator: 537 passed, zero failed.
- Plugin-to-receiver: 12/12; plugin-to-app: 11/11, including reconnect, pause, reset and channel formats. The later
  UI-only refinements are checked with the built app's average-lifecycle diagnostic and offscreen rendering.
- `Bridge/Tools/SpectralRegression.swift`: 3,600 columns at 44.1/48/96/192 kHz, including a steady tone, close tones
  at three relative phases, impulses, a logarithmic sweep and tones at the five transition frequencies.
  **2,080,800 float measurements are bitwise identical** between build 69 and build 70 (spectrum, spectrogram,
  peak frequency and level). Maximum steady 1 kHz tone error in this fixture: 0.000001 dB. This is an isolated-tone
  check, not a general accuracy claim for mixtures or unresolved tones.
- `Bridge/Tools/CheckSpectrogramRendering.swift` compiles the actual shader helpers and compares against exhaustive
  CPU maxima. Build 70 passes 8,509 checks: isolated peaks at every row, 1/3/7/13/33-cell footprints, wraparound,
  borders, all tilts, and edge widths at 1–20 device pixels per cell. Build 69 fails 4,608 footprint checks and 84
  edge-width checks, plus 80 zero-area boundary-contact checks. The latter now exclude cells that only touch
  a pixel boundary. These intentionally difficult reductions do not represent a typical window's workload.
- Identical 12-second tone/pair/impulse/sweep WAV and display settings rendered before/after. The exported analysis
  plot has zero changed RGB values; the main display changes are the intended age and interpolation corrections.
- Actual compact dark window inspected. Full-window light/mirrored and real-DAW testing remain tester tasks;
  offscreen synthetic previews do not establish those interactions.

### Performance and limits

Three alternating 15-second pairs per case, same synthetic VST3 host, one Mac. All 24 runs had bitwise audio
passthrough and zero process errors. CPU below is percent of one logical core, including host overhead.

| Scenario | Build 69 median | Build 70 median | Relative change |
|---|---:|---:|---:|
| 8 mono, 48 kHz | 16.911% | 17.046% | +0.8% |
| 32 stereo, 48 kHz | 33.738% | 33.770% | +0.1% |
| 8 stereo, 96 kHz | 28.277% | 28.331% | +0.2% |
| 8 stereo, 192 kHz | 34.515% | 34.868% | +1.0% |

These differences are small; no CPU speedup is claimed. The GPU stress batch (2,560 blocks, up to 33×33 cells)
took about 0.60 ms versus 0.05–0.06 ms with sparse sampling. Exhaustive reduction is deliberately more expensive
under extreme compression. Ordinary footprints cover far fewer cells. This is not a whole-app frame-time benchmark.

Bass resolution, approximately 85 ms center delay at 48/96/192 kHz (93 ms at 44.1 kHz), broad-band window-dependent
levels, sweep attenuation and the live curve's existing temporal damping remain. A pixel's maximum is a display
summary; its hover reads a selected original cell, not the maximum of all cells covered by that pixel. The average
uses distinct received snapshots and excludes silence; it is not continuous time-weighted PSD integration, and can
be biased if display frames are skipped. Window labels describe this build's analysis: use the bundled plugins.

Installer/bundles are ad hoc signed or unsigned as documented; not notarized. Automated checks do not replace
administrator installation, real DAW use, Intel hardware or older-macOS validation.

## Build 69 — 2026-10-08

This round targets spectrogram clarity without changing what the levels mean. Every change below follows a
measured cause; protocol 3, schema 1, the 512-row column, sine calibration, colour ranges, tone curve and palette are
unchanged. Measurements use a harness that runs synthetic signals through `SpectrumAnalyzer.spectrogram` one column
per 1/30 s, built once from the build 68 sources and once from build 69 (same inputs, same settings).

### Causes found

| Stage | Finding | Evidence | Change |
|---|---|---|---|
| Window | Hann sidelobes (−31 dB, 18 dB/oct) fall inside the 78 dB colour range; with the short treble windows a loud tone fanned out ±2 semitones at the floor | −12 dBFS tone, width at −78 dB: 4.4 semitones at 1–10 kHz (build 67, one 8192 window: 0.2–2.8) | Blackman–Harris (≤ −92 dB) at twice the Hann length where the span resolves ±½ semitone; Hann kept below |
| FFT lengths | 512-point windows (11 ms) above 6 kHz bought time detail the 33 ms column cannot show, at 4× the frequency smear | impulse lit 1 column with 512 or 1024 points | shortest window 512 only above 12 kHz |
| Span at high rates | history fixed at 8192 samples: 43 ms at 96 kHz, 21 ms at 192 kHz | 440 Hz tone width at −78 dB: 4.2 st at 48 kHz, 13.1 at 96, 25.5 at 192 | history ~170 ms at every rate |
| Coverage | 50 % overlapped Hann frames weigh instants unevenly (power ∝ w²) | four identical clicks: two drawn dimmer (pixel luminance 14–15 vs 19) | frames chosen for ≤ 1 dB ripple across the frame lattice |
| Display | linear interpolation between columns and rows | a one-column click drawn as a two-column triangle peaking in one pixel | cells drawn as boxes, 1 px / 0.3-cell edge ramp, loudest of covered cells |
| Not causes | texture size (r32Float, read per texel, no hardware filtering), drawable scale (follows backing scale), FFT normalisation (sine within 0.05 dB in every zone), zone timing (all windows centred on one instant), tone curve | | unchanged |

Zero padding is not used anywhere; resolution claims refer to window length.

### Measured before and after (48 kHz unless stated)

Width of a −12 dBFS tone in semitones at −20 / −40 / −60 / −78 dB below its peak (rows are 0.23 semitone; 512 rows):

| Tone | Build 68 | Build 69 |
|---|---|---|
| 100 Hz | 3.04 / 4.20 / 8.41 / 17.75 | 3.04 / 4.20 / 8.41 / 17.75 (unchanged by design) |
| 440 Hz | 0.47 / 0.93 / 2.34 / 4.20 | 0.47 / 0.93 / 2.34 / 4.20 |
| 1 kHz | 0.70 / 1.17 / 2.34 / 4.44 | 0.47 / 0.93 / 0.93 / 0.93 |
| 2.5 kHz | 0.47 / 0.93 / 2.34 / 4.44 | 0.47 / 0.70 / 0.93 / 0.93 |
| 5 kHz | 0.70 / 0.93 / 2.34 / 4.20 | 0.70 / 0.70 / 0.70 / 0.70 |
| 10 kHz | 0.70 / 1.17 / 2.34 / 4.44 | 0.70 / 0.70 / 0.70 / 0.93 |
| 440 Hz at 96 kHz | 1.64 / 3.04 / 6.54 / 13.08 | 0.47 / 0.93 / 2.34 / 4.20 |
| 440 Hz at 192 kHz | 3.04 / 5.37 / 11.45 / 25.46 | 0.47 / 0.93 / 2.34 / 4.20 |

- Level: sine peak error 0.00 dB (±0.05 dB tested) in every zone at 44.1, 48, 96 and 192 kHz.
- Close tones (smallest spacing with a 10 dB dip between two equal tones): 60 Hz 2.55 st, 110 Hz 0.50, 220 Hz 1.25,
  440 Hz 0.75 (build 68 0.75), 1 kHz 0.60 (0.65), 3 kHz 0.45 (0.75), 8 kHz 0.60 (0.65).
- Impulse: lit columns (within 20 dB of the row's maximum) 4 at 60–200 Hz, 3 at 1 kHz, 1 at 4 and 12 kHz, all rows'
  maxima in the same column (build 68 identical); clicks now read the same wherever they fall.
- Sweep (20 Hz–20 kHz in 8 s): ridge within ±0.15 semitone of the instantaneous frequency (both builds); −20 dB width
  at 13.5 kHz 0.93 st (same), at 1.7 kHz 1.64 st (1.17). The fast sweep reads up to ~3 dB lower than in build 68
  between 0.8 and 3.4 kHz because the longer windows see it move further: the documented time cost.
- White noise (−20 dBFS RMS) per row: as before it reads per analysis bandwidth (+3 dB per halving of the window);
  2–8 kHz now 0.2–1.3 dB lower, 16 kHz the same.
- Time cost: above 750 Hz windows are twice as long, Blackman–Harris concentrates them (effective duration ~1.44× the
  Hann window they replace); above ~3 kHz they remain shorter than one column. The column's centre is half the span
  before it is published: 85 ms at 48/96/192 kHz (build 68: 85, 43, 21 ms); the inspector's time includes it.
- Live spectrum at high rates: the transform now spans the same ~170 ms at every rate (bins 5.9 Hz). The peak
  readout's test (20 offsets across a bin, within 0.3 cents and 0.02 dB) now includes 55 Hz at 192 kHz, and single
  bass notes (C1, E1, A1, A2) are detected at 192 kHz as at 44.1–96 kHz.
- Rendering: the probe programme (tones and close pairs, clicks, sweep, chord) and the 18 s synthetic music
  programme, rendered with both builds at the same size, span (8 s), range (Standard) and tilt (flat): build 69 shows
  thinner partials above 1 kHz, separate hi-hat strokes, and clicks of equal brightness; the bass is unchanged.

### CPU

P-core micro-benchmark, build 68 → 69: one waterfall column (30 per second) 44 → 78 µs at 48 kHz, 67 → 140 µs at
96 kHz, 81 → 257 µs at 192 kHz; one spectrum transform (60 per second) 19 µs at 48 kHz (unchanged), 41 µs at 96 kHz,
152 µs at 192 kHz (the transform is 2× and 4× longer there).

Paired full-plugin comparison of the final build, `CompareResources.py <build68.vst3> <build69.vst3>` (15 s runs,
three alternating-order pairs, medians; every run bitwise passthrough, zero process errors; the 96 kHz case is new to
the tool):

| Scenario | Build 68 CPU | Build 69 CPU | Relative change |
|---|---:|---:|---:|
| 8 mono instances, 48 kHz, 256 frames | 14.67% | 17.89% | +22.0% |
| 32 stereo instances, 48 kHz, 256 frames | 32.91% | 34.49% | +4.8% |
| 8 stereo instances, 96 kHz, 512 frames | 22.20% | 28.14% | +26.8% |
| 8 stereo instances, 192 kHz, 1024 frames | 29.57% | 34.37% | +16.2% |

Run-to-run spread is large in the small cases (8 mono baseline: 12.5, 14.7, 16.2 %). Two intermediate runs split
the cost: the spectrogram changes alone measured +12.7 / +6.6 / +15.5 / +7.8 % against build 68 (same four cases),
and the longer spectrum transform alone +0.8 / +0.3 / +3.6 / +13.0 % against that.

The analysis runs on the plugins' analysis threads, never on the host's audio callback (unchanged).

### Completed validation

| Check | Build 69 result |
|---|---|
| Core suite | 45/45 (new: window choice and leakage > 85 dB down 1.5 semitones away, rate-independent zones, Blackman–Harris estimator against a real DFT, cell-exact history reads, peak readout and bass notes at 192 kHz) |
| AddressSanitizer | core 45/45 and kernel checks pass |
| Localization | 359 keys, en / zh-Hans / ko |
| Bridge analysis | 95/95 |
| Bridge transport | 95/95 |
| Steinberg VST3 validator | 537 passed, 0 failed |
| Plugin → ResultProbe | 12/12, VST3 and AU at 44.1–192 kHz; bitwise audio passthrough |
| Plugin → LABS | 11/11 |

Not done: manual tests in DAWs, a real-pointer test of the inspector (checked with `--snapshot-inspect`).

## Build 68 — 2026-10-08

This round rewrites the spectrogram end to end (analysis in the shared core, display, legend, inspector, export) and
makes the spectrum's and peak readout's level and frequency estimates exact for Hann windows. Protocol 3, schema 1,
the 512-row column format, tick rates, loudness, true peak and history capacities are unchanged. Logs are in the
scratch directory of the session that built it; the commands below reproduce them.

### Accuracy checks (core suite)

- Sine calibration of the new spectrogram: a −6.02 dBFS sine reads within **0.05 dB** at 50 Hz, 440 Hz, inside each
  zone blend (800 Hz, 1.1, 1.7, 3.5, 7 kHz) and up to 18 kHz at 48 kHz, and at 44.1 and 96 kHz (build 67: up to
  1.4 dB low between bins).
- Window choice: 8192/4096/2048/1024/512 points at 48 kHz with 1/1/2/4/7 frames per column; every row keeps at least
  64 × its bin width (the bass below that is limited by the 8192-point history, as before).
- Leakage: five semitones from a tone the row stays below −60 dBFS wherever the resolving rule holds.
- Time: a 4 ms 8 kHz burst at the column's instant reads above −40 dBFS in its row, and the same burst 75 ms earlier
  at least 40 dB lower (with 8192 points alone it would still show).
- Peak readout: frequency within **0.3 cents** and level within **0.02 dB** at 20 offsets across a bin, at 41.2, 55,
  440 Hz (48 kHz), 98 Hz (44.1 kHz) and 3 kHz (96 kHz). Build 67 measured 2.85 cents / 0.32 dB worst at 55 Hz.
- Display history: float storage, interpolation, wrap, non-finite input, reset; tone curve monotonic with exact
  end points for every color range; tilt pivots at 1 kHz; fixed spectrogram spans fit the history.

### Offline rendering

`--render-preview --preview-audio <file>` runs a file through the real analysis into the waterfall; the same 18 s
synthetic programme (bass, chords, vibrato lead, kick, snare, hi-hats, sweep) rendered with build 67 and build 68
code shows the same palette and layout, with hi-hats and onsets as thin strokes instead of ~170 ms smears and the
sweep and vibrato sharper. `--preview-image` checks the exported image; `--snapshot-inspect x,y` the inspector.

### CPU

App DSP benchmark (`--benchmark-dsp`, 100 simulated seconds at 48 kHz, release build, median of 3):

| Pipeline | Build 67 | Build 68 |
|---|---:|---:|
| Full 9.1.6, stereo spectrum | 0.61 % | 0.77 % |
| Full 9.1.6, 16-channel Spatial spectrum | 1.23 % | 1.90 % |

One spectrogram column (micro-benchmark, P-core): 48 µs at 48 kHz (0.145 % of a core at 30 columns/s), 85 µs at
192 kHz. The 8192-point zone reuses the spectrum's transform; zones keep preallocated scratch (no allocation per
column); the Hann estimator is table-driven.

Paired full-plugin comparison, `CompareResources.py <build67.vst3> <build68.vst3>` (15 s runs, three
alternating-order pairs, medians; every run bitwise passthrough, zero process errors):

| Scenario | Build 67 CPU | Build 68 CPU | Relative change |
|---|---:|---:|---:|
| 8 mono instances, 48 kHz, 256 frames | 11.215% | 12.427% | +10.8% |
| 32 stereo instances, 48 kHz, 256 frames | 29.885% | 31.543% | +5.5% |
| 8 stereo instances, 192 kHz, 1024 frames | 22.729% | 26.398% | +16.1% |

The plugins' analysis threads run at background priority and usually on efficiency cores, so their percentages are
larger than the P-core micro-benchmark. At 192 kHz the treble windows are repeated more often to cover each 1/30 s
column, which is the main cost there. One mono pair ran far below the others in both builds (5.6 / 4.8 %); the
medians exclude it.

### Completed validation

| Check | Build 68 result |
|---|---|
| Core suite | 45/45 (new: multi-resolution spectrogram, Hann estimator; extended history, tone, tilt, span) |
| AddressSanitizer | core 45/45 and kernel checks pass |
| Localization | 359 keys, en / zh-Hans / ko |
| Bridge analysis | 95/95 |
| Bridge transport | 95/95 |
| Steinberg VST3 validator | 537 passed, 0 failed |
| Plugin → ResultProbe | 12/12, VST3 and AU at 44.1–192 kHz; bitwise audio passthrough; plugin spectrum within 0.5 dB of the app's own analysis (the probe must be rebuilt with `build-tools.sh`: a build-67 probe compares against the old, uncorrected levels and fails at 192 kHz by 1.2 dB) |
| Plugin → LABS | 11/11: reconnect, mono, multiple instances, rate change, states, restart, duplicate, hold, held, controls, analysis before app launch |
| Paired resource runs | 18/18, zero output mismatches and process errors |
| Window snapshots | dark and light, minimum 1000 × 628 window (legend drops its extras instead of wrapping), mirrored orientation, Settings › Panels |

**Boundaries:** as for build 67: no administrator install of the package, no auval rescan of an installed AU, no
real audio hardware, no DAW (REAPER, Logic, Cubase, Live) rerun, no Intel hardware. The hover inspector and context
menu were checked through diagnostics and offline renders, not with a real pointer.

## Build 67 — 2026-10-05

This round starts from the delivered build 66 and retains its true-peak priming/reset fixes. It changes only two
shared DSP kernels plus tests, tooling and build metadata. Protocol 3, schema 1, measurement coefficients, tick
rates and history capacities are unchanged. Logs are in `.build/bridge/validation/build67/`.

### Implementation and numerical checks

- Mono/stereo K-weighting runs in one two-double vector instead of computing eight lanes including unused silence.
  Three or more weighted channels retain the previous grouped kernel. The recursive equations and energy
  accumulation order are unchanged, and no allocation or lock was added.
- Stereo-band output writes use constant SIMD lane indices, preserving the parallel cascades and avoiding runtime
  indexing of a vector array. A regrouped alternative measured slower and was discarded before packaging.
- `Tests/AnalysisKernelsChecks.c`, included in `scripts/test.sh`, compares both kernels with independent scalar
  recurrences: 0–16 weighted channels, 0–12 stored band lanes, empty and irregular buffers, carried states, energy
  accumulation, silence tails and unwritten output guards. K-weighting tolerance is 1e-10 (relative for large
  energies); band tolerance is 2e-6. These checks pass natively and under AddressSanitizer, and the x86_64 build
  also passes under Rosetta. Rosetta is not Intel hardware validation.
- A separate dynamic-library A/B harness loads the build-66 C kernels and the new kernels together. Its band
  outputs and states are bit-identical; weighted energies/states match within 1e-11 on that signal. Five
  alternating-order pairs, each processing 5.12 million frames, give these kernel-only medians:

| Kernel | Build 66 | Build 67 | Change in elapsed time |
|---|---:|---:|---:|
| K-weighting, mono | 0.041099 s | 0.028130 s | −31.6% |
| K-weighting, stereo | 0.041110 s | 0.028077 s | −31.7% |
| Stereo band filter, ten output lanes | 0.048576 s | 0.046692 s | −3.9% |

These are kernel costs on this Mac, **not percentages of DAW CPU saved**. The full-plugin comparison below includes
other analysis and host overhead.

### Paired full-plugin CPU comparison against build 66

`python3 Bridge/Tools/CompareResources.py <build66.vst3> <build67.vst3>` runs the same HostHarness with
no LABS receiver, a private socket, synthetic audio, 15 seconds per run, three alternating-order pairs per case.
Every one of the 18 runs passed bitwise audio passthrough and reported zero process errors. CPU includes child
process user + system time (including startup/teardown), divided by the configured audio duration; 100% means
one core. These are medians, not the best run. Raw observations: `build67/resources-vs66.log`.

| Scenario | Build 66 CPU | Build 67 CPU | Relative change |
|---|---:|---:|---:|
| 8 mono instances, 48 kHz, 256 frames | 13.160% | 12.635% | −4.0% |
| 32 stereo instances, 48 kHz, 256 frames | 34.188% | 33.419% | −2.2% |
| 8 stereo instances, 192 kHz, 1024 frames | 25.748% | 25.296% | −1.8% |

Run-to-run variation remains: for example, the 192 kHz baseline range was 23.254–26.753%, and the new range
19.861–25.885%. Three pairs do not establish statistical significance. These modest whole-process reductions
are observations on this Mac, not a guaranteed DAW improvement; they must not be confused with the 32%
K-weighting-only reduction above. LABS rendering CPU is not included in this comparison.

### Completed validation

| Check | Build 67 result |
|---|---|
| Core suite | 43/43, including dense multi-tone and 576 true-peak onset combinations |
| New scalar/SIMD kernel checks | pass, native arm64 and x86_64 under Rosetta |
| AddressSanitizer | core 43/43 and new kernel checks pass |
| Localization | 341 keys, en / zh-Hans / ko |
| Bridge analysis | 95/95 |
| Bridge transport | 95/95, also 95/95 with ThreadSanitizer (C/C++ instrumented; Swift core uninstrumented) |
| Steinberg VST3 validator | 537 passed, 0 failed |
| Plugin → ResultProbe | 12/12, exact build-67 VST3 and AU; bitwise audio passthrough |
| Plugin → LABS | 11/11: reconnect, mono, multiple instances, rate transition, states, restart, duplicate identities, hold, controls and analysis before app launch |
| Paired resource runs | 18/18, zero output mismatches and process errors |
| Installer payload | App + VST3 + AU identical to staged bundles; strict signatures, permissions, no AppleDouble entries, no relocation |
| Bundle versions | App 1.3 / build 67; plugins 0.67 / build 67; plugin internal version text 1.3dev build 67 |

**Boundaries:** synthetic test-host runs are not DAW compatibility certification. This round does not install the
package as administrator, rescan an installed AU with auval, exercise real audio hardware, or rerun REAPER, Logic,
Cubase, Live, FL Studio or GarageBand. No Intel-hardware or older-macOS runtime test. No new app-window screenshot
was attempted in this round; the UI code is unchanged from build 66. App remains arm64/macOS 13+, plugin bundles
contain arm64 and x86_64. Ad hoc code signatures; no Developer ID installer signing or notarization.

## Build 66 — 2026-10-05

This is a new build of the build-65 experiment (`cee274c`), validated below on Apple M1 Max / macOS 27.2.
Protocol 3 and analysis schema 1 are unchanged. Older sections are historical evidence, not build-66 host claims.
Logs: `.build/bridge/validation/build66/`, plus the individual probe/app/harness logs in its parent directory.

### Changes and measured accuracy

- **True-peak startup/reset priming.** The old analyser treated unavailable history as silence. Baseline run:
  the right channel of the 1499 Hz / 0.25 test tone starting at sample 777 held **−11.012 dBTP**, although its
  analytic crest is **−12.041 dBTP**. Build 66 reads **−12.041 dBTP** (left: **−6.021 dBTP**).
  Startup now uses the same 65-sample history fill as a break. Sample peaks are retained from the first sample;
  interpolation near an unknown edge is intentionally omitted. This affects both device analysis in LABS and
  plugin analysis, and does not alter the production checkout.
- **Real tails at the priming boundary.** If a nonzero sample arrives during priming, later observed silence drains
  its filter tail even when a host buffer ends exactly at sample 65. This also fixes that boundary after a break.
- **True-peak reset while paused/idle.** Clears the published snapshot as well as pipeline state, so the next RESULT
  and plugin summary show zero without waiting for new audio; measurement time and other values stay unchanged.
- **Build identity.** C++ object dependencies include `prototype-version.sh`, updating compiled version strings and
  the editor's Objective-C class names when the build number changes. Both plugin binaries contain `1.3dev build 66`.
- **Launch selection.** Every candidate, including LaunchServices' default, must have an executable and must not be
  in `.Trash` or `.Trashes`. This is source-reviewed; no destructive manipulation of registered installed copies
  was used as a test.
- **Test isolation.** HostHarness `--format au --bundle …component` registers the exact staged factory only in its
  test process. AU tests no longer silently select an installed copy. App e2e uses a private Unix socket.

### Completed checks

| Check | Build 66 result |
|---|---|
| Core suite | **43/43**, also **43/43 under AddressSanitizer** |
| Localization | **341 keys**, en / zh-Hans / ko |
| Bridge analysis | **95/95** |
| Bridge transport | **95/95**, also **95/95 under ThreadSanitizer** (C/C++ instrumented; Swift library uninstrumented) |
| Steinberg VST3 validator `-e` | **537 passed, 0 failed**, build-66 staged VST3 |
| Plugin → ResultProbe (`e2e-probe.sh`) | **12/12**, exact build-66 VST3 and AU binaries; output identical to input |
| Plugin → LABS (`e2e-app.sh`) | **11/11**, including reconnect, mono, multiple instances, 96 kHz transition, bypass/offline/idle states, app restart, duplicate identities, held display, controls and analysis before app launch |
| AU and VST3 editors | Open/close tests pass; captured editor layouts inspected; AU log confirms staged build 66 |
| Installer extraction | Three payloads match staged bundles byte for byte, internal signatures valid, non-relocatable, readable by all users, no AppleDouble entries |

New core accuracy coverage: six rates (44.1, 48, 88.2, 96, 176.4 and 192 kHz), four frequencies (997, 1499, 15,000
and 20,000 Hz), eight initial phases, three buffer sizes (1, 7, 257): **576 onset cases**, each within **0.005 dB**
of the analytic crest and split-invariant within **1e-6 linear amplitude**. There are also 24 priming-boundary burst
cases, six one-sample captures, and the existing dense 20-tone, near-Nyquist and real-silence tail tests. The latter
now supplies observed preceding silence explicitly, instead of assuming silence before capture began.

### Resource spot check against build 65

Same HostHarness, no receiver, 10 seconds per run (one pair per case); process CPU is a percentage of **one core**.
This is a short scheduling-sensitive comparison, not a speedup claim. RSS difference was at most 0.1 MB.

| Instances / format | Build 65 CPU | Build 66 CPU | Build 66 worst audio process call |
|---|---:|---:|---:|
| 1 × 48 kHz stereo | 3.3% | 2.9% | 17.2 µs |
| 8 × 48 kHz stereo | 11.9% | 12.1% | 18.5 µs |
| 32 × 48 kHz stereo | 31.0% | 34.6% | 27.8 µs |
| 8 × 44.1 kHz mono | 11.8% | 13.7% | 25.6 µs |
| 8 × 96 kHz stereo | 21.4% | 20.3% | 22.7 µs |
| 8 × 192 kHz stereo | 26.1% | 30.3% | 34.7 µs |
| 8 × 48 kHz stereo, 4096-frame blocks | 10.6% | 10.9% | 47.5 µs |

Follow-up: three alternating-order pairs for the two largest differences gave median one-core CPU **34.84% →
35.25%** for 32 × 48 kHz stereo, and **26.40% → 27.12%** for 8 × 192 kHz stereo. All 12 repeated harness runs
reported zero output mismatches and process errors. These small increases and run-to-run spread do not establish
an improvement or exact equivalence; this remains an accuracy/reset update, not a CPU optimization claim.

### App launch and rendering smoke check

The app extracted from the final installer passes strict/deep signature verification and its Metal offscreen
preview renders successfully (visually inspected). LaunchServices with external `--stdout/--stderr` destinations
returned `-10810`; without those options it launched successfully. The saved no-window state required a subsequent
normal Open event, after which the build-66 diagnostic log entered demo mode. A full-window screenshot was not
obtained. The offscreen preview is not a substitute for an installed interactive UI test.

**Boundaries:** no administrator installation was performed. AU was loaded directly by the test host, not rescanned
or validated by `auval` as an installed build. No build-66 DAW compatibility run was performed in REAPER, Logic,
Cubase, Ableton Live, FL Studio or GarageBand; historical results below do not substitute for one. No Intel or
older-macOS runtime testing, Developer ID signing or notarization. This is an accuracy/state correctness update;
no general CPU speedup is claimed. Startup's 65-sample priming is about 1.47 ms at 44.1 kHz (sample peaks still count).

## Build 65

- **App name fix.** Build 64 installed as `/Applications/Auraliscope LABS.app`, but Finder, the Dock and the privacy
  prompts showed "Auraliscope". The release's localized `InfoPlist.strings` (en, zh-Hans, ko) set
  `CFBundleDisplayName` to "Auraliscope", and the localized name wins over `Info.plist`. `build-labs-app.sh` now
  rewrites each copy in the LABS bundle to "Auraliscope LABS" (name, display name and privacy descriptions), and
  fails if one does not. The release's files are unchanged. The privacy descriptions in `Bridge/App/Info.plist` say
  Auraliscope LABS too.
- Checked: the display name resolved per localization, as Finder does, is "Auraliscope LABS" in en, zh-Hans and ko
  (installed build 64: "Auraliscope" in all three). Plugins 0.65; plugin code unchanged.

## Build 64

- **Installer fix.** Build 63's package installed every bundle as `drwx------ root wheel`, so the app could not be
  opened and the plugins could not be read by a DAW. The external volume reports every folder as owner-only, and the
  package kept that. Its payload also carried AppleDouble `._` entries: `pkgbuild` stores each extended attribute as
  one, and macOS attaches `com.apple.provenance` to files written here, which cannot be removed; inside a bundle these
  break its sealed signature. `package-installer.sh` now sets modes to owner-writable and readable by all users, and
  replaces `pkgbuild`'s payload with one written by `payload-cpio.py`: root:wheel, the files' own modes, no attributes.
  The file list is rebuilt to match. Its self-check fails the build if any payload item is unreadable by other users
  or is a `._` file. The zips get the same permissions.
- **LABS Indigo theme**, `#6B7E97`, the slate indigo of the LABS icon's body, with a cool cream. It is the default,
  listed first. A theme saved by an earlier LABS build switches to it once on first launch; a theme chosen after that
  is kept.
- Plugins 0.64, so they replace build 63's.

Checked: release core checks (42), localization (341 keys), the installer's self-check, and an offscreen render in
the new theme. The build 64 installer was not installed here (installing needs an administrator). The analysis,
transport and plugin code are build 63's, whose results follow.

## Build 63 (early test package)

Build 63 is build 3's analysis and protocol, unchanged, with these changes (the rest of this report is build 3's):

- **Source type** in Settings ▸ Audio: *Audio devices* (inputs and outputs, analysed in the app) or *Host plugins*
  (Bridge inserts; one connected is chosen, several wait for a choice). The last device is remembered.
- The app is named **Auraliscope LABS** (bundle, menus, window title, wordmark); **Prototype experiment only** at the
  foot of the main window and the plugin window (plugin window 582 pt tall).
- The plugin's Open button launches the newest registered copy of LABS, preferring one in an Applications folder.
  Before, Launch Services picked an old build 3 copy from a dist folder with the same bundle ID; this was found in the
  leak check below.
- Plugin bundle and AU versions are 0.63 / 0.63.0, below any official release; the installer
  (`package-installer.sh`) installs app and plugins system-wide, not relocatable, without downgrading a newer plugin.

| Check (build 63 binaries) | Result |
|---|---|
| Transport tests, analysis checks, release core checks (42), localization (340 keys) | all pass |
| Steinberg validator `-e`; `auval -strict` | **537 passed, 0 failed**; **AU VALIDATION SUCCEEDED** |
| Test host, 11 app scenarios (`e2e-app.sh`) | 11/11 |
| REAPER 7.80, both formats (`e2e-reaper.sh`): live, reference, controls, offline render, identity, reopen | all pass |
| Leaks, plugins: 10 cycles × 4 instances (load, live, bypass, offline, idle, 96 kHz, mono, editor open/close, unload), `leaks --atExit` with malloc stack logging, VST3 and AU | **0 leaks**; after each unload the process holds 89–115 MB (stack logging included), 6–9 threads, 6 open files, with no growth over the 10 cycles; output identical to input |
| Leaks, app: LABS showing a plugin (launched by its button) for 150 s through bypass and a stereo → mono change | **0 leaks**; footprint 150 MB at 30 s and 149 MB at 140 s |
| Installer | payload identical to the dist bundles, signatures valid, nothing relocatable; `installer -pkginfo/-dominfo` read it; installing needs an administrator, so the actual installation was not run here |

In the app leak check, "not responding" appeared for 0.14 s: `leaks` suspends the process it inspects, so this is
expected. Only REAPER was rerun for build 63; the Logic and Cubase results below are build 3's.

## Build 3

Build: Auraliscope Labs 1.3dev build 3 with Auraliscope Bridge 1.3dev build 3 (VST3 and AUv2), protocol version 3,
analysis schema 1, branch `claude/bridge-plugin-analysis` (from the build 2 prototype `7f7e733`; application baseline
Auraliscope 1.2.2, `10e35cd`). Mac: Apple M1 Max, macOS 27.2, Xcode 27.0 (Swift 6.4). Logs in
`.build/bridge/validation/` (not committed).

Test signal throughout: L = 997 Hz at 0.5 (−6.021 dBFS), R = 1499 Hz at 0.25 (−12.041 dBFS); stereo integrated
loudness −7.76 LUFS, mono (L) −9.03 LUFS. A swapped, duplicated or scaled channel cannot pass.

Evidence is kept apart by kind: **automated** (unit and transport tests, official validators), **test host** (the real
plugin binaries in `Bridge/Tools/HostHarness`, not a DAW), **DAW runtime** (REAPER 7.80 scripted; Logic Pro 12.4 and
Cubase 15.0.30 driven through their user interface). Timing figures are measurements on this Mac; the guarantees are
structural and listed separately.

### Summary

| Requirement | Evidence | Result |
|---|---|---|
| Both formats build and pass the validators | Steinberg validator `-e`; `auval -strict` | **537 passed, 0 failed**; **AU VALIDATION SUCCEEDED** |
| Plugin output identical to input | test host compares every output block; REAPER, Logic and Cubase offline renders against the source | identical in every run; renders equal the source (Logic: outside its own printed clicks) |
| Plugin measurements match the desktop analyser | unit test on identical audio; Labs `--compare-reference` in the test host, Logic and Cubase; `ResultProbe` | mono **bit-identical**; stereo identical except correlation rounding (≤ 2.2·10⁻¹⁰); in DAWs every value within 0.002 LU / 0.02 dB / 0.001 dB spectrum |
| Mono/stereo order, rates, levels, timeline | transport tests, 12 test-host cases (44.1–192 kHz, mono, stereo, blocks 64–4096) | pass |
| Visualisation panels get what they need | RESULT carries every snapshot field the canvases read; e2e checks ordered columns, no gaps | pass |
| Labs consumes results, analyses nothing | every self-test checks `showingBridgeResults`; no pipeline exists for a Bridge source | pass |
| Analysis continues with editors closed and Labs absent | transport tests; `before-labs` scenario (5 s before launch); Cubase (16 s measured before Labs connected); Labs away and back | pass |
| Reconnection reports a coherent state | transport "Labs away and back"; app `hold`, `held` | same generation, measurement continued, integrated unchanged |
| Controls on the intended instance, acknowledged | transport (incl. wrong session, obsolete generation), app `controls`, Logic, Cubase | pass |
| Overflow and a slow display stay bounded; the audio thread never waits | transport "Slow receiver" (3 s), "Analysis falling behind" (3.5 s) | pass; worst `process()` 7–46 µs |
| CPU and memory measured | `measure-resources.sh` against build 2 | table below |
| Desktop sources unchanged | release core checks; analysis moved without change | **42/42** |

### Automated

| Check | Result |
|---|---|
| Release core checks (`scripts/test.sh`: analysers, pipeline, scales, displays) | **42/42**, localization **333 keys** (en, zh-Hans, ko) |
| Analysis checks (`test-analysis.sh`) | **86/86**: build 2's 47 (break marks, analysers at breaks, restoration) plus plugin-side analysis: equivalence with the desktop pipeline at 48/44.1/96 kHz in irregular blocks, RESULT encoding (round trip, unknown / malformed / wrong-kind fields, schema, channel counts), display assembly (order, gaps, pacing, bounded queues, generations, mono), measurement lifecycle (pause, breaks, idle ticks), streams starting mid-waveform |
| Transport tests (`test-transport.sh`) | **94/94**, also under ThreadSanitizer (C and C++ instrumented; the Swift core is linked uninstrumented) |
| Link feasibility (`probe-analysis-link.sh`) | the VST3 and AU analysis libraries loaded and run together in one process: no Objective-C class clash; 0.42 % of a core per 48 kHz stereo stream (0.81 % at 192 kHz) in a tight loop |
| Steinberg VST3 validator `-e` | **537 passed, 0 failed** |
| `auval -v` and `auval -strict -v aufx Abrg Jnbz` | **AU VALIDATION SUCCEEDED** (both) |

The transport tests cover, with the real plugin core, analysis thread and receiver: 1,600 instances created and
destroyed on 8 threads (no deadlock; both threads stop with the last instance); discovery and HELLO fields; the insert
measuring before anyone subscribes (nothing sent; −6.021 / −12.041 dBFS, −7.76 LUFS); results to a subscriber (60 per
second, first result covering the audio measured before, columns in order, about 2 s of history for a new subscriber,
the unselected instance silent); mono; a 3 s receiver stall (nothing unanalysed, a few queued results then current
state within 13 ms of the audio, every skipped column reported); the analysis starved for 3.5 s (overflow counted, a
drop break with the time missing, integrated carried on, output untouched); a format change (new generation, no
mixed results); bypass and offline (nothing measured, one break each, integrated carried on); commands (pause,
resume without a break, reset true peak, reset to a new generation, obsolete generation refused, wrong session
refused, a display's pause lifted when its connection goes, the plugin window's pause kept); identity (copies,
restoration, saved state holds no live measurement); reactivation (restart break), a 120 ms stall (not a break), a
1 s stall (idle break, results fall to silence meanwhile), a timeline jump (counted, not a break); stale results
after a quick re-selection (never replayed); Labs away for 1.5 s and back (measured on, same generation); 8 more
inserts in real time; protocol versions 1 and 2 on either side; DNS-SD discovery.

### Test host (real binaries, no DAW)

`e2e-probe.sh` (`ResultProbe`, which checks each result against Auraliscope's own analysis of the signal): **12/12**:
VST3 48 kHz stereo, 44.1 kHz mono, 96 kHz stereo; AU 48 kHz stereo, 48 kHz mono, 192 kHz stereo; three instances of
each format (the 2nd or 3rd checked); subscribing 3 s after the insert started; controls (AU); plugin window opened
and closed (both formats). Output identical to input; results at 60 per second; peaks, true peaks, momentary and
integrated loudness, dominant frequency and spectrum equal the reference (spectrum within 0.001 dB); columns in
order; nothing unanalysed.

`e2e-app.sh` (Labs' own `--bridge-selftest`): **11/11**: reconnection of the same insert under a new session (with
the reference comparison), AU mono (with comparison), three instances, a rate change to 96 kHz mid-stream (new
generation), the five states (streaming, bypassed, offline, no audio, streaming; integrated carried across), Labs
quit and relaunched during playback, a duplicated insert (ambiguous until chosen), the same insert re-identifying
(same generation, measurement continued), the connection dropped (display held; plugin measured on: 3.2 s → 5.9 s),
controls from Labs (pause holds 3.25 s → 3.25 s; reset starts generation 2), and an insert measuring 5 s before Labs
was launched (the first results cover it; comparison within 0.002 LU).

### DAW runtime

#### Host compatibility matrix (build 3)

| Host (format) | Loads, names | Live results = reference | Controls from Labs | Stop | Offline render | Duplicate / copy | Reopen |
|---|---|---|---|---|---|---|---|
| REAPER 7.80 (VST3) | yes | yes | — (not scripted) | keeps processing; FX bypass → "no audio" | offline, **nothing measured**; render = source (≤ 7.5·10⁻⁸) | copy flagged; Labs stays on the original | original found |
| REAPER 7.80 (AU) | yes | yes | — | same | same | same | original found |
| Logic Pro 12.4 (AU, out of process) | yes | **yes** (Δ ≤ 0.002 LU) | **pause, resume, reset TP, reset: acknowledged** | "no audio", back to streaming on play | offline 3 s, **nothing measured**; bounce = source outside Logic's own printed clicks (same deviation as with the Bridge bypassed) | the Stereo Out copy flagged (from build 2's project) | original restored by itself |
| Cubase 15.0.30 (VST3) | yes | **yes** (Δ ≤ 0.002 LU) | **acknowledged** | keeps processing | offline, **nothing measured**; export = source (≤ 7.5·10⁻⁸) | "(D)" copy flagged | original restored by itself |
| Ableton Live 12 Lite | not tested: the macOS Local Network prompt for Live (from the build 2 session) is left for you | | | | | | |
| FL Studio, GarageBand | not tested | | | | | | |

#### REAPER 7.80 (private profile, silent device): `e2e-reaper.sh`, all passed

For each format: live (play, plugin window open and closed, FX bypass, stop, play, quit: streaming → no audio →
streaming → held); an offline render traced by `ResultProbe` (reported offline, 0 frames measured while offline,
render equal to the source within 7.45·10⁻⁸); identity and transport (track duplicated while playing, loop, locates,
44.1 kHz and back — a new generation each time —, unload and reload: Labs back on the original; saved project holds
distinct identities); reopen (Labs finds the original by itself).

#### Logic Pro 12.4 (AU), a copy of build 2's test project

Logic re-validated and loaded build 3 in `AUHostingServiceXPC_arrow`. Live: exact, with Labs' comparison against its own
analysis passing on every value; controls acknowledged (pause: nothing accumulated; reset: generation 2). Stop and
play: "no audio" then streaming. Bounce (offline, normalize off): the insert reported offline for the 3 s Logic took,
and measured nothing; the bounce differs from the source in the same 285,960 samples as build 2's bounces (Logic's
metronome clicks and start transient; a bounce with the Bridge bypassed differs likewise); every other sample within
2 LSB. Reopen: Labs found the original insert by itself.

#### Cubase 15.0.30 (VST3), a copy of build 2's test project

Live: the insert had measured 16 s before Labs connected (Cubase processes from project load); comparison passes;
controls acknowledged. The plugin window showed its own measurement (I −7.8 LUFS, true-peak maximum, LRA, time
measured, generation). Audio Mixdown (not real time): both inserts reported offline and measured nothing; with the
leftover duplicate track muted, the export equals the source within 7.45·10⁻⁸ (unmuted, it is the sum of both tracks,
as expected). Reopen: Labs restored the original, not "(D)".

Not rerun on build 3 in Logic and Cubase: bypass and deactivate (the plugin's state machine is unchanged from build 2,
where they were checked, and is covered by the test host and REAPER).

### Resources

`measure-resources.sh` (real VST3 in the test host, 20 s per case, no receiver: every insert analysing on its own;
baseline: build 2's plugin, which does not analyse):

| Case | CPU, build 2 | CPU, build 3 | Extra CPU (analysis) | Extra memory | Worst `process()` |
|---|---|---|---|---|---|
| 1 × 48 kHz stereo | 2.0 % | 5.3 % | 3.3 % of a core | 3.1 MB | 21 µs |
| 8 × 48 kHz stereo | 4.6 % | 16.5 % | 11.9 % (1.5 % each) | 23.3 MB (2.9 MB each) | 34 µs |
| 32 × 48 kHz stereo | 13.0 % | 38.7 % | 25.7 % (0.8 % each) | 92.2 MB (2.9 MB each) | 47 µs |
| 8 × 44.1 kHz mono | 3.0 % | 17.8 % | 14.8 % | 23.4 MB | 30 µs |
| 8 × 96 kHz stereo | 7.4 % | 24.8 % | 17.3 % | 23.0 MB | 36 µs |
| 8 × 192 kHz stereo | 12.8 % | 33.0 % | 20.2 % | 23.0 MB | 67 µs |
| 8 × 48 kHz, 4096-frame blocks | 3.8 % | 12.8 % | 9.0 % | 23.4 MB | 81 µs |

CPU is process CPU time over wall time, as a share of one core. The analysis thread runs at the user-initiated QoS,
where macOS may use efficiency cores; the same work measured on a performance core in a tight loop is 0.42 % per
48 kHz stereo insert (`probe-analysis-link.sh`), so these figures are the upper, as-scheduled cost. A profile of the
8-insert case shows the time in the analysis itself (true peak, K-weighting, FFT), not in scheduling or encoding. Memory
per insert: the 1 MB capture ring, the pipeline's FFT and history buffers, the result mailbox and output buffer.
In return, Labs no longer analyses a Bridge source at all.

### Structural guarantees

- The host's audio thread only copies into the insert's preallocated ring: no allocation, lock, system call, logging,
  Swift or analysis (`BridgeCore::process`).
- Analysis runs on one thread per plugin binary, below real-time priority, with per-instance (50 ms of audio) and
  per-pass (8 ms) bounds and rotating order; if it falls behind by more than the ring, the analysis (not the output)
  loses audio, counted and marked as a break.
- Every buffer between the analysis and a display is fixed: a one-slot mailbox, column queues of 64 and 512, a 256 KB
  output buffer (16 KB high-water mark), 32 KB socket buffers; Labs keeps 8 spectrogram and 512 waveform columns.
- A display never receives a result of an earlier subscription, a column twice, or results of two formats in one
  generation.

### Known limitations and unresolved issues (historical build 3)

The onset issue in item 1 below is fixed in build 66; see the current section above.

1. **True-peak onset overshoot (finding in the shared analyser, not changed).** When a measurement starts in the middle
   of a waveform (capture started while audio plays, or a Reset while the DAW plays), the release true-peak detector
   can hold up to ~+1 dB above the signal's true peak from the first samples (reproduced in `test-analysis.sh`,
   "Stream starting mid-waveform"; the plugin and the desktop hold the identical value). Changing it would change the
   release's validated algorithm; a warm-up of the interpolator's length after a (re)start would remove it.
2. **Offline renders are not measured**, by design (a bounce is not live audio). Measuring a bounce as its own,
   labelled measurement would be a later feature.
3. **History after reconnecting:** about 2 s of waveform is recovered; the waterfall resumes from now (at most 8
   columns are replayed, so it never lags). Nothing older than the plugin's queues is kept.
4. **Labs' routing and Mono option do not apply to a Bridge source:** the plugin analyses its own channels (mono as
   L; stereo as L, R). Spatial detection does not apply (mono and stereo only).
5. **One display per insert connection.** The protocol separates shared measurement from display state, and
   commands carry their target and generation, but several displays at once (and a display-only pause control) are
   not implemented.
6. **CPU:** about 1–3 % of a core per insert as scheduled (above). Sessions with very many inserts may want a lighter
   mode (levels and loudness without the spectrum and stereo image when no display is subscribed); not implemented.
7. Plugins target macOS 11 and use the system's Swift runtime. Like build 2 (which already contained Objective-C), a
   plugin binary is not unloaded from a host process after use; its threads stop with the last instance.
8. Not verified: Ableton Live (prompt pending), FL Studio, GarageBand; Intel Macs; Logic and Cubase bypass/deactivate on
   build 3; the production transport with a team signature. Labs is not sandboxed, the builds are ad hoc signed and
   not notarized. The plugin window is English only.
9. The Swift part of the plugin is not covered by ThreadSanitizer (its threading is one thread per analyser, entered
   only from the analysis thread; the C++ hand-over is).
