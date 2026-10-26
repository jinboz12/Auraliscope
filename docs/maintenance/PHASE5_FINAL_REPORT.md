# Phase 5 final report: controlled `MeterModel` decomposition

Branch `maintenance/phase5-architecture`, based on `5584b9c06c` (the verified 29-commit maintenance series). Local
commits only: nothing was pushed, merged, tagged, packaged or released, and the build number is unchanged. The primary
checkout (Build 119) and the maintenance worktree with its held records were not modified.

## 1. Verified batches

Six of the ten allowed. Each batch ran: analysis of the responsibility and its callers, checks added first (passing on
the unchanged code), the change, the model self-tests, the full `scripts/check-all.sh`, the QA self-test suite, a
deliberate defect that the new checks must catch, a diff review, then one commit. The campaign stopped because what
remains in `MeterModel` is either observed state the views bind to, per-frame composition, or the capture lifecycle,
which cannot be verified here (section 7).

| # | Commit | Kind | Change |
|---|---|---|---|
| 1 | `f862be0` | test | Test seam `MeterModelDependencies`; `--test-model-lifecycle` with stand-ins for devices and capture; `scripts/check-model.sh` |
| 2 | `5da5378` | test | DAW plugin source states in the same self-test (fake receiver) |
| 3 | `7fe3bc5` | refactor | `SpectrumEngineCoordinator` owns the Multi-FFT and shared-STFT lifecycle |
| 4 | `8384dbe` | refactor | `RoutingStore` holds the routing rules and where routings are kept; `RoutingChecks` in `scripts/test.sh` |
| 5 | `028e748` | refactor | `BridgeLink` holds the receiver, the plugins it reports and their answers |
| 6 | `fbde81e` | refactor | `BridgeLink` keeps the saved insert and how restoration finds it |

## 2. Ordered local commits

```
f862be0 test(app): model lifecycle self-test with stand-ins for devices and capture
5da5378 test(app): DAW plugin source states in the model lifecycle self-test
7fe3bc5 refactor(app): SpectrumEngineCoordinator owns the Multi-FFT and shared STFT lifecycle
8384dbe refactor(app): RoutingStore holds the routing rules and where routings are kept
028e748 refactor(app): BridgeLink holds the receiver, the plugins it reports and their answers
fbde81e refactor(app): BridgeLink keeps the saved insert and how restoration finds it
```

This report is committed after them (documentation only, not a batch).

## 3. Components

`MeterModel` remains the one observable façade the views use; its public API and every `@Published` name are unchanged.

- **`MeterModelDependencies`** (seam, batch 1). What the model reaches outside the process through: the capture of a
  device (`CaptureBackend`, which `AudioCapture` satisfies), the DAW plugin receiver (`BridgeReceiving`, satisfied by
  `BridgeReceiver`), the device list, whether Core Audio notifications are followed, and the factory of the local
  analysis. `.live` builds the same objects at the same points as before. Only `--test-model-lifecycle` (QA bundle)
  builds the model with stand-ins.
- **`SpectrumEngineCoordinator`** (batch 3). Owns the Multi-FFT panel count, the engine's delayed stop, the stored
  Multi-FFT and shared-STFT settings, the diagnostic test-tone preview and the shared-STFT choice. It reads the model's
  current worker through a closure (no copy), so a delayed stop reaches the analysis running when it fires.
- **`RoutingStore`** (batch 4). A value type with no routing of its own: default orders (SMPTE, film, VST3), a device's
  speaker configuration, routings saved per device and format (and 1.0's 5.1.2 routing), validation of a routing
  applied at once or a role routed by hand, a plugin bus, the log summary. The routing in use stays `sourceForRole` on
  the model.
- **`BridgeLink`** (batches 5–6). Owns the receiver and its error, the plugins it reports (as sources, or as needing an
  update), commands and the logging of their acknowledgements, break logging, focus requests not yet acted on, the
  speaker layout a plugin refused, and the insert chosen last with restoration's settle delay and provisional span. It
  returns what restoration found; the model acts on it (selection, candidate list, status, analysis).
- **Not extracted: `CaptureSession`.** See section 7.

## 4. Test coverage added

| Check | Where | Count | Covers |
|---|---|---|---|
| `--test-model-lifecycle` | app self-test, QA bundle (`scripts/check-model.sh`) | 94 | launch selection; pause and resume (same analysis; drops lost at the stop stay counted); device rate change while paused; reset while paused; another source while paused; switching sources; capture and analyzer failures and recovery; device loss and return; routing by hand and at once, saved per device and format, film and VST3 order, 1.0's 5.1.2 routing, Mono; settings and Multi-FFT across a new analysis, delayed stop to the current analysis; DAW plugin waiting, connection, results, settings to the plugin, pause/resume/reset commands, format change, plugin drops, refused speaker layout, disconnect held and return, new instance after the settle delay, ambiguity, known copies, provisional span, focus requests, incompatible plugins, immersive bus routing, back to a device |
| `RoutingChecks` | `scripts/test.sh` (headless) | 5 groups | every layout and order on 0–64 inputs, literal 5.1/7.1.4 orders, speaker configurations, the permanent key format, saved routings kept to format and inputs, 1.0's routing, validation, bus routing, summary |
| `--test-model-worker` | existing | 14 | unchanged |

Each check runs against the model's state and, for lifecycle steps, the order of capture and analysis calls (a journal
the stand-ins write). Every batch had a deliberate defect fail its new checks (drops discarded at pause; a changed
rate ignored at resume; no resume command; analysis kept while ambiguous; the delayed stop bound to the wrong worker;
masking of roles outside the format dropped; refusals never reported; the settle delay dropped).

