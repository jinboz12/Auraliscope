# Post-refactoring review (2026-10-25)

Independent review of the autonomous refactoring campaign (C01–C15), Phase 2 baseline and batch 3.1, before any
further standardization or release work. Everything below was re-derived from the repository and re-run for this
review; nothing is taken from the campaign's own records without checking it. No application behaviour was changed
by the review.

**Scope reviewed:** worktree `<maintenance worktree>`, branch `maintenance/p0-baseline`,
base `a11b325`, all uncommitted: Build 119 (applied from the primary checkout), Phase 2, batch 3.1, campaign C01–C15.
**Comparison builds:** pure Build 118 (`git archive a11b325`, built in scratch space) and unrefactored Build 119 (the
primary checkout, whose sources were not modified; only its build cache).

## 1. Summary

| Question | Answer |
|---|---|
| Were 15 batches completed? | **Yes.** The JSON claims 15 `COMPLETED`; every recorded file list matches the snapshot deltas exactly; no batch is in progress. |
| Did any behaviour change? | **No regression found.** Analysis output is bit-identical to Build 118/119 in the optimized test build, DSP benchmark checksums match, every executed self-test gives the same result as the unrefactored build. |
| Is the code more maintainable? | **Yes, measurably**, mainly through file organization, single definitions (frequency axis, settings keys, launch flags), compile-time-of-launch shader checks and written contracts. Structural debt in the model and app shell is untouched. |
| Are the P0 findings resolved? | **No.** P0-1 is confirmed and still open; P0-2 and P0-3 unchanged (downgraded to P2 in Phase 2). The refactoring did not touch the code involved. |
| Release-ready? | **Not yet** (section 9): nothing is committed, Build 119 exists in two copies, P0-1 is open, and plugin/DAW and device-rate checks were not possible here. |

## 2. Campaign history, verified

| Check | Method | Result |
|---|---|---|
| Batches completed | JSON state vs snapshot deltas `C<n>-before`..`C<n>-after` | 15/15; recorded file lists match the actual deltas for every batch |
| Work outside batches | deltas between `C<n>-after` and `C<n+1>-before` | Only two documentation edits to the audit's progress notes (after C14 and after C15), acknowledged in the log but outside any snapshot pair |
| Interrupted batch | C10 pause window `C10-before`..`C10-start` | No change: C10 was cleanly restarted after the usage-limit pause |
| Real-time, kernels, transport, plugins | `git diff a11b325 -- Sources/AudioRing Sources/AnalysisKernels Sources/BridgeTransport Bridge/Plugin Package.swift` | **Unchanged** |
| `AnalysisCore` | `git diff a11b325 -- Sources/AnalysisCore` | 12 lines in 5 files (batch 3.1 only) + new `LogFrequencyAxis.swift` |
| Overall vs `a11b325` | `git diff --stat` | 36 tracked files changed, 25 untracked files (includes Build 119) |

### Audit findings: status

