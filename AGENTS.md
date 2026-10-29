# Working on Auraliscope

Instructions for coding agents (and people) changing this repository. They record invariants that are easy to
break and hard to see from any one file. Background: `docs/maintenance/CODE_AUDIT_2026-10.md` (architecture and
debt), `Bridge/ARCHITECTURE.md` and `Bridge/PROTOCOL.md` (DAW plugin side), `docs/MULTIFFT_ARCHITECTURE.md`.

## Layout

| Target | What | Rule |
|---|---|---|
| `Sources/AnalysisKernels` (C11) | Frame types and DSP kernels | No allocation in kernels |
| `Sources/AnalysisCore` (Swift, `package` access) | Every measurement; also compiled into both plugins | No AppKit, SwiftUI, Core Audio or UI types |
| `Sources/AudioRing` (C11) | Capture ring, snapshot triple buffer, Core Audio IO callbacks | Real-time code: see below |
| `Sources/BridgeTransport` (C11) | The app's end of the plugin socket | Protocol in `Bridge/PROTOCOL.md` |
| `Sources/Auraliscope` | The app: model, capture lifecycle, Metal canvases, panels, settings, reports, diagnostics | |
| `Bridge/Plugin` (C++/ObjC++) | VST3 and AUv2 inserts | Audio thread: atomics only |

## Build and verify

```sh
scripts/check-all.sh             # everything below that needs no hardware or DAW (--quick: debug build + core checks); CI runs it
swift build                      # debug app
swift build -c release           # release app
scripts/check-shaders.sh         # Metal shader library and pipeline states, layout asserts; headless, draws no frame (skips without a Metal device)
scripts/test.sh                  # 61 core checks, baseline checks (golden digests), routing rules, kernel checks, localization
scripts/check-app-features.sh    # update client, render policy, Dock layout
scripts/check-model.sh           # MeterModel self-tests in a QA bundle: worker interface; capture and DAW plugin states with stand-ins (launches the app)
scripts/check-file-analysis.sh   # file analysis against EBU reference tones (QA bundle, --demo)
scripts/check-selftests.sh       # the app's --test-* self-tests in a QA bundle on the demo signal (needs a window server)
Bridge/scripts/test-network.sh   # Bridge network carrier: dev VST3 in the test host ↔ a network display probe, loopback
Bridge/scripts/test-analysis.sh  # plugin-side analysis equals the desktop pipeline; breaks; RESULT encoding
Bridge/scripts/test-transport.sh # plugin core and receiver over a socket (ABR_SANITIZE=thread for TSan)
Bridge/scripts/check-spatial.sh  # spatial reductions report
```

- `scripts/test.sh` compiles an **explicit list** of sources into one module named `AnalysisCore`. A new file used
  by tested code must be added there. The plugin-side scripts (`Bridge/scripts/test-analysis.sh`, `check-spatial.sh`)
  have their own lists: add a file to them when the plugin's tests or tools use it, which includes some app files
  (`MeterScale.swift` and the files split from it). `Tests/Probes/analysis-sources.py` reads the `test.sh` list for
  probes. Because that build is one module, it hides a missing `import AnalysisCore` in app files: always run
  `swift build` too.
- A passing build is not proof of behaviour. Analysis changes must keep the golden digests
  (`Tests/Fixtures/pipeline-golden.json`) bit-identical; re-record them (`AURALISCOPE_RECORD_GOLDEN=1
  scripts/test.sh`) only for an intended, explained numerical change, after the portable checks pass.
- UI self-tests (`--test-*`, `--snapshot*`) run only in a bundle whose identifier ends in `.QA`, so the user's
  preferences, logs and settings presets are never touched (`scripts/qa-env.sh` stages one, with a private
  `AURALISCOPE_BRIDGE_SOCKET`; a QA bundle and any flagged launch also skip the launch update check); `--demo` supplies signal without opening an audio device. An idle loopback (a Pro
  Tools Audio Bridge nobody uses) serves `--capture-selftest <device id>`.
