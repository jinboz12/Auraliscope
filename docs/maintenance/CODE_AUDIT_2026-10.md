# Auraliscope code audit (2026-10-24)

Repository-wide review for maintainability, architectural consistency, correctness, performance and real-time
safety. **Analysis only: no source file was changed for this audit.**

- **Baseline:** `main` at `a11b325` (2.0 RC 2 build 118 plus the installer-name fix), including the uncommitted
  build 119 working-tree changes (Multi-FFT settings and hover readout, frequency scale, tilt slider).
- **Method:** I read the real-time path end to end (Core Audio callbacks, rings, DSP worker, plugin audio thread),
  sampled the analysis core, the model, the rendering loop and the largest UI files, and ran scripted scans
  (duplication, unreferenced symbols, settings keys, concurrency idioms) plus the existing test suites (61 core
  checks, kernel checks, localization: all pass).
- **Evidence labels:** every finding is marked **Verified** (read in code, or reproduced by a scan) or
  **Hypothesis** (plausible from the code, needs a targeted test before acting).

---

## 1. Architecture overview

### 1.1 Targets and size

| Target | Language | Lines | Role |
|---|---|---:|---|
| `AnalysisKernels` | C11 | ~470 | Frame types (`ChannelFrame`, `StereoFrame`), true-peak, K-weighting, band filters, packed FFT powers |
| `AnalysisCore` | Swift (`package` access) | ~7,000 | Every measurement: loudness, spectrum, spectrogram (classic and reassigned), Multi-FFT, spatial field and observations, signal health, format detection, `MeterPipeline`, `StreamAnalyzer`, the RESULT protocol and `ResultAssembler`. No AppKit, SwiftUI or Core Audio. **Compiled into the app and, as static libraries, into both plugins.** |
| `AudioRing` | C11 | ~490 | Real-time ingress: `ChannelRing` (SPSC with break marks), `MeterExchange` (snapshot triple buffer), the Core Audio IO callbacks |
| `BridgeTransport` | C11 | ~1,600 | The app's receiving end of the DAW Bridge socket protocol |
| `Auraliscope` (app) | Swift / SwiftUI / Metal | ~33,000 in 64 files | Model, capture lifecycle, rendering, panels, settings, reports, diagnostics |
| `Bridge/Plugin` | C++ / ObjC++ / Swift ABI shim | ~3,200 | VST3 and AUv2 inserts: audio-thread capture, analysis thread, sender, editor |
| Tests and tools | Swift / C / C++ / Python / shell | ~6,500 tests | `scripts/test.sh` (core and kernel checks, localization), `check-app-features.sh`, Bridge transport and result tests, the e2e harnesses |

### 1.2 Data flow

```
LOCAL SOURCE (device input or output tap)
Core Audio IO thread ─ capture_input_proc / capture_tap_io_proc (C, no locks, no allocation)
  └─► ChannelRing (SPSC, 32,768 frames, NaN/Inf → 0, overflow and break marks)
DSP queue "Auraliscope.dsp", 60 Hz timer ─ DSPWorker
  └─► MeterPipeline (loudness, spectrum, spectrogram, Multi-FFT, bands, spatial, health)
  └─► 49,441-float snapshot ─► MeterExchange (lock-free triple buffer)
Main thread, display link ─ CanvasDriver.tick → MeterModel.canvasFrame() (once per refresh)
  └─► DSPWorker.decode → MeterSnapshot ─► scenes (Spectrum, Spectrogram, Waveform, Soundstage, Nebula) ─► Metal

DAW SOURCE
Host audio thread ─ BridgeCore::process (C++, atomics only) ─► RecordRing (SPSC bytes)
Plugin analysis thread ─ StreamAnalyzer = MeterPipeline (same Swift sources) ─► RESULT messages ─► socket
App receiver thread (BridgeServer.c) ─► ResultInbox (NSLock) ─► ResultWorker 60 Hz ─► ResultAssembler
  └─► the same float snapshot ─► MeterExchange ─► the same main-thread path
```

### 1.3 App layering, as it actually is

- **Hub:** `MeterModel` ([MeterModel.swift](../../Sources/Auraliscope/MeterModel.swift), 1,796 lines, 29 `@Published`)
  owns the capture lifecycle, worker selection, routing and channel order, the Bridge connection and commands,
  format detection and pinning, loudness targets, the Multi-FFT engine lifecycle, spatial geometry negotiation,
  status text, persistence of many settings, and the per-frame `canvasFrame()`.
