# Build 114: Multi-FFT Spectrum Beta

## Baseline and scope

The development checkout is `.claude/worktrees/auraliscope-bridge-analysis`, on the existing
`claude/bridge-plugin-analysis` branch. It already contained substantial uncommitted Build 113 work. The pre-edit
source archive, hashes, status and binary Git diff are preserved in `output/multifft-beta/baseline/`. No reset,
checkout, stash, commit or remote operation was used. Delivered Build 113 files were not overwritten.

The delivered Build 103 and Build 113 `SpectrumAnalyzer.swift`, `SpectrogramAnalyzer.swift` and `MeterPipeline.swift`
are byte-identical to the pre-edit checkout. Build 103 is evidence about the old implementation, not the new
implementation's starting point. The original Spectrum is a Hann FFT: 8192 samples up to 48 kHz, 16384 at 96 kHz,
32768 at 192 kHz. Classic Spectrogram already used several centred Hann/Blackman–Harris resolutions and Welch
coverage, reusing the Spectrum's longest Hann transform. Its old joins interpolate dB levels over half an octave.
Enhanced is a separate reassigned analyser. That implementation is retained as the Legacy A/B option.

## Independent engine

`MultiFFTConfiguration` and `MultiFFTAnalyzer` have no UI, capture, or Bridge dependency. `MeterPipeline` optionally
feeds the analyser the same mapped planar L/R PCM as the existing measurements. No audio callback was changed.
The desktop DSP worker creates/replaces/releases the optional analyser on its serial consumer queue. With the panel
closed, there is no analyser, history, FFT setup, timer or transform for this feature. Existing analysis continues.

The three FFTs have independent power-of-two sample counts (512–65536), but a **common sample centre** and cadence.
Let `span=max(Nlow,Nmid,Nhigh)`. The rings hold the newest `span` samples. A window of length N starts at
`ringOldest+(span-N)/2`, so every periodic window's centre is `windowEnd-span/2`. Neither end-aligned windows nor
fresh/stale band mixtures are used. A snapshot carries its serial, sample rate, centre/end sample indices, actual
lengths and hop. Times count consumed samples since this analyser was enabled, not DAW presentation time. An audio
break empties the analysis windows and temporal smoother; no result spans the break.

The synchronized hop is the largest of each band's `ceil(fs/updateCeiling)` and `ceil(N*(1-overlapCeiling))`.
The settings explicitly call these controls ceilings and report the effective cadence/delay. This first MVP
does **not** independently schedule each band and interpolate or predict it to a newer timestamp. Precision,
Balanced and Responsive tune preset sizes, rate ceilings and time smoothing. The five presets adapt sizes in
powers of two above 48 kHz, capped at 65536; settings show actual sample counts. Any advanced edit switches to
Custom, whose sample counts are literal and no longer automatically scale with rate.

A packed complex FFT transforms `L+iR` and separates its conjugate-symmetric spectra. Optional M/S is formed
from the complex coefficients, `M=(L+R)/2`, `S=(L-R)/2`, before powers; it preserves phase and cancellation.

## Per-zone read ranges (Build 117)

The fusion reads each zone only where its weight is nonzero: in Tone mode the mapped display bins, in PSD mode the
two interpolation bins, widened by the neighbours the peak estimator inspects (at most two on either side; the
analyser pads by four). At construction the analyser derives `first…last` for every zone from the weights, band
maps and display frequencies, and each transform separates the packed L/R (and M/S) spectra, applies the calibrated
scale and converts to dB only within that range, using vectorised multiply/threshold/`log10`. For the Standard
preset at 48 kHz this is 124 of 8193, 297 of 2049 and 398 of 513 bins. Bins outside the range stay at −200 dB and
are never read. The optional exhaustive mode (`MultiFFTAnalyzer.exhaustiveBins`) converts every bin as Builds
114–116 did; the core checks require both paths to produce the same fused curves. Window application uses two
contiguous vector multiplies over the ring (which wraps at most once inside a window), and the fusion/smoothing
scratch is allocated once per analyser. The scale factors, fusion weights, smoothing and timestamps are unchanged.

## Calibration and fusion

