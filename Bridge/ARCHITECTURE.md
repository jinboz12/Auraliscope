# Auraliscope Bridge 1.3dev build 3: architecture note

Plugin-side analysis with result-only delivery. The DAW hosts the Bridge (VST3 or AUv2) on a track, bus or master;
**the Bridge analyses its own audio**; Auraliscope LABS shows the results. Labs still analyses physical inputs and
system audio itself, with the same code.

```
DAW audio thread ─► BridgeCore::process ─► capture ring (1 MB per insert, SPSC, preallocated)
                      (audio passes through untouched; no allocation, lock, syscall or analysis above this line)
                                                 │
analysis thread (one per plugin binary) ─► StreamAnalyzer = MeterPipeline (shared analysis core, Swift)
                                                 │  newest RESULT in a one-slot mailbox; ordered columns queued
sender thread (one per plugin binary) ─► Unix socket (protocol 3: HELLO, STATUS, RESULT, ACK) ◄─ SUBSCRIBE, COMMAND
                                                 │
Auraliscope LABS: receiver thread ─► ResultInbox (decode) ─► ResultAssembler ─► 60 Hz ResultWorker
                                                 ─► the same snapshot triple buffer ─► every canvas and readout, unchanged
```

## Revisions

| | Commit |
|---|---|
| Application baseline | Auraliscope 1.2.2 (build 62), `10e35cd`, the committed 1.2.2 release (merged into the prototype as `3b34185`) |
| Prototype baseline (audio streaming, protocol 2, Labs build 2) | `7f7e733`, branch `claude/auraliscope-daw-bridge-187076` (prototype first committed as `4d690bf` on `a004a5b`, Auraliscope 1.1) |
| This architecture (protocol 3, Labs build 3) | branch `claude/bridge-plugin-analysis`, from `7f7e733` |

The prototype branch is left as it was, so build 2 stays reproducible. Uncommitted work in the primary checkout is
neither used nor touched.

## Shared analysis core

| Target | What | Depends on |
|---|---|---|
| `Sources/AnalysisKernels` (C) | frame types and DSP kernels: true-peak scan, K-weighting, band filters, packed FFT powers | nothing |
| `Sources/AnalysisCore` (Swift) | `LoudnessAnalyzer`, `SpectrumAnalyzer`, `WaveformEnvelope`, `FormatDetector`, `MeterPipeline` and its snapshot layout (shared with the app; build 66 fixes true-peak startup priming), plus `StreamAnalyzer` (pushed audio, audio-clocked ticks, result encoding), `ResultProtocol` (RESULT fields) and `ResultAssembler` (results back into snapshots) | Foundation, Accelerate, AnalysisKernels; **no AppKit, SwiftUI, Core Audio or views** |

The app's `DSPWorker` runs `MeterPipeline` for devices and system audio, as before; the plugins run the same
`MeterPipeline` through `StreamAnalyzer`. There is one analyser, compiled into three binaries. `package` access keeps
it internal to the Swift package.

**Integration with the C++ plugins** (proved first, `probe-analysis-link.sh`): `build-analysis-lib.sh` compiles the
core with a narrow C interface (`Bridge/Plugin/Analysis/BridgeAnalysis.h`, `BridgeAnalysisABI.swift`) into a
universal static library per format, each under its **own Swift module name** (`AuraliscopeBridgeAnalysisVST3`,
`…AU`). Swift mangles type names with the module, so a host that loads both plugins has no duplicate classes (checked:
both loaded and run in one process, no Objective-C class clash). The Swift runtime is the system's (`/usr/lib/swift`,
ABI-stable since macOS 10.14.4; the plugins target macOS 11); nothing is bundled. Swift code runs only on the
analysis thread: never on a host's audio thread.

Equivalence: fed the same audio in irregular host blocks, `StreamAnalyzer` publishes the same snapshots as the
desktop pipeline fed one tick at a time: mono bit-identical; stereo identical except the L/R correlation sums, whose
different summation order differs in float rounding (≤ 2.2·10⁻¹⁰).

## Ownership

| Owned by the Bridge (shared by every display) | Owned by one display |
|---|---|
| The measurement: levels, true peak, loudness (M, S, I, LRA), spectrum, stereo image, the spectrogram and waveform series | Interpolation, damping and drawing |
| Its generation (reset), pause and resume, the true-peak hold | Frozen picture while that display is paused; its own scroll and zoom; display options |
| Break detection and accounting | Status wording, localisation |
| Identity (session, persistent ID, copies), name (saved in the project) | Which insert it shows, and restoring that choice |