- **Global singletons (18):** `PanelPlacement`, `CanvasDriver`, `SpeakerLayoutStore`, `DomeCamera`, `Localizer`,
  `ThemeSettings`, `SettingsDraft`, `LayoutPresets`, `SettingsPresets`, `GitHubUpdateChecker` and others. Views
  reach them directly.
- **Rendering:** one display link (`CanvasDriver`) drives every `MTKView` on the main thread, with one shared
  `CanvasFrame` and command buffer per refresh. Scenes build CPU geometry (`ShapeBuilder`) plus a few GPU passes
  (waterfall, 3D surface, nebula). All Metal shaders live in one ~930-line Swift string compiled at launch.
- **Settings:** `UserDefaults` keys read three ways: `@AppStorage` (110 uses), direct `UserDefaults.standard`
  (158 uses), and per-enum `static var stored` (23 keys). A global `UserDefaults.didChangeNotification` observer
  rebuilds `DisplayOptions` into the model.
- **Diagnostics:** [Diagnostics.swift](../../Sources/Auraliscope/Diagnostics.swift) (1,580 lines, 42 flags) plus
  self-tests (`BridgeSelfTest`, `CaptureSelfTest`, `DrawingDiagnostics`, `MultiFFTLayoutDiagnostics`,
  `SettingsDraftChecks`) compiled into the shipping binary and triggered by launch arguments.

### 1.4 What is in good shape (keep it)

These are deliberate strengths and constraints for any refactor:

- **Real-time boundary is clean on both sides.** The IO callbacks are C with no locks, allocation, ARC or Swift
  ([CaptureCallback.c](../../Sources/AudioRing/CaptureCallback.c)); the plugin's `process` uses atomics only
  ([BridgeCore.cpp:281](../../Bridge/Plugin/Core/BridgeCore.cpp)). Ring memory ordering is correct: release on
  `write_index`, acquire on read, and marks published before their frames.
- **Ingress sanitising:** non-finite samples become silence at the ring
  ([AudioRing.c](../../Sources/AudioRing/AudioRing.c), `channel_ring_write`), so a bad driver cannot poison
  recursive filters.
- **One analyser, three binaries:** `AnalysisCore` is UI-free and shared with the plugins, with documented
  equivalence between `StreamAnalyzer` and the desktop pipeline.
- **Break semantics are explicit and documented:** overflow, idle, bypass and offline marks flow from producer to
  `MeterPipeline.interrupt`, with the documented reset rules
  ([MeterPipeline.swift](../../Sources/AnalysisCore/MeterPipeline.swift) type comment).
- **Strong DSP tests:** 61 core checks, including EBU conformance, K-weighting across rates, true peak at
  boundaries and near Nyquist, reassignment, Multi-FFT read-range equals exhaustive, ring concurrency and the
  exchange tearing test.
- **Localization is policed:** [check-localization.py](../../scripts/check-localization.py) enforces key parity,
  placeholders, protected terms, glossary and view observation.
- **Teardown order is right:** the worker stops (`queue.sync {}`) before capture clears its ring
  ([MeterModel.swift:720](../../Sources/Auraliscope/MeterModel.swift)), and the ring lives as long as the model.

### 1.5 Unusual but intentional (not defects)

- Serial counters wrap at 999,999 (`sequence`, `spectrogramSerial`, `streamID`) so they stay exact in a `Float`
  snapshot slot ([MeterPipeline.swift:434](../../Sources/AnalysisCore/MeterPipeline.swift)). Correct by design.
- Hashes and revisions are packed across several floats in the snapshot (`SpatialObservations.load(parts:)`), for
  the same reason.
- Old-plugin compatibility paths (`SpatialPoints` of builds 87–97, RESULT tag 54, the standard-geometry
  fallback) are required while older plugins exist. They need a deprecation policy, not removal.
- The flat float snapshot is a deliberate shared contract between the C triple buffer, the DSP worker and the
  Bridge assembler. It is fragile (§2, P2-6) but it is the right shape for a lock-free C exchange.

---

## 2. Prioritized technical-debt report

Effort is a rough guide: S is under half a day, M is one or two days, L is several days.

### P0: correctness, stability, real-time safety

> **Phase 2 status (2026-10-24): see [BASELINE_2026-10.md](BASELINE_2026-10.md), section 3.** P0-1 is confirmed and
> reproduced, with a corrected cause: a rate mismatch makes `AudioUnitRender` refuse every slice; the buffer-size
> trigger described below is refuted, because IO buffer sizes are per process and capped at 4,096 frames on every
> device here. P0-2 is confirmed at unit level but unreachable on this machine (now P2). P0-3 is not reproducible
> under the plugin formats' contracts (now P2 hardening). The text below is the original audit, kept as written.

