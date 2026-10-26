# Maintenance baseline and P0 validation (Phase 2, 2026-10-24)

Phase 2 of the maintenance plan in [CODE_AUDIT_2026-10.md](CODE_AUDIT_2026-10.md): isolate the work from Build 119,
re-check the three P0 findings against evidence, record a regression baseline, and add focused regression tests.
**No production code, DSP implementation or app behaviour was changed in this phase.**

## 1. Isolation from Build 119

| | State |
|---|---|
| Build 119 | Uncommitted in the main checkout (`<primary checkout>`, branch `main` at `a11b325`): 15 modified files (UI, settings, localization, one test), plus untracked docs. **Untouched by this phase**: nothing stashed, committed, reset or overwritten. |
| Safety copy | `output/build119-wip-backup/` in the main checkout (git-ignored): `build119-tracked.patch` (2,251 lines, SHA-256 `f15f1445…0134914`), the porcelain status and the base commit. Read-only backup; restore with `git apply` only if ever needed. |
| Maintenance work | Separate worktree `<maintenance worktree>` on the new branch `maintenance/p0-baseline`, from `a11b325` (the commit Build 119 sits on). Nothing here is committed yet. |

Why this shape: the maintenance branch starts from the same commit as Build 119, and the files it touches
(`Tests/AuraliscopeTests/BaselineChecks.swift`, `Tests/Probes/`, `Tests/Fixtures/`, `docs/maintenance/`, a two-line
hook in `scripts/test.sh` and one line in the core test runner) do not overlap Build 119's hunks. Build 119 does
change `Tests/AuraliscopeTests/CoreTests.swift`, in its tilt test far from the runner, so the two merge without
conflict either way. A P0 fix lives in `Sources/AudioRing/` and `AudioCapture.swift`, which Build 119 does not touch.

**Build 119 in the maintenance worktree (Phase 3 start).** At the user's request to continue on Build 119, its
backed-up patch (hash re-checked against the live diff: identical) was applied to the maintenance worktree with
`git apply`, uncommitted. The main checkout still holds the original, unchanged. While both exist, make further
Build 119 edits in one place only (the maintenance worktree from now on), or re-sync before merging.

Recommended order once Build 119 is approved: commit Build 119 on `main` (or a `build-119` branch), then rebase or
merge `maintenance/p0-baseline` onto it and rerun the baseline (the golden digests must not move: Build 119 changed no
analysis code).

## 2. Regression baseline

Environment: macOS 27.2 on arm64 (Apple silicon), Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode toolchain; no VST3
SDK fetched (`Bridge/ThirdParty` absent).