For a standard unnormalized DFT X of windowed samples, the one-sided tone amplitude-squared scale is
`4|X|²/(sum(w))²` for interior bins. A window-specific peak estimator corrects isolated-tone scalloping when the
peak lies inside a display interval. The separate one-sided PSD scale is `2|X|²/(fs*sum(w²))`; DC and Nyquist
are not doubled. The displayed PSD reference is full-scale sample amplitude squared per Hz: integrating the
unresampled PSD gives mean square, so a unit-peak sine has mean square 0.5. The log display itself is not a
band-power integrator. Tone mode is dBFS for sine peaks; its noise floor depends on ENBW. PSD mode is dBFS/Hz and
keeps stationary-noise density comparable between resolutions. These are intentionally distinct calibrations.

At frequency f, let `a(f)` be the low-pass half-cosine across the Low/Mid transition and `b(f)` the equivalent
across Mid/High. Each transition is linear in `log2(f/fc)`, centred on fc, with the user-selected full width in
octaves. The three weights are `a`, `(1-a)*b`, `(1-a)*(1-b)`: nonnegative, continuous, and summing to one even
if the transition ranges overlap. Calibrated **linear powers** are blended with these weights, then optionally
smoothed across frequency and time in power. Only the final values become dB. There is no hard frequency splice,
complex-phase interference between differently sized FFTs, or dB-domain averaging of PSDs.

The normalization follows the distinction documented in the primary references:
[SciPy periodogram](https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.periodogram.html) and
[AES tutorial on DFT scaling](https://appliedacousticschalmers.github.io/scaling-of-the-dft/AES2020_eBrief/).

## Existing displays and measurement accuracy

For local Classic Stereo/Mono displays, `configureLegacySTFT` supplies **one display-only Hann STFT** to both
Spectrum and Spectrogram. Choices are 2048, 4096 (default), 8192, and Legacy (Build 113). The original long FFT
continues to own dominant frequency/level, notes, stereo-band correlation/width/balance/level and spatial evidence.
Reducing display resolution therefore does not reduce measurement resolution. Shared mode avoids Classic
Spectrogram's additional resolution zones; it still retains the necessary original measurement FFT plus one
smaller shared display FFT. This is not a claim that every analysis in the app runs on a single 4096 FFT.

Switching display analysis refills only display FFT history; original measurements, loudness and held peaks
continue. Enhanced and Immersive use the original analysis. Bridge stays Legacy: no protocol/schema/snapshot
layout, producer callback, audio routing or plugin pass-through was changed. The inspector's current-window
resolution and centre delay follow the selected local display size. Historical columns from before a switch
are retained; their inspector metadata describes the current choice, not a per-column resolution history.

## UI and publication

The optional panel is hidden by a dedicated opt-in preference even for an upgrade with older hidden-panel data.
It appears in Panel Settings and the Panels menu, and participates in grid, enlarged, detached and Dock layouts.
It only analyses Stereo; Mono/Immersive and Bridge show an explicit unavailable state where a detached/Dock panel
remains present. Rendering polls an immutable snapshot at 30 Hz; the FFT cadence follows PCM, not drawing.
A short lock covers only snapshot exchange, never FFT computation or audio capture. A paused live panel retains
its frame; stalled live input clears the display after the larger of 250 ms or two configured hops without a new frame.

`--demo --multifft-test-tone` is an explicit QA-only source generating three stereo tones as PCM on a separate
queue and running the actual engine. It opens no input/output and never substitutes fabricated curve values.
Normal demo snapshots alone do not supply PCM to this panel.

## Follow-up stages

1. Implement versioned Bridge configuration/results transport, capability negotiation and old-plugin fallback.
   The present app cannot reconstruct Multi-FFT data from a plugin's old display curves.
2. Decide whether asynchronous per-band scheduling is worthwhile; if implemented, align timestamped histories
   before fusion and measure additional latency/CPU. Do not silently mix frames of different ages.
3. Validate live devices, system audio, long sessions, real DAWs, transport breaks, older macOS, Intel plugins
   and different display refresh rates. Synthetic numerical checks and host harnesses do not replace listening.
4. Consider a dedicated shared-STFT display class to avoid allocating unused spatial scratch in the current
   reusable `SpectrumAnalyzer`, and measure whole-app A/B resource use on the target hardware.
5. The remaining engine cost is dominated by the FFTs themselves; the display-point fusion (`pow`/`log10` per point)
   and snapshot publication are small. Per-band asynchronous scheduling remains the only route to a lower latency
   high band without changing the synchronized-frame guarantee.
