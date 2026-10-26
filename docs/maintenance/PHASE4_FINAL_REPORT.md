# Phase 4 final report: correctness hardening and engineering infrastructure

Status: **six batches completed; not release-ready.** Nothing is committed, pushed, packaged, tagged or renumbered.
Working copy: `<maintenance worktree>` (branch `maintenance/p0-baseline`, base `a11b325`).
Primary checkout `<primary checkout>` is unchanged (Build 119 diff still hashes `f15f1445ac8eeaa7`).
Full chronology: `PHASE4_LOG.md`; machine-readable state: `PHASE4_STATE.json`.

## 1. Completed batches

| Batch | Work | Outcome |
|---|---|---|
| Start | Source-of-truth check; checkpoint `output/campaign/snapshots/phase4-start` | Worktree chosen as working copy: it holds Build 119 plus Phases 2–3 and all baseline tests. Primary checkout kept as Build 119 reference. |
| A | P0-1 and P0-2 capture losses | Fixed: lost capture frames are counted and marked as a break. |
| B | CI and shader verification | Added `--check-shaders`, `scripts/check-shaders.sh`, a shader step in `check-all.sh`, and `.github/workflows/ci.yml` (not yet run on GitHub). |
| C | Pause self-test | Test corrected: compares the meter canvases only; the live frame-rate readout is not frozen. |
| D | Enhanced spectrogram numerics | Investigated; acceptable numerical variation; no code change. |
| E | MeterModel regression checks | 14 checks with a recording worker (`--test-model-worker`). |
| F | P0-3 investigation, low-risk cleanups | New reconfiguration stress check under TSan (0 warnings); scene imports cleaned; AGENTS.md list guidance corrected. P0-3 stays hardening. |

## 2. Confirmed correctness fixes

**P0-1 (capture refusal and oversize slices).** Root cause, reproduced: while a device's rate differs from the capture format,
`AudioUnitRender` refuses every slice (−10863). The callback wrote nothing and recorded nothing. The audit's buffer-size trigger
was not reproduced (buffer sizes are per process, capped at 4096 here).
Fix (`Sources/AudioRing/AudioRing.c`, `CaptureCallback.c`, `AudioRing.h`): new producer call `channel_ring_lose`. Lost frames
count as dropped at once, and the break is marked where the next written frames start. Consecutive losses form one break.
Verified: 96,256 and 94,208 frames counted on the two refusal runs of `capture-render-probe.sh 153` (were 0); control run has no loss.

**P0-2 (output-tap truncation).** A tap delivery longer than the storage kept its first frames and dropped the tail silently.
Fix: the tail is lost through the same path, after the kept frames. Channel order checked by test.

### Intentional behaviour changes (for release notes)
1. Dropped-frame count now includes frames a capture could not deliver (refused, too long for storage, cut-off tail). The status bar's
   dropped figure and the "Dropped audio frames" log rise during a refusal.
2. A loss followed by audio is one break at the resume point, with the lost frames as missing seconds. Before, the analysis saw a stall.
3. Restart policy is unchanged: capture still restarts only on device rate and alive changes. A refusal with no following audio is
   counted, not marked, until audio resumes.
4. A restart clears pending losses with the ring; the dropped count carries across restarts as before.

## 3. Remaining P0 risks

| Item | Status | Why it is not closed |
|---|---|---|
| P0-1 sustained refusal | Counted, but no break and no restart while it lasts | Needs a restart-policy decision (when to restart a refusing capture). Not changed here. |
| P0-1 in-app rate change | Not verified in the app | A real global device rate change was not made (needs approval). The probe reproduces the mechanism with a loopback device. |
| P0-1 oversize slices | Covered by accounting; trigger not reproduced | Would need AUHAL slices above 4096 frames (AUHAL reports `MaximumFramesPerSlice` 7,527 in the probe). |
| P0-2 | Covered by accounting | Reachable only with a tap IO size above 4096; none here. |
| P0-3 ring swap | Hardening, not a reproduced defect | New reconfiguration check passes under TSan. Overlapping configure with process is caught by the frame count, not TSan; the TSan-visible interleaving is not reached (see Batch F log). Hardening: publish the ring through an atomic pointer (audit). |

## 4. Test and CI results

- **Full suite, `scripts/check-all.sh` (final, after all batches): 9 of 9 steps pass, exit 0**
  (`output/phase4/final-check-all.txt`): build-debug, shaders, core-checks, build-release, app-features, file-analysis,
  bridge-analysis, spatial-report, bridge-transport.
- Core checks: 61 checks passed; 86 PASS lines (includes 4 new capture-loss checks and the 5 golden pipeline scenarios, bit-identical);
  924 localization keys in six languages.
- Plugin transport: 110 checks ok (includes the new reconfiguration check: 200 reconfigurations, 819,200 frames, none lost);
  plugin analysis: 169 checks ok; ThreadSanitizer transport run: 0 warnings.
- Shader check (`--check-shaders`): library and every pipeline built. Mutation test: a wrong struct size fails with the named static assert.
- Self-tests (QA bundle, demo mode where noted): pause and resume 11/11 (twice); model worker 14/14 (demo and live launch,
  repeated); spectrum-average, peak-reset, nebula-gpu pass.