| Finding | Status | Evidence / what remains |
|---|---|---|
| P0-1 capture loses refused slices silently | **Open** (confirmed) | Probe reproduces today exactly as in Phase 2 (§5) |
| P0-2 tap truncation without mark | **Open** (P2) | Characterization test still pins it |
| P0-3 plugin ring swap | **Open** (P2 hardening) | Plugin code unchanged; transport TSan clean |
| P1-1 safety net | Partial | Golden + baseline checks, `scripts/check-all.sh`; no CI, no SwiftPM test target |
| P1-2 frequency axis | Done (part 1) | `LogFrequencyAxis`; spectrogram export on the linear scale (P2-8) remains |
| P1-3 `MeterModel` | Prerequisite only | Casts gone (C05); model still 1,804 lines, no model tests |
| P1-4 per-frame work | Open | |
| P1-5 shader mirroring | Step 1 done | Size checks (C07), source in its own file (C09); checks run only when the library is compiled at launch |
| P1-6 diagnostics coupling | Partial | Flags centralized (C03, C04); `Diagnostics.swift` (1,572 lines) and all self-tests still ship in the app |
| P1-7 documentation | Partial | `AGENTS.md`, `CLAUDE.md`, `docs/SNAPSHOT_CONTRACT.md`; `Bridge/ARCHITECTURE.md` still describes LABS 1.3dev (21 mentions) |
| P2-1 grab-bag files | Largely done | `MetalCanvas`, `Panels`, `MeterScale` split; `AuraliscopeApp` (1,674), `NebulaScene` (2,020), `PanelPlacement` remain |
| P2-2 hover readouts | Open | |
| P2-3 settings keys | Partial | Constants for duplicated literals (C06); `SettingsBackup.keys` still literal; three access patterns remain |
| P2-4 concurrency annotations | Open | |
| P2-5 dead/legacy code | Partial | `drawBandImage` removed (C14); stereo `audio_ring_*` API and LABS-named scripts remain |
| P2-6 snapshot contract | Done | Document + test that keeps it in step (C13) |
| P2-7 explicit test file lists | Open, slightly worse | The lists gained 4 app files (C08) |
| P2-8 export linear scale | Open | |
| P3 items | Open | `rg` in `test.sh`, demo modulus, AppleDouble notes |

## 3. Code review

### What genuinely improved

- **Organization.** The three grab-bag files lost 5,124 lines to 11 focused files (`MetalCanvas.swift` 3,841 → 1,504;
  `Panels.swift` 3,200 → 1,734; `MeterScale.swift` 1,581 → 260). The largest file in the app is now 2,020 lines
  (`NebulaScene.swift`, untouched) instead of 3,841. Moves were verified line for line (multiset proofs per batch,
  re-checked here through the snapshots); no access level was widened except two shader properties (`private` →
  internal, needed across files).
- **Single definitions.** The frequency axis (35 copies → `LogFrequencyAxis`, bit-identical), 12 stored keys (63 call
  sites → owner constants), launch flags (9 ad hoc parses → named flags), point/size flag parsing (10 → 1 helper).
- **Interfaces.** `MeterWorker` now states what both workers do; the three `as? DSPWorker` casts are gone, which makes
  a fake worker for model tests possible. ResultWorker's no-ops are documented.
- **Guards.** Shader struct sizes are checked against Swift (`static_assert`, proven to fire); the snapshot document
  is checked against the code (proven to fire); golden digests catch a 1e-7 change.
- **Dependency direction.** The only new cross-module use is the app calling `AnalysisCore.LogFrequencyAxis`, the right
  direction. No new dependency, no new abstraction layer.

### Problems found in the campaign's own work (none affects behaviour)

| # | Finding | Severity | Evidence |
|---|---|---|---|
| R3 | The four scene files moved in C10 carry their source file's whole import list; 5–6 imports each are likely unused (`AppKit`, `AudioRing`, `AudioToolbox`, `Combine`, `ImageIO`, `SwiftUI`) | P3 | Heuristic symbol scan (not compiler-proven) |
| R4 | `AGENTS.md` says new files go into `test-analysis.sh` / `check-spatial.sh` "if in `AnalysisCore`", but those lists also contain app files (`MeterScale` and the three files split from it) | P3 (doc) | `AGENTS.md` line 33 vs the scripts |
| R5 | Two documentation edits were made between batch snapshots, so they are not attributable to a batch by tooling (they are mentioned in the log) | P3 (process) | snapshot deltas |
| R6 | The shader size checks run only when the Metal library is compiled (app launch, `--render-preview`); `check-all.sh` never compiles it, so a mismatch is caught by the first launch, not by the test command | P2 | `check-all.sh` steps |
| R8 | Settings keys are partly consolidated: `WelcomeSheet.showOnLaunchKey` is read by `SettingsView` and `AuraliscopeApp` (a key owned by a view type), and `SettingsBackup.keys` still spells three model keys as literals (kept deliberately because the test build does not compile `MeterModel`) | P3 | C06 diff, `Localizer.swift:177` |
| R9 | `MeterScale.upperFrequency` remains as a thin wrapper over `LogFrequencyAxis.upper`: two entry points for one value | P3 | `MeterScale.swift` |
| R10 | The explicit source lists in `test.sh`, `test-analysis.sh`, `check-spatial.sh` grew by four files; the underlying fragility (P2-7) is unchanged | P2 | C08 |