**P0-1. Device capture stops silently when the device's IO buffer grows past the size measured at start.** Verified code path; runtime trigger is a hypothesis.

- Evidence: `prepareContext` sizes storage once from the current `kAudioDevicePropertyBufferFrameSize`:
  `max(4096, min(16384, 2 × frames))` ([AudioCapture.swift:310](../../Sources/Auraliscope/AudioCapture.swift)).
  The input callback returns `kAudioUnitErr_TooManyFramesToProcess` for any larger slice and writes nothing
  ([CaptureCallback.c:9](../../Sources/AudioRing/CaptureCallback.c)). `HardwareObserver` watches only the nominal
  rate and is-alive ([MeterModel.swift:223](../../Sources/Auraliscope/MeterModel.swift)), never the buffer size. No
  break mark is written, so the analysis sees a stall, not a break.
- Scenario: Auraliscope captures an interface at 256 frames (storage 4,096). A DAW then sets the same device to
  8,192 frames. If AUHAL then delivers more than 4,096 frames per slice, every callback fails: no audio, and no
  "audio break" accounting. Whether AUHAL delivers slices above its `MaximumFramesPerSlice` default is exactly
  what needs testing.
- Recommendation: listen to `kAudioDevicePropertyBufferFrameSize` (restart capture on change, as rate changes do),
  size storage from AUHAL's `kAudioUnitProperty_MaximumFramesPerSlice`, and on any rejected slice mark the ring
  (`channel_ring_mark`) and count it, so a failure is visible.
- Risk: low. Capture restart already exists for rate changes. Verify with `CaptureSelfTest` and a buffer-size
  change while capturing. Effort S.

**P0-2. The output-tap IOProc truncates oversize deliveries without marking a break.** Verified.

- Evidence: in the multi-buffer path `frames` is clamped to `max_frames` and the tail is dropped
  ([CaptureCallback.c:49](../../Sources/AudioRing/CaptureCallback.c)). No mark is written, so analysis windows span
  the hole. The single-buffer path is unaffected because the ring counts its own overflow.
- Recommendation: as P0-1. Mark the ring with the lost frame count, and size storage from the aggregate's
  maximum IO size.
- Risk: low. Effort S.

**P0-3. The plugin swaps its capture ring under a host-contract assumption.** Hypothesis.

- Evidence: `growRing` replaces `ring_` (a `unique_ptr`) under `configLock_` while holding the analysis thread
  ([BridgeCore.cpp:236](../../Bridge/Plugin/Core/BridgeCore.cpp)). The audio thread dereferences `ring_` with no
  synchronisation (`ring_->write`, line 337). Safety rests on "the host does not process while it configures".
  VST3 guarantees this between `setActive(false)` and `setActive(true)`. For AUv2 (stream-format or channel
  changes during `Initialize`, or hosts that render during reconfiguration) the guarantee is weaker.
- Recommendation: first prove it. Add a `HostHarness` stress case that reconfigures channel count while a render
  thread calls `process`, under TSan. If it races, publish the ring through an atomic pointer that the audio
  thread loads once per block, and retire the old ring only after the analysis thread acknowledges the epoch.
- Risk: medium. This is real-time code in third-party hosts. Change only behind the harness test. Effort M.

### P1: high-value maintainability

**P1-1. There is no automated safety net beyond local scripts.** Verified.

> **Progress:** baseline checks and golden digests (Phase 2); `scripts/check-all.sh` (C02). CI and a SwiftPM test target remain.

- No CI workflow exists (`.github/` is absent). No SwiftPM test target exists: tests compile hand-picked source
  lists with `swiftc` ([test.sh](../../scripts/test.sh), [check-app-features.sh](../../scripts/check-app-features.sh)),
  so any refactor that moves code between files can silently drop it from the test build or break the build.
- Missing guards that refactors below depend on:
  - a **golden pipeline test** (fixed audio in, bit-exact `SnapshotSlots` out) protecting DSP refactors;
  - a **snapshot layout test** (`SnapshotSlots.total == METER_SNAPSHOT_FLOATS`, plus decode/assemble round trip;
    today only a runtime `precondition`);
  - a **Metal struct layout check** (P1-5);
  - **model-level tests** (source switch, pause/resume, Bridge fallback) using a fake `MeterWorker`.
- Recommendation: add `scripts/check-all.sh` (`swift build`, core checks, app-feature checks, localization, plugin
  unit tests where SDKs exist) and a macOS CI job that runs it. No audio device is needed.