Committed tree (`a11b325`, clean), then the same tree with Build 119 applied (section 1, step "Build 119 in the
maintenance worktree"):

| Step | Command | `a11b325` | + Build 119 |
|---|---|---|---|
| Debug build | `swift build` | pass (43 s) | pass |
| Release build | `swift build -c release` | pass (84 s) | not rerun |
| Core checks (61), kernels, localization | `scripts/test.sh` | pass: 61/61, kernels 0 failures, 901 keys | pass: 61/61, 924 keys |
| New baseline checks | `scripts/test.sh` (BaselineChecks) | pass; golden recorded | pass; **golden bit-identical** |
| Core checks under ThreadSanitizer | `scripts/test.sh thread` | **not completed**: 17 checks passed, then stopped after 9 min in the 100,000-publication exchange test (≈40 GB of instrumented `memcpy`) | not run |
| Bridge analysis (StreamAnalyzer ≡ desktop pipeline, breaks, RESULT) | `Bridge/scripts/test-analysis.sh` | pass | pass (main checkout) |
| Bridge transport, UBSan | `Bridge/scripts/test-transport.sh` | pass | not rerun (no Bridge change) |
| Bridge transport, ThreadSanitizer (C/C++ parts) | `ABR_SANITIZE=thread Bridge/scripts/test-transport.sh` | pass, 0 TSan warnings | not rerun |
| App feature checks (updates, render policy, Dock layout) | `scripts/check-app-features.sh` | pass | pass (main checkout) |
| Multichannel capture end to end | `.build/release/Auraliscope --capture-selftest 153` (idle Pro Tools Audio Bridge 16) | pass: 16 roles, reversed routing, two roles on one input, one role off, 14 channels delivered through the channel map | not rerun (no capture change) |
| P0-1 probe | `Tests/Probes/capture-render-probe.sh 153` | reproduces (table in section 3) | n/a |
| Golden sensitivity (mutation) | temporary +1e-7 in `SpectrogramAnalyzer` row centre, then restored byte for byte | **caught**: `spectrogram` group changed in the 3 scenarios using that path; nothing else | n/a |

Logs: `output/baseline-2026-10-24/` in the maintenance worktree (git-ignored).

### What the existing suites cover (and what they do not)

- **Strong:** loudness (EBU Tech 3341/3342 conformance, K-weighting across rates, LFE exclusion, channel weights to
  9.1.6), true peak (boundaries, near Nyquist, dense mixtures), spectrum and spectrogram calibration (classic,
  reassigned, Multi-FFT, shared STFT), stereo bands, spatial field and observations, ring concurrency and the
  exchange's tearing, StreamAnalyzer equivalence with the desktop pipeline, the Bridge transport.
- **Now added:** bit-exact pipeline output across five scenarios, the snapshot layout contract, routing through the
  ring into the pipeline, and the two capture known issues.
- **Still not covered by automated tests:** the model (`MeterModel` source switching, pause/resume, restart after a
  device change), Metal uniform layouts, UI layout and drawing beyond the app-feature checks (the app's
  `--test-*` self-tests exist but need a visible window and run by hand), plugin hosting in real DAWs (needs the
  VST3 SDK and a host session), and capture under a real device rate change.

## 3. P0 re-evaluation

| | Original claim | Verdict | Evidence | Severity if triggered | Likelihood | New priority |
|---|---|---|---|---|---|---|
| P0-1 | Capture stops silently when the IO buffer outgrows the storage | **Confirmed and reproduced, cause corrected** | Probe with the app's own callback (below); unit characterization test | Medium-high: audio lost with no break, no count, no status | High for the transient (every device sample-rate change while capturing); low for a lasting stall | **P0** (fix first) |
| P0-2 | Output tap truncates oversize deliveries without a mark | Confirmed at unit level, not reachable here | Characterization test; every device here caps IO at 4,096 frames, the storage minimum | Low | Negligible on current hardware | P2 |
| P0-3 | Plugin swaps its ring under a host-contract assumption | Not reproducible under the formats' contracts | Code: `process` touches the ring only when `active_`; `configure` runs only while inactive | High (host crash) | Very low: needs a host that breaks the VST3/AU contract mid-block | P2 hardening |

### P0-1: what is actually wrong

The audit's trigger was refuted, and a real one found:

1. **Buffer-size trigger refuted.** `kAudioDevicePropertyBufferFrameSize` is per process: with one process holding
   BlackHole 16ch at 2,048 frames, a second process read 512 at the same moment
   (a two-process check with a throwaway tool, restored afterwards). A DAW changing its buffer cannot change
   Auraliscope's. Every input device on this Mac also caps its range at 4,096 frames (Zoom at 768), and the app's
   storage is never smaller than 4,096.
2. **Real trigger: a sample-rate mismatch.** When the capture format's rate differs from the device's, AUHAL calls the
   input callback with device-sized slices that fit the storage, and `AudioUnitRender` refuses every one with
   OSStatus −10863 (`kAudioUnitErr_CannotDoInCurrentContext`). Auraliscope is in exactly this state from the moment a
   device's nominal rate changes until its capture restart (`HardwareObserver` → main queue → `refreshDevices` →
   `restart`, [MeterModel.swift:800](../../Sources/Auraliscope/MeterModel.swift)).