No duplicated replacements, circular dependencies, new singletons or unnecessary abstractions were found. Coupling
did not increase: moved code kept its file-private relationships (checked before each move).

## 4. Functional and numerical verification (all executed for this review)

| Area | Command / test | Result |
|---|---|---|
| Builds | `swift build`, `swift build -c release` | pass |
| Core suite (FFT, spectrum, spectrogram classic/reassigned, Multi-FFT, LUFS, true peak, EBU 3341/3342, K-weighting, stereo bands, spatial field, rings, exchange) | `scripts/test.sh` (in `check-all.sh`) | 61/61 pass; Multi-FFT 160 sine cases pass |
| Numerical equivalence | golden digests, 5 scenarios, every snapshot group | **bit-identical** to the digests recorded on `a11b325` |
| Frequency axis | `LogFrequencyAxis` pin test | pass |
| Snapshot layout and contract | `BaselineChecks.snapshotLayout`, `snapshotContractDocument` | pass |
| Localization | `check-localization.py` | 924 keys pass |
| App feature checks (updates, render policy, Dock layout) | `scripts/check-app-features.sh` | pass |
| File analysis / reports (EBU tones, surround weight, AAC) | `scripts/check-file-analysis.sh` | pass |
| Plugin-side analysis ≡ desktop pipeline; breaks; RESULT | `Bridge/scripts/test-analysis.sh` | pass |
| Spatial reductions | `Bridge/scripts/check-spatial.sh` | pass; report content identical to batch 3.1 |
| Bridge communication (plugin core ↔ receiver, socket) | `Bridge/scripts/test-transport.sh`, UBSan and TSan | pass; **0 TSan warnings** |
| Multichannel routing end to end (Core Audio) | release `--capture-selftest 153` | PASS, 16 roles, scrambled map, shared and disabled roles |
| Memory safety of the core | `scripts/test.sh address` | **no AddressSanitizer errors**; stops at the golden check (R2) |
| Panels | `--test-panel-drawing` | 11/11 |
| Multi-FFT layout and persistence | `--test-multifft-layout` | 36/36 |
| Dock strip | `--test-strip-widths`, `--test-strip-return` | pass |
| Settings persistence | `--test-settings-presets` 10/10, `--test-settings-draft` 13/13 | pass |
| Spectrum average, peak reset | `--test-spectrum-average`, `--test-peak-reset` | pass |
| Nebula / spatial GPU | `--test-nebula-gpu` 0 failures; `--test-spatial-projection` GPU centroid within 0.038 pt of CPU | pass |
| Language, theme, mode switching | `--test-language-switch`, `--test-theme-switch`, `--test-mode-switch` | complete (timing reports, no pass/fail) |
| Source switching (live loopbacks) | `--input-device 149 --test-source-switch 153` | pass (refactored and Build 119) |
| Device add/remove (synthetic) | `--test-device-source-selection` | 6/6 (refactored and Build 119) |
| Pause / resume (live) | `--test-pause-resume --input-device 153` | 3 pass, **1 fail, identical in Build 118, Build 119 and refactored** (R1) |
| Hidden beta default | fresh preferences domain, snapshot | Multi-FFT panel hidden until opted in; default layout |
| Rendering | Stereo (Log, Linear), Immersive snapshots | all panels render |

### Issues found that predate the refactoring

- **R1 (test defect, pre-existing since Build 113).** `--test-pause-resume` fails "the paused window keeps its picture
  unchanged" in Build 118, Build 119 and the refactored build alike. A pixel diff of the two paused captures shows
  5,970 changed pixels confined to the status bar's bottom-right strip (y 1602–1621): the live frame-rate readout
  added in Build 113 keeps updating while paused. Either the readout should freeze while paused or the test should
  exclude it; nothing else changes in the paused picture.