- Risk: none (no product code changes). Effort M.

**P1-2. The analysis frequency axis has about 30 copies.** Verified.

> **Progress:** done in batch 3.1 ([REFACTORING_LOG.md](REFACTORING_LOG.md)): `LogFrequencyAxis` in `AnalysisCore`,
> 35 copies replaced, analysis output bit-identical. The spectrogram export's linear scale (P2-8) remains.

- `20 · (upper/20)^((i+0.5)/n)` and its inverse are written out 21 times in 9 files, including
  [SpectrumAnalyzer.swift](../../Sources/AnalysisCore/SpectrumAnalyzer.swift),
  [SpectrogramAnalyzer.swift](../../Sources/AnalysisCore/SpectrogramAnalyzer.swift),
  [MultiFFTAnalyzer.swift](../../Sources/AnalysisCore/MultiFFTAnalyzer.swift),
  [MetalCanvas.swift](../../Sources/Auraliscope/MetalCanvas.swift), [Panels.swift](../../Sources/Auraliscope/Panels.swift),
  [SpectrogramImage.swift](../../Sources/Auraliscope/SpectrogramImage.swift),
  [ReportPages.swift](../../Sources/Auraliscope/ReportPages.swift) and
  [MasteringAnalysis.swift](../../Sources/Auraliscope/MasteringAnalysis.swift).
- `min(20_000, sampleRate / 2)` is repeated 9 more times, although
  [MeterScale.upperFrequency](../../Sources/Auraliscope/MeterScale.swift) exists.
- Build 119's linear display scale had to be threaded through each copy by hand; the exported spectrogram image
  still uses the log axis only.
- Recommendation: one `LogBandAxis` in `AnalysisCore` (upper bound, band centre, band edges, fraction ↔ frequency).
  The app's `FrequencyScale` builds on it.
- Risk: medium for DSP files (floating-point order must not change). Land it only with the golden test from P1-1
  and require bit-identical output. Effort M.

**P1-3. `MeterModel` is a god object.** Verified.

- It has 1,796 lines and 29 published properties, and spans about ten responsibilities (§1.3).
- The worker abstraction leaks: `worker as? DSPWorker` appears at
  [MeterModel.swift:618, 626 and 632](../../Sources/Auraliscope/MeterModel.swift) because Multi-FFT and legacy STFT
  are not part of `MeterWorker`.
- Multi-FFT test-tone checks parse `CommandLine.arguments` inside model methods called every frame (lines 625
  and 631).
- Recommendation: extract in this order, each step behaviour-neutral:
  1. `SpectrumEngineCoordinator` (Multi-FFT and legacy STFT lifecycle);
  2. `CaptureSession` (capture plus worker start, stop, pause and resume, drops accounting);
  3. `BridgeController` (connection, commands, geometry negotiation);
  4. `RoutingStore` (assignments, channel order).

  `MeterModel` remains the façade the views bind to.
- Risk: medium-high (state transitions). Do it after the model-level tests exist. Effort L.

**P1-4. Per-frame work on the main thread could be event-driven.** Verified code; cost not measured.

- `canvasFrame()` ([MeterModel.swift:841](../../Sources/Auraliscope/MeterModel.swift)) runs at 60–120 Hz. Each call:
  - runs `configureSpectrumArchitecture()`. While the Multi-FFT panel is hidden this re-arms a 0.4 s teardown
    work item forever: it fires, clears itself, and the next frame schedules another;
  - re-sends six configuration values to the worker and the Bridge (cheap equality guards);
  - decodes the snapshot into about 45 fresh arrays (`DSPWorker.decode`,
    [MeterModel.swift:134](../../Sources/Auraliscope/MeterModel.swift)), after `meter_exchange_read` has copied
    198 KB;
  - hashes the observation header.
- Separately, every `UserDefaults` write (including each step of a divider drag) rebuilds `DisplayOptions`
  (~35 key reads) and decodes Multi-FFT data
  ([MeterModel.swift:777](../../Sources/Auraliscope/MeterModel.swift)).
- Recommendation: measure first with the existing CPU A/B harness (`output/build117/cpu-ab.sh`). Then configure on
  change (placement, format, settings), decode into reused storage (or decode lazily per consumer), and narrow the
  defaults observer to the keys that matter.
- Risk: low-medium. Wake-up paths for paused canvases depend on these publishes (see `CanvasDriver.follow`).
  Effort M.

**P1-5. Shaders are hand-mirrored in a Swift string.** Verified.