- Self-test with an environment problem: `--test-panel-drawing` 9/11 in this shell session, the same 9/11 on the build from
  before the import cleanup (`output/phase4/batchF-panel-before-import-change.log`). The two failing checks are window-state
  dependent (revealed and minimised window). The review recorded 11/11 from a terminal. Re-run from a terminal before release.
- CI: `.github/workflows/ci.yml` (`macos-15`, runs `scripts/check-all.sh`). Parsed (YAML), not run on GitHub. Unknown:
  Metal availability on the runner (the check exits with status 77 and check-all reports `skip` without it; that path was not exercised here) and whether its Swift toolchain builds the
  package (tools 6.0). First run decides.
- Not in CI: live capture, device and plugin tests (hardware and DAW), rendering self-tests.

## 5. Enhanced spectrogram numerical findings

Full report: `ENHANCED_SPECTROGRAM_NUMERICS.md`. Summary:
- `-O` against `-Onone`: mean error ≤ 2.3e-3 dB; RMS ≤ 0.24 dB; at most 5 of 30,720 cells above 1 dB per signal. The largest
  errors (up to 41 dB) are single weak cells at the −120 dB floor.
- Cause: at `-O` LLVM fuses `sin` and `cos` of one argument (`sincosf`) in the Hann-window loop of `ReassignedSpectrogram`.
  Splitting the loop in a scratch copy makes `-O` bit-identical to `-Onone` (all five signals), and the ASan build (which
  blocks the fusion) matches `-Onone` too.
- C kernel optimisation level and FP contraction make no difference. The same binary is repeatable.
- Decision: acceptable numerical variation (both builds are within one ulp of the window reference). No algorithm change;
  optimised golden digests stay. The ASan Enhanced golden failure (R2) is expected and explained.

## 6. MeterModel regression coverage

Added: `setWorkerForTesting` seam and `--test-model-worker` (14 checks). Covered: settings propagation at each display frame
(spectrogram mode, Enhanced analysis, spatial spectrum, nebula threshold), true-peak reset, Multi-FFT start and teardown,
stop, worker replacement, no-worker frame.
Not covered (need a running capture or device): source switching, capture start and restart, pause and resume, bridge (DAW)
waiting and fallback, failure recovery, Multi-FFT on a bridge source. Also found: the model's launch work replaces a worker attached early;
the seam now stops capture and the test waits 1.5 s.

## 7. Hardware or DAW validation still required

- Live capture pause test (`--test-pause-resume --input-device <id>`): cannot run from the tool shell (microphone permission belongs to
  the launching process). Passed in the Phase 3 review from a terminal.
- Real device sample-rate change while capturing (P0-1 in the app), and a real buffer-size change above 4096 frames.
- Source switching, bridge (DAW) waiting and fallback, Multi-FFT on a bridge source.
- Plugin: VST3/AU builds, `HostHarness` and REAPER tests (VST3 SDK not present in this checkout); P0-3 in a real host.
- Manual UI pass of the status bar and the panels; the rendering self-tests from a terminal session.
- First GitHub CI run, including Metal availability on the runner.

## 8. Release blockers

1. Nothing is committed. Build 119 and Phases 2–4 exist in the worktree; the primary checkout still holds Build 119 alone.
   A commit plan and a decision on which copy is the source of truth are needed.
2. Restart policy for a sustained capture refusal (P0-1) is undecided.
3. Live capture, device and plugin validation (section 7) has not run here.
4. The panel-drawing self-test shows 2 env-dependent failures in this shell; re-run from a terminal.
5. CI has never run on GitHub.

## 9. Readiness for Phase 5

**Partly ready.** The worker seam and model checks give regression cover for the worker interface, so a decomposition can
now be checked for those parts. Before the model's capture lifecycle, source switching, bridge waiting and pause/resume are
split out, the live tests in section 7 must be run, because the current checks cannot see those paths. Recommended order:
1. Decide the commit plan and restart policy (blockers 1–2).
2. Run the live tests from a terminal (section 7) and the panel-drawing self-test.
3. Start Phase 5 with the `MeterModel` capture-lifecycle split, adding the missing model checks first.

## 10. Files changed in Phase 4 (worktree, uncommitted)

- Capture loss accounting: `Sources/AudioRing/AudioRing.c`, `CaptureCallback.c`, `include/AudioRing.h`; `AGENTS.md`.
- Shader check: `Sources/Auraliscope/ShaderCheck.swift` (new), `Diagnostics.swift` (dispatch, pause test, self-test list),
  `scripts/check-shaders.sh` (new), `scripts/check-all.sh`, `.github/workflows/ci.yml` (new).
- Model checks: `Sources/Auraliscope/ModelWorkerSelfTest.swift` (new), `MeterModel.swift` (seam and call).
- Tests: `Tests/AuraliscopeTests/BaselineChecks.swift` (capture-loss checks replace the KNOWN ISSUE characterisations),
  `Bridge/Tests/TransportTests.cpp` (reconfiguration check).
- Numerics probe: `Tests/Probes/EnhancedNumerics.swift`, `enhanced-numerics.sh`, `compare-numerics.py`, `analysis-sources.py` (new).
- Cleanup: imports in `SpectrumScene.swift`, `SpectrogramScene.swift`, `WaveformScene.swift`, `SoundstageScene.swift`.
- Docs: `docs/maintenance/PHASE4_LOG.md`, `PHASE4_STATE.json`, `ENHANCED_SPECTROGRAM_NUMERICS.md`, this report.