**What Labs' controls do** (documented in the UI help and here, and unchanged in meaning from the release):

- **Pause Capture** on a Bridge source pauses **the Bridge's measurement** (COMMAND PAUSE) and holds Labs' picture.
  This is the release's pause: measurement stops accumulating and resumes without a break. Because the measurement
  is the Bridge's, the pause applies to every display of that insert; the plugin window shows it and can resume it.
  A pause lasts while the display that made it is connected: when Labs chooses another source it resumes the insert,
  and if Labs quits, crashes or loses the connection the plugin resumes by itself. A pause made in the plugin window
  lasts until it is resumed there or by a display.
- **Reset** sends RESET: the Bridge starts a new generation; every display sees a new stream.
- **Clicking TRUE PEAK** sends RESET_TRUE_PEAK. The published held peaks clear even when the analyser is paused
  or has finished its idle ticks; other snapshot fields and measurement time do not advance.
- **Display-only pause** (freezing one display while the Bridge measures on) is not a separate control in this
  milestone. It is what a second display would do; the protocol already separates it (a display can simply stop
  drawing without sending PAUSE).

Every command names its target session and, optionally, the generation it expects; the plugin acknowledges each one
with its outcome and the resulting generation and measurement state, and refuses (without acting) a command for
another instance or an obsolete generation.

## Real-time behaviour

`BridgeCore::process` (host audio thread) reads atomics, compares the host transport with the previous block, and when
the insert is live copies the block into the insert's capture ring (at most two `memcpy`s per chunk of ≤ 2048 frames).
No allocation, lock, system call, logging or analysis. The ring, the analysis scratch, the result mailbox and the
output buffer are allocated when the instance is created; the analyser (Swift) is created on the analysis thread when
the first audio of a format arrives. Measured worst `process()`: 34–45 µs per 256-frame block in the test host,
unchanged by a 3.5 s analysis stall or a 3 s receiver stall.

## Scheduling and bounds

One analysis thread per plugin binary (`BridgeAnalysisHub.cpp`), at the user-initiated QoS, below every real-time
audio thread: analysis load can delay only analysis.

- **Every 5 ms** it visits every instance, starting one further along each pass (no instance is always served last).
- **Per visit** an instance analyses at most **50 ms** of its queued audio: a large block, a high rate or a backlog
  cannot hold the others up.
- **Per pass** it stops after **8 ms** of work; the next pass continues from the instance it did not reach.
- **If the analysis falls behind** by more than an instance's ring (1 MB: 2.7 s at 48 kHz stereo, 0.68 s at 192 kHz)
  the audio thread drops the newest audio **from the analysis only** (never from the output), counts it
  ("unanalysed"), and the analysis marks a break with the time missing.

Ticks are clocked by the audio: every 1/60 s of audio (rounded per tick, exact on average) closes a tick and publishes
a snapshot. A host that renders ahead in bursts therefore produces bursts of results, each describing exactly its
audio. When the host stops calling the plugin, the analyser ticks on the clock for up to 9 ticks (meters fall to
silence), then rests.

Measured cost (`measure-resources.sh`, `Bridge/VALIDATION.md`): see the resource table in the validation report.

## Result delivery

Specified in [PROTOCOL.md](PROTOCOL.md). In short: while a display is subscribed, the analysis thread encodes the
newest state after every tick into a one-slot mailbox (a newer one replaces an unsent one); the sender thread moves it
to the socket when the connection has room (16 KB high-water mark, 32 KB socket buffers). Spectrogram and waveform
columns are serial-numbered per generation and kept in bounded queues (64 and 512 columns, about 2 s); each result
carries the columns after the last one sent to this subscriber. A subscriber more than about 2 s behind sees a gap,
and the count of skipped columns; nothing is ever sent twice or replayed into a later subscription.

In Labs, `ResultInbox` decodes on the receiver thread; `ResultWorker` publishes one snapshot per display tick from
`ResultAssembler`: the newest state; at most one spectrogram column per tick, skipping ahead when more than 8 wait (the
waterfall stays within about 0.27 s of real time); waveform columns into the 64-column window the waveform display
reads; a gap leaves blank columns (spectrogram) or a flat notch (waveform). After 0.3 s without results the
instantaneous readings fall to silence and the measured values stay.