> **Progress:** step 1 done (C07: `MeterGPU.layoutChecks`); the source now lives in `MetalShaders.swift` (C09). A precompiled metallib remains optional.

- About 930 lines of MSL sit in `shaderSource` ([MetalCanvas.swift:713](../../Sources/Auraliscope/MetalCanvas.swift)),
  compiled with `makeLibrary(source:)` at launch.
- Uniform structs are declared twice and must match field for field: `WaterfallState` (line 1321 ↔
  `UnderlayState`), `SurfaceState` (line 1431 ↔ Swift 1825), and the nebula and particle states. A mismatch draws
  garbage silently. Build 119 had to edit both sides.
- Recommendation, step 1 (cheap): a diagnostic that compiles the library offscreen and checks each Swift struct's
  `MemoryLayout.size` and stride against a value the shader reports (or `static_assert(sizeof(...) == N)` lines
  generated from the Swift sizes into the source). Step 2 (optional): move to `.metal` files with a shared C
  header, built to a `metallib` by a build script. SwiftPM does not compile `.metal` itself.
- Risk: step 1 none; step 2 medium (build pipeline, packaging). Effort S then M.

**P1-6. Diagnostics are woven into production paths.** Verified.

> **Progress:** ad hoc flag checks moved into the `Diagnostics` registry (C03) and one parser for valued flags (C04). Splitting self-tests from the app remains.

- `Diagnostics.swift` holds 42 flags. Nine more ad hoc `CommandLine.arguments` checks are spread over production
  files (`MeterModel`, `MetalCanvas`, `SettingsView`, `AuraliscopeApp`, `BridgeSource`).
- The app's `init` exits for UI self-tests without a `.QA` bundle id
  ([AuraliscopeApp.swift:45](../../Sources/Auraliscope/AuraliscopeApp.swift)). That is correct, but it lives in the
  app entry point.
- Recommendation: parse launch options once into a `LaunchOptions` value (flags keep their names, because scripts
  depend on them). Route self-tests through one `DiagnosticsHost` entry. Optionally compile heavy self-tests only
  under a `QA` build flag.
- Risk: low if flag names are preserved. Effort M.

**P1-7. Documentation misleads agents.** Verified.

> **Progress:** `AGENTS.md` + `CLAUDE.md` (C01), `docs/SNAPSHOT_CONTRACT.md` (C13). `Bridge/ARCHITECTURE.md`'s LABS-era text remains to rewrite.

- [Bridge/ARCHITECTURE.md](../../Bridge/ARCHITECTURE.md) still describes "Auraliscope Bridge 1.3dev build 3" and
  "Auraliscope LABS" (21 mentions); the app has been Auraliscope 2.0 since build 92.
- There is no `AGENTS.md` or `CLAUDE.md`, so each agent rediscovers the invariants: snapshot layout procedure,
  settings-key stability, real-time rules, localization rules, QA bundle usage, packaging.
- Doc comments carry build-number history (53 "Build N" or "before build N" phrases in `Sources/`). This history
  belongs in the update log.
- Recommendation: §5.
- Risk: none. Effort S.

### P2: structural cleanup and consistency

**P2-1. Grab-bag files.** Verified.

> **Progress:** `MeterScale.swift` split (C08); shaders (C09) and the four scenes (C10) out of `MetalCanvas.swift` (3,859 → 1,504 lines); Spectrum panel (C11), controls (C12) and display options (C15) out of `Panels.swift` (3,202 → 1,734 lines). `AuraliscopeApp.swift` remains.

| File | Lines | Types | Mixes |
|---|---:|---:|---|
| [Panels.swift](../../Sources/Auraliscope/Panels.swift) | 3,200 | 65 | card chrome, Spectrum panel and inspectors, Loudness, History, Waveform, Soundstage, Levels, `DisplayOptions`, settings enums, controls (`GlassSegments`, `DiscButton`) |
| [MetalCanvas.swift](../../Sources/Auraliscope/MetalCanvas.swift) | 3,841 | 27 | driver, GPU setup, all shaders, four scenes, preview renderer |
| [AuraliscopeApp.swift](../../Sources/Auraliscope/AuraliscopeApp.swift) | 1,674 | 41 | entry point, welcome, toolbar, window plumbing, the loudness hero, menus |
| [MeterScale.swift](../../Sources/Auraliscope/MeterScale.swift) | 1,581 | 25 | scales, pitch, peak tracking, eight settings enums, five layout structs |