3. **Why it matters.** The callback returns the error and writes nothing
   ([CaptureCallback.c:9–17](../../Sources/AudioRing/CaptureCallback.c)): no ring mark, no dropped-frame count, no
   status. That breaks the documented continuity contract ("every break is counted, with the time known missing",
   `MeterPipeline`). The meters fall silent while the status still says capturing. Usually the restart ends it
   (and clears the measurement anyway). If a restart does not follow (selection changed during `refreshDevices`, a
   driver that does not post the rate change, a failed restart), capture stays silent with no diagnostic at all.

Reproduction (`Tests/Probes/capture-render-probe.sh <device>`, the app's `capture_input_proc` and `ChannelRing`
behind an AUHAL, 2 s per run, idle loopback input, nothing changed outside the probe's process):

| Run | Device rate | Capture format | IO buffer (this process) | Slices | Refused | Frames in ring | Dropped | Break marks |
|---|---|---|---|---|---|---|---|---|
| Control | 48 kHz | 48 kHz | 512 | 188 | 0 | 96,256 | 0 | 0 |
| Mismatch | 48 kHz | 96 kHz | 2,048 | 47 | 47 (−10863) | 0 | 0 | 0 |
| Mismatch | 48 kHz | 44.1 kHz | 4,096 | 23 | 23 (−10863) | 0 | 0 | 0 |

Every refused slice fits the 4,096-frame storage: the refusal comes from `AudioUnitRender`, not from the size check.

What was not verified: the length of the window in the real app after a real device rate change (it needs a global
sample-rate change on a device, which this phase did not make without approval); see section 5.

### P0-2: why it is downgraded

`capture_tap_io_proc` clamps a multi-stream delivery to `max_frames` and drops the rest with no mark or count
([CaptureCallback.c:49](../../Sources/AudioRing/CaptureCallback.c)); the new characterization test reproduces it
(8 of 12 frames kept, 0 marks, 0 dropped). It needs a tap IO size above the storage, which is at least
max(4,096, 2 × the IO buffer at start); every device here caps at 4,096. The single-stream path (the usual one for a
tap) is unaffected: the ring counts its own overflow. Fix it together with P0-1 (same function family), not first.

### P0-3: why it is downgraded

`BridgeCore::growRing` swaps `ring_` while the audio thread may dereference it
([BridgeCore.cpp:236](../../Bridge/Plugin/Core/BridgeCore.cpp)). Two independent guards make that unreachable for a
host that follows its format's contract:

- `configure` (and so `growRing`) is called only from VST3 `setActive(true)`
  ([BridgeVST3.cpp:170](../../Bridge/Plugin/VST3/BridgeVST3.cpp)) and AU `Initialize`
  ([BridgeAU.cpp:46](../../Bridge/Plugin/AU/BridgeAU.cpp)). VST3 forbids `process` while inactive; AU forbids
  render on an uninitialised unit, and AUBase does not re-run `Initialize` on an initialised one.
- `process` returns before touching the ring unless `effectiveState()` is live, which needs `active_`; `active_` is
  false from `setActive(false)` / `Cleanup` until after `configure` has finished
  ([BridgeCore.cpp:281–320](../../Bridge/Plugin/Core/BridgeCore.cpp)).

A crash needs a host that deactivates and reconfigures while a `process` call is already past the `active_` check.
Hardening (publish the ring through an atomic pointer, retire the old one after the analysis thread's next pass) is
cheap and worth doing later, with a HostHarness stress test under TSan; it is not a confirmed defect.

## 4. Regression tests added (no production change)

| Test | Where | Guards |
|---|---|---|
| Snapshot layout | `BaselineChecks.snapshotLayout` | The 20 slot groups tile `METER_SNAPSHOT_FLOATS` in order with their producers' sizes (today only a runtime `precondition`) |
| Golden pipeline digests | `BaselineChecks.goldenPipeline`, `Tests/Fixtures/pipeline-golden.json` | Bit-exact output of `MeterPipeline` per slot group in five scenarios: stereo 48 kHz (pipeline default), the app's shared 4096 STFT with Multi-FFT (curves hashed too), the reassigned spectrogram, 96 kHz with a break, and 7.1.4 through the capture ring with the spatial field on |
| Portable pipeline checks | the same runs | Each role's peak equals the newest 1/30 s maximum exactly; RMS to 1e-5; unrouted roles silent; the ring's scrambled routing preserved bit for bit; one break counted with its missing time; dominant peak on the 63 Hz partial |
| P0-1 characterization | `BaselineChecks.knownIssueCaptureRejectsSilently` | Pins today's silent loss (oversize slice, and a slice `AudioUnitRender` refuses): the fix must turn it into "marked and counted" |
| P0-2 characterization | `BaselineChecks.knownIssueTapTruncatesSilently` | Pins today's silent truncation in the tap's multi-stream path |
| P0-1 probe | `Tests/Probes/capture-render-probe.sh` | Reproduces the refused slices on a real device; reruns after the fix should show marks and counts |

The golden digests are exact for one architecture and toolchain: a compiler or SDK update may change rounding
legitimately. On a mismatch: run the portable checks (they still must pass), review the change, then re-record with
`AURALISCOPE_RECORD_GOLDEN=1 scripts/test.sh` and say why in the commit.

## 5. Verification limits

- **ThreadSanitizer on the core checks did not finish** (section 2). TSan coverage of the Swift analysis is therefore
  limited to the 17 checks before the exchange test; the transport tests' TSan run instruments only C and C++.
  Next step: a TSan target that runs the concurrency checks with fewer iterations.
- **No real device rate change was made.** Changing a device's nominal rate is global (it affects every app using the
  device), so the length of P0-1's window in the real app was not measured. With approval: capture an idle Pro Tools
  Audio Bridge in a `.QA` build with `--diagnostic`, switch its rate in Audio MIDI Setup, and read the log for the
  time to restart and for any "Audio break" line (expected: none today).
- **No plugin or DAW runs.** The VST3 SDK is not fetched (`Bridge/scripts/fetch-sdks.sh` downloads it; not done
  without approval), so the plugins, `e2e-reaper*.sh` and HostHarness were not built or run. P0-3 rests on code
  reading and the format contracts.
- **Output taps not exercised** (System Audio Recording permission); P0-2 is reproduced at unit level only.
- **Golden digests are exact for arm64 and Swift 6.4 only.** Another toolchain may round differently; the portable
  checks are the cross-toolchain guard.
- **Bench numbers** in the core-check logs were taken with other builds running and are not a performance baseline.

## 6. Recommendation

**Fix P0-1 first**, as its own batch, separately from structural refactoring.

Why: it is the only confirmed defect with a realistic trigger (every device sample-rate change while capturing), it
breaks the analysis' continuity contract silently, the fix is small and local to the real-time boundary, and the
characterization test and the probe already exist to prove it.

Plan:
1. In `capture_input_proc`: when the slice is too long or `AudioUnitRender` fails, call
   `channel_ring_mark(ring, reason, frames, 0)` (a new reason bit, for example `CAPTURE_RENDER_FAILED`) and count the
   frames in a new atomic counter on the context. One branch and two stores: no lock, no allocation. Apply the same
   to the tap's truncation (P0-2) in the same change.
2. In the model: read that counter at the readout rate, as `refreshDroppedFrames` does, and log once per episode
   ("capture refused N slices: format/rate mismatch?"). If refusals persist past a short grace period, restart
   capture, as the rate-change listener would.
3. Tests: turn `knownIssueCaptureRejectsSilently` and `knownIssueTapTruncatesSilently` around (a mark and a count
   are now expected); rerun `Tests/Probes/capture-render-probe.sh` (mismatch rows must show marks and counts); the
   golden digests must not move (no analysis change); `--capture-selftest` must still pass; then, with approval, the
   real rate-change check above.
4. Risk: low. The IO callback stays C, lock-free and allocation-free. Watch the break counter in the status bar: a
   mismatch now shows as breaks, which is the intended, visible outcome.