## Lifecycle

| Event | Bridge measurement | Labs |
|---|---|---|
| Activation (first audio of a format) | a new generation starts | a new stream |
| Deactivate and reactivate, same format | carries on; one **restart** break | carries on |
| Sample-rate or channel change | a new generation (no result mixes formats) | rebuilds its display for the new rate |
| Plugin window opened or closed | nothing changes | — |
| Transport stop (host keeps processing) | measures the silence | streaming |
| Host stops calling the plugin (stop in some hosts, suspension) | idle ticks, then rest; a **host idle** break when audio returns (idle > block + 350 ms) | "no audio" |
| Seek, loop | nothing (a timeline jump is counted, not a break) | — |
| Bypass | not measured; a **bypass** break when live again | "bypassed" |
| Offline render / freeze | **not measured** (a bounce is not live audio); an **offline** break when live again | "offline render, not metered" |
| Analysis queue overflow | a **frames dropped** break with the time missing | "Interrupted N×" |
| Labs quits, crashes or disconnects | measures on | — |
| Labs reconnects | — | the first result is the current state (same generation); up to 2 s of waveform history arrives, the waterfall resumes from now |
| Labs away longer | — | the same: the measurement covers everything since the generation began |
| Reset (Labs or plugin window) | a new generation | a new stream |
| Plugin removed, DAW quits | gone | "disconnected, measurement held"; waits for the same insert |
| Project reopened | a new instance, a new measurement (live measurements are not saved in the project) | finds the saved insert (below) and shows its new measurement |
| Instance duplicated | the copy keeps an identity of its own and measures separately | never inherits the selection |

Integrated loudness and loudness range carry on across breaks and count only analysed audio; momentary, short-term,
filters, FFT and true-peak interpolation restart at a break. Each result carries the number of breaks and the audio
known missing, and Labs shows "Interrupted N× · x s missing", so a reading that spans breaks never passes for one
continuous measurement.

## Build 72 Enhanced and 3D spectrogram, panel settings

- `Sources/AnalysisCore/ReassignedSpectrogram.swift`: the Enhanced analysis, on the same 512 rows and 30 Hz columns as
  `SpectrogramAnalyzer`. Five Hann zones (the span down to span/16), each serving the rows where its main lobe stays
  within 1/16 of the frequency. Per frame, one complex DFT carries x·h and x·t·h of a role, another carries x·dh/dt of
  two roles; each bin's energy moves to t + Re(X_th X*/|X|²) and ω − Im(X_dh X*/|X|²), and is kept when it lands in the
  column's 1/30 s and the zone's slice of frequency, spread over one bin's width. Frames lie less than half a window
  apart (the squared Hann windows then sum to a constant) and reach half a window beyond the column, so a column is
  computed from the history alone, with Classic's delay. The longest zone has room for one frame only and moves energy
  in frequency only. Calibration: a stationary sine in dBFS; broadband power per row.
- Mode plumbing: `SpectrumAnalyzer.spectrogramMode` picks the analyser; `StreamAnalyzer` exposes it, the plugin core
  sets it from SUBSCRIBE field 2 (`abr_analyzer_set_spectrogram_mode`), RESULT tag 65 and `SnapshotSlots.spectrogramMode`
  carry what the columns are. In LABS, `MeterModel.canvasFrame` hands the choice to the local DSP worker and to the
  receiver (`abr_server_set_spectrogram`, which retunes the current subscription instead of renewing it).
- 3D: `SpectrogramScene` draws a floor grid and returns a `SurfaceState`; `surfaceVertex` builds a height field from the
  same history texture (vertex-ID driven, 128 depth strips × the visible columns, strips farthest first so nearer ridges
  cover farther ones), `surfaceFragment` colours it with the waterfall ramp, shading and distance haze, and leaves silence
  transparent. `SurfaceProjection` holds the projection shared by Swift (grid, labels) and Metal.
- Live spectrum: `SpectrumSmoothing` (Gaussian in octaves, in power) on curve, holds and average; holds as one line.
- Panel settings: `PanelSettingsButton` in each header opens a popover of `@AppStorage` controls; `MeterModel` follows
  the stored values as before. `SettingsDraft` keeps only app-wide settings.

## Build 71 spectrogram and spectrum display

The analysis is unchanged from build 69/70 except for one addition: the fine spectrum bands.