Recommendation: mechanical moves into feature folders (`Spectrum/`, `Loudness/`, `Soundstage/`, `Waveform/`,
`Chrome/`, `Rendering/`, `Settings/`), one commit per moved type group. `test.sh` source lists must move in the
same commit (P1-1). Risk: low. Effort M.

**P2-2. There are five hover readout implementations.** Verified.

`SpectrumCardInspector`, `SpectrogramInspector`, `WaveformCursor` and `WaveformProbeTag` (Panels.swift 590 / 665 /
2678), `DomeProbeTag` (DomeScene.swift 296) and `MultiFFTInspector` each re-implement pointer state, a diagnostic
hold point (four different flags), crosshair, tag placement and `BadgeSurface`. Only the spectrogram's avoids
other overlays (build 119). Recommendation: a shared `ProbeOverlay` modifier plus `ReadoutTag` and one placement
function. Risk: low-medium (visual). Verify with snapshot diffs. Effort M.

**P2-3. Settings have three access patterns and duplicated literal keys.** Verified.

> **Progress:** C06 named constants for every key that was spelled out in several places (63 call sites). A typed accessor remains.

28 literal keys; 14 of them appear as literals in more than one file (for example `inputDeviceUID` 13×,
`levels.bands` across four files, `showWelcomeOnLaunch` across three). Recommendation: a `SettingsKey` registry
(the same strings, never renamed: presets, migration and the LABS import depend on them) and a typed accessor
used by both `@AppStorage` call sites and model code. Risk: low if strings are unchanged. Add a test that the
registry's strings equal the historical ones. Effort M.

**P2-4. Concurrency idioms are mixed, and Swift 6 checking is off.** Verified.

The package uses tools 6.0 with `swiftLanguageModes: [.v5]`. The main-thread model and placement objects are not
annotated `@MainActor` but rely on `MainActor.assumeIsolated` (60 uses, which trap if ever reached off main),
`Task { @MainActor }` (10) and `DispatchQueue.main.async` (104). `MeterExchange` assumes a single consumer that
nothing enforces (`latest()` is main-only today). Recommendation:

1. annotate `MeterModel`, `PanelPlacement`, `CanvasDriver` and the stores `@MainActor`;
2. add `dispatchPrecondition(.onQueue(.main))` to `latest()`;
3. move `AnalysisCore` to Swift 6 mode first (already thread-confined), then the app target by file.

Risk: medium (surfaces latent races; compile churn). Effort L.

**P2-5. Dead and legacy code.** Verified.

- `SoundstageScene.drawBandImage` is never called **(removed in campaign batch C14)**
  ([MetalCanvas.swift:3487](../../Sources/Auraliscope/MetalCanvas.swift)).
- The stereo `AudioRing` API (`audio_ring_*`) is used only by tests; production uses `ChannelRing`.
- "Legacy (Build 113)" shared-STFT A/B is still a user setting. Decide its product fate.
- LABS-era names survive in scripts and assets (`build-labs-app.sh`, `install-labs-app.sh`, `labs-selftest.sh`,
  `AuraliscopeLabs.icns`). Rename scripts only; never change bundle ids (`com.jinboz.SoundMeterJBZ…`) or
  preference domains.

Risk: low. Effort S.

**P2-6. The snapshot contract is maintained by hand in three places.** Verified.

> **Progress:** checked by `BaselineChecks` (Phase 2) and documented in `docs/SNAPSHOT_CONTRACT.md` with a test keeping it current (C13).

The size comment and `METER_SNAPSHOT_FLOATS 49441` ([AudioRing.h:65](../../Sources/AudioRing/include/AudioRing.h)),
`SnapshotSlots` ([MeterPipeline.swift](../../Sources/AnalysisCore/MeterPipeline.swift)), and `DSPWorker.decode` /
`ResultAssembler` all have to agree. A runtime `precondition` is the only guard. Recommendation: a test (P1-1);
optionally generate the C constant from `SnapshotSlots.total` in the build script. Risk: none. Effort S.

**P2-7. The test harness is coupled to file lists.** Verified.

Adding a dependency to a tested app file (for example `MeterScale.swift` needing a new type) breaks `test.sh`.
Recommendation: a SwiftPM `testTarget` for `AnalysisCore` with swift-testing or XCTest, keeping the fast scripts as
wrappers. Risk: low. Effort M.

**P2-8. Build 119 follow-up.** Verified.

The exported spectrogram image ([SpectrogramImage.swift](../../Sources/Auraliscope/SpectrogramImage.swift)) ignores
the new linear frequency scale.

### P3: optional cosmetic