- **R2 (numerics, pre-existing).** The Enhanced (reassigned) spectrogram's output differs bitwise between the
  optimized build (`-O`) and both an unoptimized (`-Onone`) and an AddressSanitizer build, which agree with each other
  (`dc069defaf2c3906` vs the recorded `89055ef97eab50e2`). It is deterministic, identical in Build 118 and the
  refactored code, and ASan reports no memory error; the zone buffers are zero-initialized. The likely cause is
  optimizer floating-point code generation (for example, operation contraction) in that path. Consequences: the
  golden digests are valid for the `-O` test build only (debug app builds compute slightly different Enhanced
  spectrogram bits than release builds), and the magnitude of the difference is not yet known. Recommended: measure
  it and document the golden digests as optimization-level specific.

### Verification that was not possible here

Plugin builds and DAW runs (no VST3 SDK; REAPER e2e scripts not run); a real device sample-rate change (global
setting); output taps (System Audio Recording permission); ThreadSanitizer on the Swift core checks (does not finish
in practical time); a full manual UI pass (popovers, drag interactions, windows, full screen) beyond the self-tests and
snapshots above; packaging and installer dry runs.

## 5. P0 review

| | Status now | Evidence (re-run for this review) |
|---|---|---|
| **P0-1** capture slice refused or too long → silent loss | **Open, confirmed.** No change since Phase 2. | `Tests/Probes/capture-render-probe.sh 153`: control 188 slices, 96,256 frames; rate mismatch 96 kHz: 47/47 slices refused (OSStatus −10863), 0 frames, 0 dropped, 0 break marks; 44.1 kHz: 23/23 refused, same. `CaptureCallback.c`, `AudioCapture.swift` unchanged since `a11b325`. Characterization test still passes as "known issue". |
| **P0-2** tap multi-stream truncation | Open, P2 (unreachable with this machine's devices) | Characterization test still pins 8 of 12 frames kept, no mark |
| **P0-3** plugin ring swap | Open, P2 hardening (no reachable race under VST3/AU contracts) | `BridgeCore.cpp`, `RecordRing.h`, VST3/AU wrappers unchanged; transport TSan 0 warnings |

Remaining correctness/concurrency risks: P0-1 (silent capture loss around device rate changes); R2 (build-mode-
dependent Enhanced spectrogram bits); Swift 5 language mode with 60 `MainActor.assumeIsolated` (P2-4) unchanged; the
`MeterExchange` single-consumer rule is documented (`AGENTS.md`) but not enforced.

## 6. Performance comparison (release builds, alternating runs, nothing else running)

| Benchmark | Build 119 (unrefactored) | Refactored | Verdict |
|---|---|---|---|
| `--benchmark-dsp` stereo pipeline, one-core % (median of 3) | 1.215 | 1.209 | equal |
| Spatial, no field | 2.862 | 2.861 | equal |
| Spatial, field built | 4.244 | 4.225 | equal |
| Spatial, field + multi-resolution observations | 4.163 | 4.157 | equal |
| DSP benchmark checksums | −6886.990 | −6886.990 | identical |
| Soundstage stage render 9.1.6, CPU p50 / GPU p50 (3 runs) | 0.34–0.40 / 1.08–1.75 ms | 0.34–0.35 / 1.06–1.13 ms | equal within run-to-run spread |
| Shader pipeline build, warm | 50–54 ms | 48 ms | equal (the 11 size checks cost nothing measurable) |
| Multi-FFT engine, 20 configurations summed (2 runs each) | 8.335 % | 8.323 % | ratio 0.999 |
| Signal health, 60 s stereo | 37.15 ms | 37.00 ms | equal |

Not measured: whole-app CPU in the window over time (the `output/build117/cpu-ab.sh` method), memory footprint, launch
time end to end.

## 7. Maintainability assessment

- **Better:** navigation (no source file above 2,100 lines; the panel, scene and setting a change concerns are now
  findable by file name), single sources of truth for the frequency axis, keys and flags, written and tested
  contracts (snapshot, shader structs, axis), agent instructions, a one-command check, and per-batch traceability.
- **Unchanged:** the model is still a 1,800-line hub; diagnostics and self-tests still ship in the app; concurrency is
  still annotated by convention; tests still rely on hand-maintained source lists; no CI.
- **Net:** a clear, low-risk improvement. The campaign stayed within mechanical, verifiable changes; the harder
  structural work (model decomposition, concurrency, per-frame configuration) is now easier to start but not begun.

## 8. Remaining high-risk architecture problems

1. **Capture failure is invisible** (P0-1): no break, count or status when the IO callback cannot render.
2. **`MeterModel` concentration** (P1-3): capture lifecycle, Bridge, routing, Multi-FFT, geometry and status in one
   main-actor object with no model-level tests.
3. **Concurrency by convention** (P2-4): Swift 5 mode; `assumeIsolated` traps if a callback ever arrives off main.
4. **Verification gaps around the plugins**: no SDK build or DAW run in this environment; P0-3 hardening untested.
5. **Process risk:** two uncommitted copies of Build 119 and ~60 uncommitted files in the maintenance worktree.

## 9. Release readiness

**Not release-ready yet.** The refactoring itself is low-risk and verified equivalent, but before a release:

1. Commit Build 119 on `main` (or a branch) from one copy, then bring the maintenance work in batch by batch (the
   snapshots give per-batch patches); rerun `scripts/check-all.sh` and the golden digests after each.
2. Fix P0-1 (plan in `BASELINE_2026-10.md`, section 6) and turn its characterization test around.
3. With the VST3 SDK: build the plugins, run `Bridge/scripts/e2e-reaper*.sh` and the plugin self-test.
4. Manual checks: a real device sample-rate change while capturing; output taps; a manual UI pass; packaging and
   installer dry run with the usual delivery scripts.

## 10. Recommended priorities

**Phase 4 (correctness and safety net):**
1. P0-1 fix (and P0-2 in the same change).
2. CI: `scripts/check-all.sh` on a macOS runner, plus a step that compiles the Metal library (`--render-preview`) so
   R6 is caught by the pipeline.
3. Fix R1 (freeze the frame-rate readout while paused, or exclude it from the check) so `--test-pause-resume` is a
   usable regression test again.
4. R2: measure the Enhanced spectrogram's `-O` vs `-Onone` difference; document golden digests as `-O`-specific (or
   record a second set).