- **Fine spectrum.** `SpectrumAnalyzer` maps the same power spectrum it reads for the 64 display bands onto 128
  (`MeterSnapshot.fineBandCount`, each of the 64 halved, about 1/13 octave) with the same band reading (loudest bin
  with Hann peak correction, or the interpolated peak for bands narrower than 1.5 bins); plugin CPU in VALIDATION.md.
  They travel as snapshot slots (`SnapshotSlots.spectrumFine`, appended after `missing`) and as RESULT tag 51; the
  assembler shows a result without them (a build 70 plugin) as each of its 64 bands across its two halves.
  The live curve, peak holds, average and spectrum hover read them. They are deliberately not read from the
  waterfall's multi-resolution column: its short treble windows read broadband sound about 3 dB higher per halving
  of the window, which would bend a pink-noise average flat above ~1.5 kHz and mislead tonal-balance reading.
- **Curve ballistics.** `SpectrumScene` follows the fine bands with its own critically damped filter at
  `SpectrumResponse.rate` (22, 10 or 4 per second; build 70 used 22 through `DampedDisplayState`). Paused, it holds.
- **Colour maps.** `SpectrogramColors` (Heat, Theme, Gray) → `Theme.rampStops(_:)`; the waterfall shader reads 33
  evenly spaced colours (every 1/32: each stop of Heat exactly) from a fragment buffer beside its state
  (`CanvasScene.underlayRamp`), so a change recolours without rebuilding the pipelines; Swift callers (spectrum fill,
  header scale, exported image) read a 1024-entry table per map, cleared when the theme changes.
- **Cell reconstruction.** `waterfallAxis` eases between neighbouring cells with a smoothstep across
  `SpectrogramTone.columnSoftness`/`rowSoftness` of a cell (both 1: centre to centre), never narrower than one device
  pixel; a cell's centre keeps its exact level. Minified pixels still take the loudest of every covered cell.
  `Bridge/Tools/CheckSpectrogramRendering.swift` checks both against CPU references.

## Build 69 spectrogram clarity

Build 68's design stands (multi-resolution, time-aligned, calibrated rows, float history); build 69 removes the
causes of blur that measurement found in it.

- **Window.** `SpectralWindow` describes cosine-sum windows (samples, kernel) and `PeakEstimator` derives the exact
  tone estimator for any of them (Grandke's for Hann). Rows use the minimum 4-term Blackman–Harris window (sidelobes
  ≤ −92 dB) at the shortest length whose main-lobe half-width (4 bins) stays within 1/32 of the row frequency
  (`resolvingPower`, about ±½ semitone): N ≥ 128 · rate / f. Below the frequency where even the span's
  Blackman–Harris window cannot meet that (750 Hz at 48 kHz), rows read the span's Hann transform (main lobe 2 bins),
  as in build 68. At 48 kHz: Hann 8192 to 750 Hz, Blackman–Harris 8192 to 1.5 kHz, 4096, 2048, 1024, and 512 from
  12 kHz.
- **History.** `SpectrumAnalyzer.historyLength` is 8192 at 44.1/48 kHz and doubles per doubling of the rate (16384
  at 88.2/96, 32768 at 176.4/192, capped at 8×), and it is also the spectrum's transform length (RESULT tag 80
  reports it), so the spectrum, peak readout, notes and stereo bands have 5.9 Hz bins at every rate. The
  spectrogram's span is the same ring, so its zones are the same in Hz at every rate and every column is centred
  ~85 ms (half the span) before the newest sample. The span's Hann zone reuses the spectrum's transform; when the
  roles differ (a Spatial role fell silent within the window), the span's Hann and Blackman–Harris zones share one
  unwindowed FFT and are windowed in the frequency domain (3- and 7-tap circular convolutions, exact).
- **Coverage.** `Zone.frames` picks the fewest frames per column for which the frame lattice (repeated column to
  column) weighs every instant within 1 dB: at 48 kHz 1/1/2/3/6/12 frames for the six zones.
- **Display.** `waterfallFragment` draws each cell (column × row) flat over its box. Where a cell is larger than a
  pixel it meets its neighbour in a ramp of one pixel or 0.3 cell (`SpectrogramLayout.cellEdge`), blended as tone;
  where a pixel covers several cells, it shows the loudest (up to 6 × 6 reads). `SpectrogramHistory.level` and the
  inspector read the same cell; the inspector adds the column's true time (+ half the span), the row's centre
  frequency, the analysis behind the row, and the 2nd–8th harmonics of the frequency under the pointer.