- Plugin builds need the VST3 SDK (`Bridge/scripts/fetch-sdks.sh` downloads it).
- Shader checks come in two levels. `check-shaders.sh` proves the shaders compile and that each shader struct matches its
  Swift struct (`MeterGPU.layoutChecks`); it does not draw. Rendering is checked only by the self-tests that draw frames
  (`--test-nebula-gpu`, `--render-preview`, the snapshots), which need a QA bundle or a window.

## Real-time rules

- Core Audio IO callbacks (`Sources/AudioRing/CaptureCallback.c`) and the plugins' `process` stay C/C++ with no
  locks, allocation, logging, Objective-C or Swift.
- The DSP queue owns `MeterPipeline`; only the main thread reads `MeterExchange` (`DSPWorker.latest()`).
- Every audio frame the capture does not deliver is a break. A producer that cannot write frames (refused by its device,
  or longer than its storage) calls `channel_ring_lose`: the frames count as dropped at once, and the break is marked
  where its next write starts. A ring that is full marks its own overflow. `BaselineChecks.swift` pins both
  (`captureRefusalsAreCountedAsBreaks`, `tapTruncationIsCountedAsBreak`).
- The IO callbacks also keep the capture's health record (`CaptureHealth`): relaxed atomic loads and stores by the IO
  thread alone, read by the main thread for capture recovery. Never a read-modify-write, fence or signal there.

## Contracts that span files

- **Snapshot layout:** `SnapshotSlots` (Swift), `METER_SNAPSHOT_FLOATS` (`Sources/AudioRing/include/AudioRing.h`),
  `DSPWorker.decode`, `ResultAssembler` and the RESULT tags must change together, with a plugin compatibility note.
  `BaselineChecks.snapshotLayout` checks the sizes; `docs/SNAPSHOT_CONTRACT.md` documents every group and the change
  procedure (a test keeps its table in step with the code).
- **Frequency axis:** use `LogFrequencyAxis` (`Sources/AnalysisCore/LogFrequencyAxis.swift`). Never write
  `20 * pow(upper / 20, …)`, `log(f / 20) / log(upper / 20)` or `min(20_000, sampleRate / 2)` again, and keep its
  helpers bit-identical to those expressions.
- **Metal uniforms:** a struct passed to a shader is declared in Swift and again in the shader source; change both in
  the same edit.
- **Settings:** never rename a stored `UserDefaults` key or a preference domain (`com.jinboz.SoundMeterJBZ…`):
  presets, the LABS migration and users' settings depend on them. Settings presets include every key except those
  excluded in `SettingsPresets.excludedKeys`.
- **Localization:** every `L("…")` key exists in all six `Resources/Localization/*.lproj/Localizable.strings`
  tables; a SwiftUI view that calls `L(` observes `Localizer.shared`; `scripts/check-localization.py` enforces both
  and the glossary.
- **Names:** never name third-party analyzers or brands in code, UI, keys or docs.
- **Capture recovery:** `CaptureRecoveryPolicy` decisions belong to `MeterModel.captureSession`, which every `stop()`
  and `pause()` changes. A new path that stops or restarts capture without them must change it too, or a pending
  restart could reach another capture. Recovery's own restart (`AudioCapture.restart`) keeps the ring, so lost frames
  stay counted and marked: never clear it there. `--test-model-lifecycle` checks both.

## Style

- Match the surrounding code: its comment density, naming and idioms. Doc comments explain what and why; build
  history belongs in `docs/UPDATE_LOG_since_1.2.2.md` and release notes, not in comments.
- One feature per file; do not add unrelated types to `Panels.swift`, `MetalCanvas.swift`, `MeterScale.swift` or
  `AuraliscopeApp.swift`.
- Launch flags are declared in `Diagnostics` (diagnostic) or next to their feature (`--bridge-launch`); keep their
  names stable: scripts and the user's workflows use them.

## Process

- Do not commit, push, tag, package or change build numbers unless asked. Packaging and naming conventions live
  with the delivery scripts (`Bridge/scripts/package-dist.sh`, `scripts/package-app.sh`).
- The README is edited on GitHub: fetch before committing to `main`.
- On the external volume, macOS writes AppleDouble `._*` files; if git reports a non-monotonic index, delete the
  `._*` files inside `.git`.
- Maintenance work in progress: `docs/maintenance/` (audit, baseline, refactoring logs).
