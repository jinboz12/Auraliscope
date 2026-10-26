# Phase 6 final report: correctness fixes and release hardening

Branch `maintenance/phase6-correctness`, based on `a69c30e` (the verified Phase 5 HEAD), in its own worktree. Four
batches, all used. Local commits only: nothing was pushed, merged, tagged, packaged or released, and the build number is
unchanged. The primary checkout (`main` at `a11b325` with the uncommitted Build 119, diff still `f15f1445ac8eeaa7`), the
maintenance worktree, the Phase 5 worktree and its records, and the branches `main`, `maintenance/commit-series` and
`maintenance/phase5-architecture` were not modified. Chronology: `PHASE6_LOG.md`; state: `PHASE6_STATE.json` (both kept
uncommitted, as in Phase 5).

## 1. Root causes

**A. Ambiguous restoration lasted one poll.** When restoration bound a new instance of the saved insert
*provisionally* (rule 2, after the settle delay), `MeterModel.startBridge` called `BridgeLink.remember` as it does for
every results stream. That replaced the saved selection, in memory and in the stored `bridgeSelection`, with the
provisional instance and its live session. When a copy then made the choice ambiguous, `becomeAmbiguous` stopped
analysis, but on the next poll `BridgeLink.findSaved` applied rule 1 ("the saved session is connected: the same live
insert") to that instance and bound it again, for good, also recording the copy as known. The rule "never choose
between inserts by chance" was broken one poll after it applied.

**B. A paused plugin left behind was never resumed.** `MeterModel.stop()` set `paused = nil` and then tested
`paused != nil` before sending RESUME, so the branch was dead. Leaving a plugin whose measurement this display had paused
(another insert, a device, a stop, or a resume after the plugin's format changed while paused) left that plugin's
measurement paused, for every display, until its own window resumed it or the connection broke (the plugin resumes by
itself on disconnection).

## 2. Behaviour changes

**A** (`c7a32eb`). `BridgeLink.attached(_:)` replaces the call in `startBridge`: the insert is remembered only when the
choice is final. A provisional choice is saved once it holds through its 5 s provisional span (`checkBound`, as
before). `remember` is now private to `BridgeLink`. Result: ambiguity lasts until the person chooses (source list or the
plugin window's button) or the connected inserts change so that restoration finds a single claimant (a copy goes away,
the saved live insert returns). Nothing else changes: the selected insert reconnecting still carries on at once through
`followBound`, provisional or not. (The `c7a32eb` commit message says otherwise about that reconnection; a trace in
batch C showed the message was wrong and the code path unaffected. Corrected in the batch C commit message and the log.)

**B** (`8a167fd`). `PausedSession.pluginPaused` records whether the PAUSE reached the plugin (the command was queued).
`stop()` reads the paused insert before clearing the session and sends RESUME once, after detaching results and before
any other insert is subscribed. Ownership rule: this display resumes a plugin exactly when its own PAUSE reached it and
it lets go of that paused session without resuming it in place. Not sent: when the PAUSE never went out (the insert was
disconnected at the pause), when the connection has since broken (the plugin resumed by itself; there is nothing to
send to), or twice (a resume in place clears the session first). Resuming on the same insert is unchanged. No protocol
change: PAUSE and RESUME are existing, idempotent commands, queued per connection; `abr_server_select` does not drop
them.

No other behaviour changes. Batches C and D are a test and a document.

## 3. Regression tests

All in `--test-model-lifecycle` (`scripts/check-model.sh`), run with stand-ins for devices, capture and plugins.

| Batch | Checks | What |
|---|---|---|
| A | KNOWN ISSUE replaced; +6 | Provisional choice not saved; ambiguity holds past the settle delay (no subscription, candidates and saved choice unchanged); the copy leaving re-finds the only claimant; a provisional insert reconnecting carries on and stays provisional; the person's choice ends it with the copy known; the known-copy section also checks the saved selection before and after the provisional span |
| B | KNOWN ISSUE replaced; +12 | The stand-in receiver records each command's target. One RESUME to the paused insert when a focus request moves to another; same-insert pause/resume; another insert chosen while paused (nothing until capture starts, then RESUME before the new subscription); stop while paused, a second stop, the fresh start; format change while paused; connection broken while paused; a pause that never reached the plugin |
| C | +15 | Twenty quick device switches; ten pause/resume cycles on a device and on a plugin; quick plugin/device switches; a plugin lost and back five times; two holders of the saved identity, the saved live insert's return; three failed starts; Multi-FFT across quick switches and its delayed stop |

Lifecycle checks: 127 (Phase 5: 94). Every new check in A and B failed on the code before its fix (A: the persistence
check, then, with it skipped, the ambiguity-hold check; B: the replaced check, then "starting on the other insert resumes
the paused one"). Mutations: B's "ignore whether the PAUSE went out" caught; C's "analysis not stopped" and "ambiguity
re-applied every poll" caught; C's "a returning held insert always restarts" **not caught**, because `bind` is never
called with a held analysis to continue (section 8).

## 4. Local commits

```
c7a32eb fix(app): keep a provisional DAW plugin choice from rebinding itself when ambiguous
8a167fd fix(app): resume a paused DAW plugin's measurement when the paused source is left
8be8ef6 test(app): transition checks for quick switching, repeated pauses, plugin loss and Multi-FFT
1dc3a66 docs(maintenance): capture recovery proposal for sustained refusal (P0-1)
```

This report is committed after them (documentation, not a batch). Each commit's tree is the tree that was verified.

## 5. Test results

Final code state (`8be8ef6`; the two later commits are documents):

- `scripts/check-all.sh`: 9/9 (build-debug, shaders, core-checks, build-release, app-features, file-analysis,
  bridge-analysis, spatial-report, bridge-transport).
- `scripts/check-model.sh`, three consecutive runs: `--test-model-worker` 14/14, `--test-model-lifecycle` 127/127.
- QA self-tests (`output/phase6/qa-suite.sh`, documented invocations): settings-presets 10 (Multi-FFT opt-in
  precondition), settings-draft 13, multifft-layout 36, pause 11, model-worker demo and live 14, model-lifecycle 127,
  spectrum-average, peak-reset, nebula-gpu, spatial-projection; Multi-FFT hidden by default in a fresh preference
  domain.
- Sanitizers: AddressSanitizer and ThreadSanitizer builds of the app (runtimes confirmed linked) run both model
  self-tests with no reports; `Bridge/scripts/test-transport.sh` under ThreadSanitizer and AddressSanitizer: all checks
  pass, no reports. Not run: `scripts/test.sh` under a sanitizer (no Phase 6 change reaches the analysis core; its
  Enhanced golden differs under ASan by design).
- Batches A and B each passed the same full suite before their commits (`check-all` 9/9, model checks twice, QA suite).

Against the Phase 5 baseline (`a69c30e`): the same steps pass, with the same counts except the lifecycle self-test
(94 → 127).

## 6. Numerical and performance equivalence

No change reaches the DSP, the analysis core, the ring, the capture callbacks, the snapshot layout or the plugin. The
golden pipeline digests are bit-identical (core checks pass). The code changes are on the main thread's control path: a
Boolean stored at a pause and an optional read in `stop()` (B), one condition before remembering an insert at a stream
start (A). No performance measurement was made; none of these runs per frame or per audio buffer.

## 7. Hardware- and DAW-dependent checks not run

None of these was treated as passed:

- Both fixes against a real DAW with real plugins:
  - restoration with copies (a duplicated track, a project opened twice);
  - pause in Auraliscope, then switching inserts, with the plugin window open.
- The plugins themselves: VST3/AU builds, `HostHarness` and the REAPER end-to-end tests. The VST3 SDK is not present.
- Live capture:
  - microphone and interface permission;
  - a sample-rate change while capturing;
  - IO sizes above 4,096 frames.
- Output taps with System Audio Recording.
- `--capture-selftest` and `capture-render-probe.sh` on a loopback device.
- `--test-pause-resume` on a live input, and `--test-panel-drawing` run from a terminal.
- The first GitHub CI run.

## 8. Remaining P0 concerns and findings

- **P0-1 sustained refusal**: still no recovery; a proposal is in section 9, not implemented.
- **P0-1 in the app**: a real device rate change was never made, so the notification path's latency is unmeasured.
- **P0-2**: covered by accounting only; it cannot be reached on this hardware.
- **P0-3**: hardening only (unchanged).
- **Findings from batch C** (not changed here):
  - `MeterModel.bind`'s branch for continuing a held analysis appears unreachable. The selected insert's return goes
    through `followBound`, and every path that moves the selection off an attached insert stops it first. Candidate
    for removal in a later cleanup.
  - With the Multi-FFT panel hidden, frames re-arm the delayed stop, so the analysis is sent a `nil` configuration
    about every 0.4 s. `DSPWorker` ignores an unchanged value, so this is harmless.
- **Residual edge of B, by design**: a display may resume a pause made in the plugin window. This happens only if the
  connection broke after this display's pause, the plugin then resumed itself, and the person paused it in its window
  before leaving the insert here. The protocol allows a display to resume a window pause.
- **Earlier phases' open items**:
  - the maintenance series and Phases 5–6 are local branches only;
  - integration into the release line, and the primary checkout's uncommitted Build 119, need a decision.

## 9. Capture recovery proposal

`docs/maintenance/CAPTURE_RECOVERY_PROPOSAL.md` (design only).

**The problem.** Today, a capture whose every IO cycle fails is counted and marked, but only a Core Audio
notification ends it.

**How failures are recorded and detected.**
- The IO callback records failed slices (kind, OSStatus, run length) with relaxed atomics. It sends no signal; the
  main thread's 10 Hz readout reads the record.
- A pure policy treats a run as sustained after 1 s and at least 3 slices.

**How a failure is classified.** The policy reads the device's state:
- **Sample-rate mismatch:** a fresh analysis, as the rate notification does today.
- **Slices too long for the storage:** restart capture with larger storage, keeping the analysis across one marked
  break.
- **Device gone:** handled by the existing device-list path.
- **Unknown refusal:** restart capture alone.

**Limits on restarts.**
- At most 3 attempts per episode, at 0, 2 and 8 s.
- Notification restarts are coalesced within 250 ms and count against the same budget.
- One pending attempt at a time, tagged with the capture generation, so anything that restarts or stops capture
  cancels it.
- Never while paused or stopped, in demo mode, or for a plugin source.
- After the budget: a visible failure, and Start Capture retries.

**Accounting and tests.** Break accounting stays as it is, and restarts never run on the IO thread. The proposal also
separates what can be tested deterministically from what needs hardware.

**Order.** Implement the policy as separable pieces first, validate it live, then extract `CaptureSession`.

**Decisions it needs:**
1. Approval to implement it, including new status text in six languages.
2. Approval for a real rate change on an idle loopback device, to measure notification latency.
3. Confirmation that a capture-only recovery keeps the analysis.

## 10. Release readiness

**Not release-ready.** The two confirmed behavioural defects are fixed, and their fixes are covered by checks that
failed before them. The automated suite is green, with wider transition and sanitizer coverage than at Phase 5. But
passing automated checks prove only what the stand-ins model. These still block a release:

1. P0-1 sustained-refusal recovery is undecided and unimplemented (section 9).
2. Live capture, device, plugin and DAW validation (section 7) has not run. That includes both fixes in a real DAW.
3. The work exists only on local branches:
   - the maintenance series, Phase 5 and Phase 6;
   - the uncommitted Build 119 in the primary checkout.

   How these reach the release line needs a decision.
4. CI has never run on GitHub.

**Recommended next steps:**
1. Run the live DAW checks for A and B, and the capture checks in section 7, from a terminal.
2. Decide on the capture recovery proposal; if approved, implement it as described and validate it on hardware.
3. Extract `CaptureSession`.
4. Decide the branch integration plan, and run CI.