- `MeterScale.swift` is misnamed for its contents (it is mostly layouts and settings enums).
- The demo sequence wraps at 1,000,000 ([MeterModel.swift](../../Sources/Auraliscope/MeterModel.swift),
  `pollSnapshot`) while the pipeline wraps at 999,999. Harmless; align them.
- `test.sh`'s fallback path uses `rg`, which is not installed outside the Claude Code shell (only hit when
  compilation fails).
- AppleDouble `._*` files appear throughout the external-volume checkout (ignored by git, but they have corrupted
  `.git` before). Document this in the agent instructions.
- Review the 64 `try?` and 29 force unwraps in the app for swallowed persistence errors (`SettingsPresets`,
  layout and speaker stores).

---

## 3. Risk assessment summary

| ID | Change | Behaviour risk | Real-time risk | Verification |
|---|---|---|---|---|
| P0-1/2 | Buffer-size listener, storage sizing, break marks | Low | Low (C callback gains one branch) | `CaptureSelfTest`, buffer-size change during capture, break counter |
| P0-3 | Atomic ring publish in plugin (only if the race is proven) | Low | **Medium** | HostHarness + TSan, REAPER e2e, both formats |
| P1-1 | CI, golden and layout tests | None | None | n/a |
| P1-2 | Frequency-axis unification | **Medium** (numerics) | None | Golden pipeline bit-exact, report PDFs unchanged |
| P1-3 | `MeterModel` split | **Medium-high** | None | Model tests, existing self-tests, manual source switching |
| P1-4 | Event-driven config, decode reuse | Low-medium | None | CPU A/B, paused-canvas wake tests (`--test-pause-resume`) |
| P1-5 | Shader layout checks / metallib | None / medium | None | Offscreen `--render-preview` diff |
| P1-6 | `LaunchOptions` | Low | None | All e2e scripts still pass (flag names frozen) |
| P2-1 | File moves | Low | None | Build and tests |
| P2-2 | Shared probe overlay | Low-medium (visual) | None | Snapshot diffs with each probe flag |
| P2-3 | Settings registry | Low | None | Key-string test, presets round trip, LABS migration test |
| P2-4 | `@MainActor` / Swift 6 | Medium | None | Compile, TSan run, self-tests |
| P2-5 | Dead code, script renames | Low | None | Build, packaging dry run |

---

## 4. Staged refactoring roadmap

Ordered by benefit, risk and dependencies. Each stage is independently shippable and leaves behaviour unchanged
unless the item says otherwise.

**Stage 0: safety net (no product change).**
1. Write `AGENTS.md` (§5.3) and refresh `Bridge/ARCHITECTURE.md` (P1-7).
2. `scripts/check-all.sh` plus a macOS CI job (P1-1).
3. Golden pipeline fixtures: three short WAVs (stereo music, 7.1.4 tones, a break) run through `MeterPipeline`,
   hashed per snapshot slot group.
4. Snapshot layout test and Metal struct size check (P2-6, P1-5 step 1).

Exit criterion: CI green; golden hashes recorded on the current `main`.

**Stage 1: real-time correctness.**
5. P0-1 and P0-2 (capture buffer size and break marks).
6. P0-3 harness test; fix only if it reproduces.

Exit criterion: capture survives a buffer-size change; every dropped frame appears as a break.

**Stage 2: seams that unblock everything else.**
7. `LogBandAxis` in `AnalysisCore` (P1-2), with golden bit-exactness required.
8. `SettingsKey` registry (P2-3) and the narrowed defaults observer (P1-4, part).
9. `MeterWorker` capability protocol, removing the `as? DSPWorker` casts (P1-3 prerequisite).
10. `LaunchOptions` (P1-6).

**Stage 3: decomposition.**
11. Model-level tests with a fake worker, then extract `SpectrumEngineCoordinator`, `CaptureSession`,
    `BridgeController` and `RoutingStore` (P1-3).
12. Split the grab-bag files by feature (P2-1).
13. Shared probe overlay (P2-2); also fixes the remaining readout and overlay collisions consistently.

**Stage 4: concurrency hardening.**
14. `@MainActor` annotations and a single-consumer assertion on the exchange (P2-4).
15. Swift 6 mode for `AnalysisCore`, then the app target by file.

**Stage 5: measured performance.**
16. CPU A/B baseline, then event-driven configuration and snapshot decode reuse (P1-4).
17. Precompiled metallib only if launch time is shown to matter (P1-5 step 2).

**Stage 6: cleanup.**
18. Dead code and LABS script renames (P2-5), the spectrogram export scale (P2-8), and the P3 items.

