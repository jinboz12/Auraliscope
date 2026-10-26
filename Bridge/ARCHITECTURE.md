# Auraliscope Bridge 1.3dev build 3: architecture note

Plugin-side analysis with result-only delivery. The DAW hosts the Bridge (VST3 or AUv2) on a track, bus or master;
**the Bridge analyses its own audio**; Auraliscope LABS shows the results. Labs still analyses physical inputs and
system audio itself, with the same code.

```
DAW audio thread ─► BridgeCore::process ─► capture ring (1 MB per 2 channels per insert, SPSC, preallocated)
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
| `Sources/AnalysisCore` (Swift) | `LogFrequencyAxis` (the frequency axis every analysis and display shares), `LoudnessAnalyzer`, `SpectrumAnalyzer`, `WaveformEnvelope`, `FormatDetector`, `MeterPipeline` and its snapshot layout (shared with the app; build 66 fixes true-peak startup priming), plus `StreamAnalyzer` (pushed audio, audio-clocked ticks, result encoding), `ResultProtocol` (RESULT fields) and `ResultAssembler` (results back into snapshots) | Foundation, Accelerate, AnalysisKernels; **no AppKit, SwiftUI, Core Audio or views** |

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
- **If the analysis falls behind** by more than an instance's ring (1 MB per two channels, rounded up to a power of
  two: 2.7 s at 48 kHz stereo, 0.68 s at 192 kHz; 8 MB for a 7.1.4 or 9.1.6 bus, 3.6 s and 2.7 s at 48 kHz) the audio
  thread drops the newest audio **from the analysis only** (never from the output), counts it ("unanalysed"), and the
  analysis marks a break with the time missing.

Ticks are clocked by the audio: every 1/60 s of audio (rounded per tick, exact on average) closes a tick and publishes
a snapshot. A host that renders ahead in bursts therefore produces bursts of results, each describing exactly its
audio. When the host stops calling the plugin, the analyser ticks on the clock for up to 9 ticks (meters fall to
silence), then rests.

Measured cost: run `scripts/measure-resources.sh`.

## Result delivery

Specified in [PROTOCOL.md](PROTOCOL.md). In short: while a display is subscribed, the analysis thread encodes the
newest state after every tick into a one-slot mailbox (a newer one replaces an unsent one); the sender thread moves it
to the socket when the connection has room (16 KB high-water mark, 32 KB socket buffers). Spectrogram and waveform
columns are serial-numbered per generation and kept in bounded queues (64 and 512 columns, about 2 s); each result
carries the columns after the last one sent to this subscriber. A subscriber more than about 2 s behind sees a gap,
and the count of skipped columns; nothing is ever sent twice or replayed into a later subscription. The spatial
observations (RESULT 58, about 30 new frames a second against 60 results) go the same way to a display that keeps
them (WELCOME capability 1, after build 98): the mailbox records the frame its result leaves the display holding, only
a result actually sent counts, so each frame is sent once and a replaced, unsent result's frame goes with the next; a
display that does not announce it (build 98) gets them in every result. An unconfigured plugin makes no observations at
all (it places tag 54's bins instead), so nothing is computed that no display receives.

In Labs, `ResultInbox` decodes on the receiver thread; `ResultWorker` publishes one snapshot per display tick from
`ResultAssembler`: the newest state; the newest observations any result carried (taken from every result, decoded once,
kept until a result carries new ones); at most one spectrogram column per tick, skipping ahead when more than 8 wait (the
waterfall stays within about 0.27 s of real time); waveform columns into the 64-column window the waveform display
reads; a gap leaves blank columns (spectrogram) or a flat notch (waveform). After 0.3 s without results the
instantaneous readings fall to silence and the measured values stay.

## Lifecycle

| Event | Bridge measurement | Labs |
|---|---|---|
| Activation (first audio of a format) | a new generation starts | a new stream |
| Deactivate and reactivate, same format | carries on; one **restart** break | carries on |
| Sample-rate or channel-layout change | a new generation (no result mixes formats) | rebuilds its display for the new rate and layout |
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

## Build 98 SoundStage V2: one exact reduction, the display's speaker geometry

- **Geometry.** `SpatialGeometry` (AnalysisCore): each role's azimuth, elevation, optional distance and inclusion, the
  mapping (speaker directions, or positions in meters), the detail (Particles) and the spatial window; values rounded
  to `Float` when made; an FNV-1a content hash (never 0). The display makes it from the user's layout
  (`SpeakerLayoutStore`; file and settings in docs/SPEAKER_LAYOUT_FORMAT.md); its revision mixes the store's change
  count with the hash, so every different geometry carries its own.
- **Analysis.** `SpatialFieldAnalyzer` places every bin of a band at Σ|X_i| s_i / Σ|X_i| (s_i the unit direction or the
  position in meters; the LFE and excluded speakers take no part) and reduces the transform once with
  `SpatialObservationBuilder`: exact same-place runs, every component of at least E_band / budget kept, the rest merged
  on a grid from 1/100 of the layout's extent, doubling; a water-filling budget of detail × 96 (at most 3072, 96 a
  band). Each band's energy, centre of gravity and second moment are kept; runs below 10⁻¹⁴ of the strongest dropped
  run are left out with their energy recorded. Multi-resolution window: bands centred from 1 kHz on a quarter, from
  4 kHz on an eighth of the transform, each window ending at the newest sample; the coherence field stays on the full
  transform. Timestamps are window ends in frames. Published in `SnapshotSlots.spatialObservations`
  (METER_SNAPSHOT_FLOATS 49441); silent partners of a pair are zeroed so float leakage cannot pull a lone speaker's sound.
- **Bridge.** HELLO capability 16; SPATIAL_CONFIG (display → plugin, at most 1000 bytes, only to a capable plugin)
  applied on the analysis thread and answered by SPATIAL_ACK; RESULT 58 carries the observations with the geometry's
  hash; tag 54 only while no configuration is in force; the standard geometry again on disconnection; mailbox 256 KB,
  output buffer 512 KB. The server sends the configuration again whenever its bytes change (a change counter), not only
  on a new revision.
- **Display.** `NebulaScene.accepts`: observations are drawn only with the hash of the geometry the speakers are drawn
  with (or tag 54's bins with the standard geometry); a geometry change clears the particles behind a crossfade;
  particles are born on the audio's clock (window end) and a frame shown twice is added once. `RadiantParticles`: one
  particle per observation, where it is (no clamping: below the ear plane, in meters), its light the band's times its
  share of the band's energy (Σ = 1, any number of particles); `Radiant.exposure` 3.4 · √20 keeps the default picture's
  light near build 97's (whose particles each carried 1/√N); every particle at the particle size (drawn as wide as its
  spread, diffuse treble became one broad splat). Raw observations draws the newest frame bare. The level body's grid
  covers the full sphere when a speaker sits below the ear plane.
- **UI.** The Speaker Layout window (a utility window that never reopens on its own at launch); Soundstage settings:
  Speaker layout, Spatial window (Standard | Fast), Raw observations, and notes for a plugin that is older or refused
  the layout.

## Build 88 display lifecycle and transitions

- Analysis and RESULT layouts unchanged. `NebulaScene` uses analysis-column serial changes as well as content changes
  for particle emission, while content equality still caches the level grid. Stream/layout/epoch changes clear history;
  band changes replay retained measurements. Measured empty bands do not use the statistical fallback.
- `SpatialBody.evaluate(metadataOnly: true)` provides Radiant's layer count/LFE without its unused direction grid.
  Returning to Level body invalidates the cache and fully evaluates the field. The default evaluation path is unchanged.
- `RadiantParticles` pools exact equal bin positions within each band before systematic sampling, preserves energy,
  prunes hover data with expired frames, and batches adjacent live ring ranges in `encode` without changing draw order.
- A style or Radiant-band switch captures the last composite into a temporary BGRA texture. A `PresenceSpring` driven
  by display time crossfades it with the incoming image. Interrupted switches capture the current blend. Stream resets,
  viewport changes and completion release stale transition state. `--test-nebula-gpu` checks the real shader path in
  addition to the CPU lifecycle checks. No new persistent settings or UI strings.

## Build 87 Radiant from the analysis' own bins

- **Analysis.** `SpatialFieldAnalyzer.analyse` also places the newest Spatial transform's bins (`placePoints`, per band,
  from the same captured spectra as the field, every second transform, 30 per second): each bin's energy over the
  full-range speakers, Σ_i w|X_i|² in mean-square units (w the partial edge weight), and its position Σ|X_i|u_i / Σ|X_i|
  (u_i the slot's direction; the LFE takes no part). A band with at most `SpatialPoints.perBand` (32) bins keeps every
  one with energy; a wider band is resampled systematically in proportion to energy (one offset hashed from a field
  counter and the band), a bin drawn k times kept once with k shares, so the points add up to the band's energy. Layout
  `SpatialPoints` (status, then per band a count and 32 × (x, y, z, energy)); published after the field in the snapshot
  (`SnapshotSlots.spatialPoints`; METER_SNAPSHOT_FLOATS 21636) and in RESULT tag 54 (`SpatialPointsWire`: 7 bytes a
  point, i16 positions, tag 53's 0.5 dB energy code; points below −127 dB left out). The plugin's mailbox is 192 KB
  (was 128 KB). Cost: 2.83 % of one core for 7.1.4 (the whole pipeline; 2.69 % in build 86).
- **Display.** `RadiantParticles` takes the bins (`Input.points`) whenever the snapshot has them; otherwise (a plugin
  before build 87, the demo signal) it draws from the field's statistics as in build 86. Per band, `perBand` draws by
  systematic resampling over the bins' energies, each an equal share of the band's light (brightness / √draws); draws on
  one bin are one particle with their light added (exact, the passes are additive). Instability (the ochre tint) is the
  band's coherent energy that cancels, Σ e_c(1 − stability_c) / total; the hover reading names a speaker the particle
  sits on (within 0.02), else the band's strongest coherent image while most of the band is coherent.
- `NebulaScene` keeps the frames heard (`Heard`: birth, serial, field, bins, band power) within the persistence time; a
  change to how particles are drawn remakes them from those frames (with their own serials, so nothing else moves); a
  reset (new stream, layout or band choice) starts afresh from the newest frame; frozen with nothing heard, the newest
  frame is repeated as before. The cached bins join
  the field and band power in the "new audio" test.
- Settings: Spatial spread is shown for the level body only; Coherence sensitivity and the Radiant caption describe the
  new placement; a caption names a Bridge source that sends a field without bins (`MeterModel.lastSpatialPointsStatus`).

## Build 86 Radiant sparks, diffusing haze, two-level glow and exposure meter

- **Display only**; analysis, wire, plugins, `RadiantParticles` (where particles sit) and the level body as in build 85.
  New setting `soundstage.nebula.sparkle` (0–2, default 1); `soundstage.nebula.particles` defaults to 20 (was 12).
- Two passes over the same instanced particles (`radiantParticleVertex`, `RadiantCamera` now 96 bytes: `pass`,
  `sparkSize`, `sparkFade`, `sparkGain` added). Haze (`pass` 0, half-resolution rgba16Float target as before):
  σ² = σ₀² + (blur × scale)² × age, as repeated blurring grows it (σ₀ = 0.008 radii × Particle size, blur = 0.045 radii
  per √s × Blur), peak dimmed by σ₀²/σ² so the light only spreads, fade e^(−age/(persistence/3)). Sparks (`pass` 1,
  a full-resolution rgba16Float target cleared every draw): σ = 0.0035 radii × Particle size (at least 0.6 px), peak =
  light × 2.5 × Sparkle × e^(−age/0.05 s), drawn only for the newest frames (age ≤ 4 × 0.05 s; none at Sparkle 0, the
  pass still clears). Both skip particles whose light is below 5·10⁻⁴.
- Glow: the haze averaged to a quarter and blurred twice each way (near), that averaged to half again and blurred the
  same way (wide). `radiantMeterKernel` (one threadgroup of 256) takes the wide glow's brightest point (its 4-norm) and
  holds it in a two-float shared buffer: risen at once, fallen back with a 0.8 s time constant of the scene's clock,
  zeroed on a reset; it runs in the same command buffer as the picture, so a render is deterministic.
- `radiantCompositeFragment` (`RadiantLook`, 32 bytes: sparkle, glowNear, glowFar, chroma, hotFrom, hotTo, limit,
  ease; the meter at fragment buffer 2): haze + glow (near 1, wide 1, × 0.7) + sparks; chroma ×1.35; gain = opacity ×
  3.4 × presence(loudest band), eased by (2 / (meter × gain))^0.7 when meter × gain > 2. Dark: x = 4-norm(light) ×
  gain, colour = mix(light / 4-norm, white, smoothstep(3, 16, x)²) × (1 − e^(−x)), straight alpha (the 4-norm, a
  smooth stand-in for the largest channel, leaves no crease or seam where hues cross). Light: a wash c / 4-norm × 0.78
  with alpha 1 − e^(−0.8 × 4-norm × gain), at most 0.94.

## Build 85 Radiant particles

- **Display only**; analysis, wire, plugins and `SpatialBody` (still built for the level body and the LFE) as before.
  The style is a visible setting again (`soundstage.nebula.style`, first row of the panel's nebula settings).
- `RadiantParticles` makes each frame's particles on the CPU when a new field arrives (30 Hz): per field band (or, for
  a source without a field, per analysis band from `roleBandPower`), `particles` draws of the band's parts, each part
  (a speaker's independent energy at its unit direction; a coherent component at its `SpatialField.image` position,
  scattered over its covariance × `spread` × instability when out of phase) weighted by |CN(0, E)| (√(E × an
  exponential draw)); the particle sits at the amplitude-weighted centre. Draws are hashed from (frame serial, band,
  particle), so a frozen picture holds. Light = intensity of the band's place in the glow range below the loudest band
  (raised at once, released over 2.5 s) × (draw energy / band energy)^γ / √particles, γ matching intensity's
  compression. Particles go into a shared ring buffer (320k × 48 bytes) with per-frame ranges and births on the scene's
  clock (seconds of signal, still while frozen); frames older than the persistence are forgotten. After a reset, a
  style change or a change while frozen, the frozen field's steady picture is made at once (the persistence's worth of
  frames, 1/30 s apart).
- `radiantParticleVertex` (instanced, one quad per particle, the dome's orthographic camera from `RadiantCamera`):
  σ = (size + blur × age) × scale, peak dimmed by (σ₀/σ)² so the light only spreads, fade e^(−age/(persistence/3)),
  far side dimmed 25%, ochre by instability; skipped once its light is below 5·10⁻⁴. Added (one, one) into the
  half-resolution rgba16Float target; then a bloom (four-tap average to a quarter, two 9-tap Gaussian passes each way)
  and `radiantCompositeFragment`: chroma ×1.35, tone-mapped 1 − e^(−light × gain) per channel on dark, a wash toward ink
  on light, straight alpha. `gain` = opacity × exposure × presence(loudest band).
- The pointer reads `RadiantParticles.recent` (the newest frames' particles with their band, level and the part that
  pulls them most): the brightest within 10 pt as it shows now.
- Build 84's shell ray-march (`radiantFragment`), its bearing line and Radiant smoothing are gone; the retired key is
  cleared with the defaults.

## Build 84 Radiant style (replaced by particles in build 85)

- **Display only**; analysis, wire, plugins and `SpatialBody` as in build 83. `NebulaSettings.style` (`NebulaStyle`,
  `soundstage.nebula.style`: `radiant` default, `level` = build 83's body) picks the shader; both read the same
  textures, so a style change only redraws (`NebulaScene.recolored`). The style row in the panel settings shows only
  when the popover opens with Option held or while the level body is on.
- `radiantFragment` reads each direction's value on the floor…0 dBFS scale as a place x in the glow range below the
  loudest direction (`BodyUniforms.peak`, `.range`; the uniforms grew to 88 bytes): brightness e^(4x), glow thickness
  σ = 0.035 + 0.06·(1 + x) radii, on a shell at `Radiant.shell` (0.82 of the speakers' radius), sunk toward the
  listener by up to 30% where the share out of phase is high. The whole glow's gain follows the loudest level
  (`Radiant.presence`). `NebulaScene` follows that level quickly up (80 ms) and slowly down (2.5 s). An orthographic
  ray has ρ² = r² + t², so only the two spans crossing the shell band [0.3, 1.1] are marched (step 0.02); under the
  floor the horizon's value is continued (mirrored, clamped to 2·horizon − mirror) down to −25°. Coloured by
  frequency, each band is its own cloud (its own x and thickness) scaled so the clouds sum to the direction's
  brightness; light gets a 1.45 chroma lift before the 1 − e^(−x) tone map. Directions below the range are skipped
  and the band clouds are sampled only within 3.2σ of the shell; the halo beyond keeps the hue last seen on the ray.
  Radiant is drawn at a third of the canvas' resolution (the level body at half).
- Radiant has its own smoothing (`radiantSmoothing`, default 12°; `NebulaSettings.displaySmoothing` feeds
  `SpatialBody.Settings`) and no floor rings (`NebulaSettings.rings` is empty). The footprint becomes a bearing: per
  azimuth the loudest height's value (`footprint`), at the glow's sunk radius (`footprintRadius`), turned ochre as
  the glow is (`footprintOchre`). The pointer marches the shell as the shader does (`radiantProbe`) and reads the first
  direction that glows visibly. `Radiant` (NebulaSettings.swift) holds the constants Swift and Metal share.

## Build 83 glowing, frequency-coloured body; camera and rendering

- **Display only**; analysis, wire and plugins as in build 80–82. `SpatialBody` also accumulates, per layer and
  direction, the energy of each of the five analysis bands (`bands`, five planes): every lobe carries its energy per
  band (speakers from their independent band energies, merged images from their member bands) and adds it with its
  kernel, so the planes sum to `energy`. Lobes also carry their spectral hue and centre frequency for the pointer.
- `NebulaScene` keeps every per-direction plane in one allocation and eases eight directions at a time with SIMD
  (`simd_max`/`simd_clamp`; the standard library's generic SIMD functions run lane by lane). Targets arrive at the
  analysis rate and are glided straight from one to the next at the display rate; a layer at rest is neither eased nor
  uploaded. For the full band with Frequency colours it eases each band's radius on the body's dBFS scale and uploads
  them as two rgba16Unorm slices per layer (bands 0–3; band 4 and the largest). A band change draws the new choice into a
  second texture set and cross-fades the old body out (0.55 s, `PresenceSpring`).
- `bodyFragment` is an emissive volume (no lit skin): per sample, emission ∝ hue × loudness × (core weighting), light
  accumulated per channel and tone-mapped 1 − e^(−x) on dark (so dense, loud parts saturate toward white), an ink-like
  wash on light. Coloured by frequency, a point's hue is the mix of the band hues whose radius reaches at least that far
  in its direction (relative to the largest band), weighted by how far they reach. A static 32³ value-noise texture
  (model space) modulates density as grain. The body is marched at half resolution into an rgba16Float texture
  (`encodeOffscreen`, a pass before the canvas pass, hook `CanvasScene.encodeOffscreen`) and laid in by
  `bodyCompositeFragment` at the overlay point; the texture is reused while its inputs (camera, opacity, colours,
  uploads) are unchanged.
- The dome's camera lives in `DomeCamera` (main actor): settings plus a pose whose turn stays continuous. Only
  `DomeLabelsHost` observes it (the labels are one SwiftUI `Canvas`, `Animatable` over the pose), the canvas reads it
  every frame (`MeterModel.canvasFrame`), and the defaults are written when an interaction ends. Discrete changes glide
  (SwiftUI spring 0.45 s for the labels, `DomePoseSpring` with the same response for Metal); direct manipulation snaps.

## Build 81 spatial body

- **Display only**; analysis, wire and plugins as in build 80. `SpatialBody` (`Sources/Auraliscope/SpatialBody.swift`)
  turns each frame's field into a level per direction, per layer (the full band, or each band of a 3 or 5 split), on a
  120 × 31 grid (3° steps): every independent energy and every coherent image is a lobe (von Mises–Fisher-like kernel,
  anisotropic along the image's principal axes, peak 1, widened by the panel's Smoothing), lobes add as energies;
  images recurring across bands in one grid direction and phase are merged by moments, then evaluated with Accelerate
  over the rows they reach. Speakers use kernels cached per layout and smoothing.
- `NebulaScene` eases each direction in dB (attack, release, afterglow), maps it to a radius on the fixed dBFS scale
  (Level floor … 0 dBFS) and uploads one rgba16Unorm slice per layer (radius, out-of-phase share × weight, weight, so the
  share interpolates without fringes). `bodyFragment` ray-marches the hemisphere (build 79's volume: haze, lit skin,
  depth shade) with the skin's normal from the radius' slope and an ochre tint where energy is out of phase. It is the
  room's overlay, drawn first in the canvas pass (`ShapeBuilder.overlayStart` before the grid); the canvas' offscreen
  hook is gone with the splats. The pointer's reading marches the same ray on the CPU and names the strongest lobe.

## Build 80 spatial nebula

- **Analysis** (`Sources/AnalysisCore/SpatialField.swift`: `SpatialFieldAnalyzer`, owned by `SpectrumAnalyzer` on the
  analysis thread). While the Spatial spectrum sums every routed channel, each transform pair's two complex spectra are
  separated from the packed FFT and kept per bin. Every second transform (30 per second) the analyzer builds each band's
  cross-spectral matrix (`cblas_cherk`, at most 40 inner bins for the cross terms, exact band energies), smooths it (an
  exponential average started from zero, Σw/Σw² tracked) and splits the band: chance-corrected coherence, soft shares
  above the threshold, maximal cliques (Bron–Kerbosch), then per speaker an independent part and up to three coherent
  components, each placed and sized by `SpatialField.image` (velocity and energy vectors, Frank's width model, the
  out-of-phase haze) and kept in its slot by least movement. Allocation-free after creation; nothing on the audio thread.
- **Wire**: snapshot slots `SnapshotSlots.spatialField`; RESULT tag 53 (`SpatialFieldWire`: one byte per energy,
  20-byte components); SUBSCRIBE option 4 carries the coherence threshold (‰) to the plugin (`abr_server_set_coherence`
  → `BridgeCore::spatialCoherence_` → `abr_analyzer_set_spatial_coherence`). A plugin before build 80 sends none, and
  the display falls back to tag 49's five band energies per channel.
- **Display**: `DomeScene` (grid, markers, labels, keys, probe) and `NebulaScene`: per slot attack, release and
  afterglow in dB, eased image shapes; brightness per place from its total level; one 64-byte splat per component
  (position, σ along principal axes with a quaternion from `Symmetric3.decomposed`, colour, intensity, opacity).
  `splatVertex` projects Σ exactly for the orthographic camera, `splatFragment` adds into a half-resolution rgba16Float
  target, bloom at ¼ and ⅛, and `nebulaComposite` tone-maps by the strongest channel inside the canvas pass.
  `CanvasRenderer` encodes the offscreen passes before the canvas pass and splits it for the overlay (markers, listener)
  in front of the cloud.

## Build 77 immersive VST3 buses

The VST3 measures immersive beds as well as mono and stereo; the AU stays mono and stereo.

- **Arrangements** (`BridgeVST3.cpp`, `layoutFor`): `setBusArrangements` takes any arrangement whose speakers all have an
  Auraliscope role (PROTOCOL.md, *Speaker roles*), the same on input and output: 3.0 to 9.1.6 with or without LFE (5.1,
  7.1, 5.1.2, 5.1.4, 7.1.2 top side or top front, 7.1.4, 7.1.6, Dolby 9.1.4 and 9.1.6 with wides, 4.0.4, 6.0…). Offered a
  measurable input with another output, it takes the input's arrangement on both sides and declines (the host reads
  that back). Arrangements with speakers that have no role (Lc Rc, Cs, Tc, Lfe2, bottom, Ambisonics) are declined, so the
  host keeps the plugin on one it measures fully. `setActive` hands the layout (channels, roles, name) to the core.
- **Core** (`ChannelLayout`): a new layout is a new format epoch. The audio thread carries the epoch's packed roles
  (4 bits per channel) in every capture record, so the analysis never pairs audio with another layout's roles. The
  capture ring grows with the channel count in `configure` (the host is not processing then, and `withAnalysisHeld`
  keeps the analysis thread between passes while the ring is replaced; STATUS reads its fill level under the config
  lock); a host that changes a stereo insert to 7.1.4 mid-session gets the larger ring with the new epoch. The audio
  thread does what it did for stereo: atomics and copies, no allocation.
- **Analysis**: `StreamAnalyzer(sampleRate:roles:…)` runs `MeterPipeline` with the bus's roles, exactly as the desktop
  runs a device routed to those roles (checked value for value): BS.1770-5 weights by role, true peak, waveform and
  band energy per channel; its format detector starts Immersive for a bus with positional channels and leaves it after
  2.5 s of front-only programme, as the desktop's does. The spectrum and waterfall sum L and R, or every channel while
  the display shows Immersive (SUBSCRIBE option 3, `abr_analyzer_set_spectrum_channels`), which also gives every
  channel's band energy for the immersive soundstage.
- **Wire**: STATUS carries the roles and the layout's name (tags 21, 22); RESULT carries the roles (18) and what the
  spectrum sums (52), per-channel arrays for up to 16 channels. A 16-channel RESULT is about 9 KB at 60 per second.
- **Labs**: the receiver keeps each source's roles and name; `ResultAssembler` puts each channel on its role and passes
  the plugin's Stereo/Immersive reading to Auto. While an immersive insert is the source, `MeterModel.shownLayout` is
  the smallest Immersive format holding its speakers (a 7.0.4 bus draws in 7.1.4 with LFE off, named 7.0.4), its routing
  is the bus's (each channel to its own speaker, locked in Settings ▸ Channels), and the Meter menu's format is
  disabled; the format chosen in Settings returns with any other source.
- **Testing a build next to an installed Bridge**: hosts resolve a VST3 by its class ID, so REAPER (which also scans
  the system's VST3 folders) would load an installed Bridge instead of the one under test. `build-dev-vst3.sh` builds
  "Auraliscope Bridge Dev.vst3" (class ID, name, Swift module and window class of its own) into `.build/bridge/dev/`,
  and `e2e-reaper-surround.sh` plays a 12-channel track through it in the private REAPER profile.

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
  with Hann peak correction, or the interpolated peak for bands narrower than 1.5 bins); plugin CPU via `scripts/measure-resources.sh`.
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
  Plugin CPU via `scripts/measure-resources.sh`.

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