## 5. Invariants kept

Public model API and `@Published` names; observation (views read `MeterModel` only); main-actor ownership (the new
types are `@MainActor`, the seam's factories are main-actor closures); no change to `AudioRing`, `CaptureCallback.c`,
the DSP, the snapshot layout, the golden digests, settings keys, the plugin protocol or localisation; the P0-1/P0-2
accounting (drops carried across a pause and reset by a restart); no new restart policy; the order of capture and
analysis starts and stops (now pinned by the journal checks).

## 6. Full test results (final state)

`scripts/check-all.sh` (full): build-debug, shaders, core-checks (61 + routing groups + baseline digests), build-release,
app-features, file-analysis, bridge-analysis, spatial-report, bridge-transport: all pass. `scripts/check-model.sh`:
`--test-model-worker` 14/14, `--test-model-lifecycle` 94/94, stable over repeated runs. QA self-tests on the final build:
settings-presets 10/10 (Multi-FFT opt-in precondition), settings-draft 13/13, multifft-layout 36/36, pause 11/11,
model-worker demo and live 14/14, spectrum-average, peak-reset, nebula-gpu, spatial-projection, and Multi-FFT hidden by
default in a fresh preference domain: all pass. The numerics probe builds and runs with the longer core source list.

## 7. Remaining architecture issues

- **Capture lifecycle stays in `MeterModel`.** `restart`, `stop`, `pause`, `continuePaused`, permission handling, demo
  timing, stream IDs and drop accounting interleave with status, selection and the DAW plugin attachment. The paths that
  matter most cannot be reached with stand-ins here: the microphone permission prompt and denial, Core Audio
  configuration changes while running (`HardwareObserver`), real output taps, and P0-1's sustained refusal, whose
  restart policy is undecided. The lifecycle self-test covers the model-level orchestration and is the safety net for
  that split once live tests can run.
- **The DAW plugin flow is split, not inverted.** `BridgeLink` owns the state and the restoration decisions; the model
  still runs the polling flow (`pollBridge`, `followBound`, `findSaved`, `bind`, `becomeAmbiguous`) because each step
  changes the selection, the candidate list, the status and the analysis.
- **Settings mirrors** (format, Mono, layout, loudness standards, display options, bands) are `@Published` and bound by
  the views; moving them would change observation. Typed settings accessors (audit P2-3) remain the better next step.
- `MeterModel` still reads `UserDefaults.standard` directly in 35 places (42 before).
- **New coupling introduced.** `BridgeLink.remember` writes two of the model's stored keys (`inputDeviceUIDKey`,
  `inputDeviceIsOutputKey`), as the model did. The app's entry point asks `ModelLifecycleSelfTest` for stand-ins at
  launch, and the 750-line self-test ships in the app binary like the other self-tests. The coordinator is a `lazy`
  property, created on first use. The model's façade methods add one call of indirection.
- **Defects found and characterised, not fixed** (behaviour unchanged in this phase; each has a KNOWN ISSUE check that
  must be turned around by its fix):
  - A. A copy appearing while a restored insert is still provisional makes the choice ambiguous for one poll only:
    `startBridge` remembers the provisional insert with its session, so restoration's rule 1 binds it again.
  - B. `stop()` clears the paused session before testing it, so a paused DAW insert that is left is never sent the
    resume command it is meant to get; its measurement stays paused.

## 8. Hardware- and DAW-dependent checks not run

Live capture from a microphone or interface (permission, sample-rate change while capturing, buffer sizes above 4096),
output taps with System Audio Recording, `--capture-selftest` and `Tests/Probes/capture-render-probe.sh` on a loopback,
`--test-pause-resume` on a live input, `--test-panel-drawing` from a terminal (window-state dependent), VST3/AU plugin
builds and `HostHarness` (VST3 SDK not present), REAPER end-to-end tests and `--bridge-selftest`, and the first GitHub CI
run. None was treated as passed.

## 9. Outstanding release blockers

1. The two defects in section 7 (A, B) need decisions and fixes.
2. P0-1 sustained-refusal restart policy is undecided.
3. Live capture, device, plugin and DAW validation (section 8) has not run.
4. The maintenance series and Phase 5 are local branches only; integration into the release line, and the primary
   checkout's uncommitted Build 119, still need a decision.
5. CI has never run on GitHub.

## 10. Recommended next phase

1. Fix defects A and B, each turning its KNOWN ISSUE check around.
2. Decide the P0-1 restart policy; run the live checks in section 8 from a terminal.
3. Then split the capture session from the model, under the lifecycle self-test plus the live checks, starting with the
   attachment state (`attachedBridge`, `resultInbox`, `paused`, `droppedBefore`, stream IDs).
4. Typed settings accessors (P2-3), which would let the settings mirrors move without changing observation.
5. Move the `MeterModel` file's other types (`DSPWorker`, `HardwareObserver`, the status types) to files of their own
   when one of them next changes.