- **Cost.** One column: 78 µs at 48 kHz (build 68: 44), 140 µs at 96 kHz (67), 257 µs at 192 kHz (81); one
  spectrum transform (60 per second): 19 µs at 48 kHz, 41 µs at 96, 152 µs at 192 (P-core micro-benchmark).
  Plugin CPU in VALIDATION.md.

## Build 68 spectrogram

The spectrogram is the project's own end to end; nothing of the earlier presentation (and no third-party credit)
remains.

- **Analysis** (`AnalysisCore/SpectrogramAnalyzer.swift`, so the plugins compute the same columns as Labs). It reads
  the spectrum's 8192-sample history rings at 30 columns per second. Each of the 512 log rows uses the shortest Hann
  window whose bins keep `frequency / binWidth ≥ 64` (main lobe within about ±½ semitone): 8192 points below about
  750 Hz at 48 kHz, then 4096, 2048, 1024 and 512 points, zones blended over half an octave above each boundary. All
  windows are centred on the middle of the 8192-sample span, so a column is one instant at every frequency; windows
  shorter than twice the 1/30 s hop are repeated across it at 50 % overlap and their powers averaged (Welch). The
  8192-point zone reuses the spectrum's own transform of the same window. Rows read the loudest level in their slice
  of frequency, corrected for Hann scalloping with Grandke's estimator (`SpectrumAnalyzer.hannPeak`), within 0.05 dB
  for a sine in every zone.
- **Wire.** Unchanged: 512 dBFS rows per column (PROTOCOL.md tags 60–64).
- **Display.** `SpectrogramHistory` keeps 512 columns (17 s) of float dBFS; `SpectrogramScene` uploads one column per
  serial to an r32Float texture, and `waterfallFragment` interpolates between columns and rows, takes the loudest row
  under a pixel that covers several, applies the tilt, and maps level to colour through `SpectrogramTone` (shared with
  the spectrum's fill and the header legend). The inspector samples the same history with the same interpolation.
- **Cost.** The DSP benchmark (100 s, 48 kHz): 0.61 → 0.77 % of one core with a stereo spectrum, 1.23 → 1.90 % with a
  16-channel Spatial spectrum (all channels sounding).

## Build 67 DSP implementation

For one or two weighted channels, the K-weighting kernel uses a two-double vector with the same coefficients,
recurrence and accumulation order. More channels retain the groups-of-eight kernel. Stereo-band output stores use
constant SIMD lane indices; all cascades continue to advance as before. Neither change moves work onto the host's
audio callback, reduces result cadence, or disables analysis while LABS is absent.

## Insert identity and restoration (unchanged from build 2)

Each insert has a session ID (this instance's life) and a persistent ID (saved with the project). A process-wide
registry flags a copy (duplicated track, pasted settings) and gives it an identity of its own. Labs saves the chosen
insert with its context and restores it only when it is certain: the same live session; otherwise the only holder of
the saved identity with no unknown copy connected; otherwise the saved context (host channel ID, or format, host, and
names) singling one out; **otherwise it is ambiguous**, nothing is shown, and the person chooses. Rules and tests:
`BridgeRestoration.swift`, `AnalysisBreakTests.swift`. Two DAWs (or processes) holding the same project cannot see each
other's copies; Labs tells them apart by context or says the choice is ambiguous.

## Towards iOS

The boundary is already the one an iOS app needs: results, not audio. `AnalysisCore` has no macOS-only dependency
(Foundation, Accelerate), so an iOS app can compile `ResultProtocol` and `ResultAssembler` (and the snapshot
layout its displays would read) unchanged; the RESULT format is carrier-independent. Not implemented: a network
carrier (framing unchanged; it needs discovery, which exists as a preview; pairing; encryption and authentication; and
probably compressed columns: a RESULT is about 7 KB, 60 per second, ≈ 430 KB/s per insert uncompressed, which a LAN
carries but a quantised form would cut by 3–4×). Multiple displays: the plugin sends to one subscriber per
connection today; a relay or several connections would each get their own subscription and column cursor, with the
shared measurement and its commands as specified.

## Production transport

Unchanged from build 2's recommendation: the sandboxed release cannot use this socket; carry the same protocol over
Mach messages under an application-group prefix, to be verified with a team signature
(`probe-sandbox-transport.sh`). Results are smaller and less frequent than audio was, which makes that carrier easier.