5. Model-level tests with a fake `MeterWorker` (now possible after C05); a SwiftPM test target for `AnalysisCore`.

**Phase 5 (structure, once Phase 4 is in place):**
1. `MeterModel` decomposition (P1-3), batch by batch, under the new model tests.
2. Shared hover readout (P2-2).
3. Typed settings accessors and the rest of P2-3 (including `SettingsBackup.keys`).
4. `AuraliscopeApp.swift`, `PanelPlacement.swift`, `NebulaScene.swift` splits; tidy R3 imports.
5. `@MainActor` / Swift 6 for `AnalysisCore` first (P2-4); P1-4 per-frame configuration with a CPU A/B.
6. `Bridge/ARCHITECTURE.md` rewrite; P0-3 hardening with a HostHarness TSan stress test; P2-8 export scale.

## Appendix: where the evidence is

All under `output/` in the maintenance worktree (git-ignored): `review/check-all.txt`, `review/core-checks.log`,
`review/selftests/*.log` (including the A/B pause/resume and source-switch logs), `review/perf/*` (DSP, stage and core
benchmark logs), `review/p0-1-probe.txt`, `review/transport-tsan.log`, `review/core-asan.log`; campaign snapshots in
`campaign/snapshots/`. Build 118 comparison logs are in `review/b118/` (`b118-normal.log`,
`b118-asan.log`, `b118-onone.log`).