Dependencies: Stage 0 gates Stages 2–5. Item 9 gates 11. Item 7 should land before any further spectrum or axis
features.

---

## 5. Documentation, tests and agent instructions

### 5.1 Documentation gaps (highest value first)

1. **Snapshot contract:** one page listing every `SnapshotSlots` group, its producer (pipeline or assembler), its
   consumers, and the change procedure (C constant, assembler, RESULT tags, plugin version).
2. **State machines:** capture states (standby, capturing, paused, ring failed, Bridge waiting or connected,
   fallback), and how pause and resume differ for local and Bridge sources. Today this is spread over `MeterModel`
   comments and `Bridge/ARCHITECTURE.md`.
3. **Settings inventory:** every key, owner, default, whether presets include it, and migration history.
4. **Rendering loop:** `CanvasDriver` wake and rest rules, why paused canvases rest, and which publishes wake them
   (the P1-4 work depends on this).
5. **Algorithm notes already well documented in code** (loudness, true peak, reassignment, spatial field,
   Multi-FFT) should be linked from one index rather than rewritten.

### 5.2 Tests to add before refactoring

| Test | Protects | Notes |
|---|---|---|
| Golden pipeline (bit-exact) | P1-2, any DSP move | Fixtures under `Tests/Fixtures`; hash per slot group so a failure names the measurement |
| Snapshot encode/decode and assembler parity | P2-6 | Partly exists in `Bridge/Tests/ResultTests.swift`; add desktop decode |
| Layout geometry, log and linear | P1-2, build 119 | `SpectrogramLayout` row and frequency inverses, ticks, keyboard |
| Fake-worker model tests | P1-3 | Source switch, pause/resume, Bridge waiting and fallback, Multi-FFT teardown |
| Metal struct sizes | P1-5 | Offscreen diagnostic or generated asserts |
| Capture buffer-size change | P0-1 | Through `CaptureSelfTest` on a loopback device |
| Plugin reconfigure under render (TSan) | P0-3 | `Bridge/Tools/HostHarness.mm` |
| Snapshot image diffs | P2-1, P2-2 | Existing `--snapshot` and `--render-preview` flags with fixed size and demo time |

### 5.3 Proposed `AGENTS.md` contents (repository root)

- **Build and test:** `swift build`; `scripts/test.sh`; `scripts/check-app-features.sh`;
  `python3 scripts/check-localization.py`; UI self-tests only in a `.QA` bundle (staging recipe), with `--demo` for
  signal.
- **Real-time rules:** nothing but C in Core Audio IO callbacks and the plugin's `process`; no locks, allocation,
  logging or Objective-C there; the DSP queue owns `MeterPipeline`; only the main thread reads `MeterExchange`;
  every dropped or skipped frame must produce a ring mark.
- **Snapshot change checklist:** `SnapshotSlots`, `METER_SNAPSHOT_FLOATS`, decode, `ResultAssembler`, RESULT tag,
  plugin compatibility note.
- **Settings:** never rename a stored key or preference domain; add keys through the registry; consider presets and
  migration.
- **Localization:** every `L("…")` key in all six tables; views that call `L(` observe `Localizer.shared`; no
  third-party trademarks in code, UI or docs.
- **Metal:** a uniform struct change touches the Swift struct and the shader struct in the same commit, plus the size
  check.
- **Frequency axis:** use `LogFrequencyAxis` (`Sources/AnalysisCore/LogFrequencyAxis.swift`); never inline `20 · pow(upper/20, …)`, `log(f/20)/log(upper/20)` or `min(20_000, rate/2)`, and keep its helpers bit-identical to those expressions.
- **Code placement:** one feature per file, no new types in grab-bag files, history in the update log rather than in
  doc comments.
- **Process:** do not package, commit, push or bump versions unless asked; the delivery steps and naming in
  `docs/RELEASE_PREPARATION.md`; fetch before pushing (README is edited on GitHub); delete `._*` files inside `.git`
  if git reports index errors on the external volume.

---

## 6. Open questions for review

1. Should the "Legacy (Build 113)" shared-STFT choice remain a user-facing option in 2.0, or become a diagnostic?
2. Is a minimum supported plugin build acceptable (for example "plugins older than build 98 show the standard
   layout only"), so the compatibility paths can get a removal date?
3. Is CI on GitHub-hosted macOS runners acceptable, given that the Steinberg SDK fetch is needed for plugin tests
   (or should CI cover the app and core only)?
4. Is moving shaders to a precompiled `metallib` worth a change to the packaging scripts, or is the runtime compile
   acceptable?
