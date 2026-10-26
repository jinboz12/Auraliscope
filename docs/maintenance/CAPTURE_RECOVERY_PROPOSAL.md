# Capture recovery proposal (P0-1 sustained refusal)

Status: **implemented in Phase 7** (branch `maintenance/phase7-capture-recovery`); `PHASE7_FINAL_REPORT.md` says how
the implementation differs (no work items or coalescing, no buffer-size listener, a capture-only restart that keeps the
ring rather than marking a fresh one). Written in Phase 6, batch D, as design only; code references below are to branch
`maintenance/phase6-correctness`.

## 1. Summary

A device capture can fail on every IO cycle and stay that way: Core Audio keeps calling the input callback, each slice
is refused or too long for the storage, and since Phase 4 every lost frame is counted as dropped and marked as a break
when audio returns. Nothing ends the failure. Recovery today depends entirely on a Core Audio notification (nominal
sample rate, device alive) reaching `HardwareObserver`, which restarts capture; if that notification never comes, comes
for something else, or the restart fails, the meters stay silent while the status still says capturing and the dropped
count climbs.

Proposed: the IO callback records each failed slice (kind, status, run length) in lock-free counters; the main thread's
existing 10 Hz readout reads them; a small, pure policy decides when a failure has lasted long enough, what kind it is
(sample-rate mismatch, slices too long for the storage, device gone, unknown refusal), and whether to restart, wait, or
give up with a visible status and a manual retry. Restarts are bounded (three per episode, backoff 0 / 2 / 8 s), never
run from the IO thread, and are cancelled by anything else that restarts or stops capture. Lost audio stays counted and
marked.

Recommendation on order: implement this policy (as separable pieces) before extracting `CaptureSession`, then do the
extraction under the policy's tests plus the live checks in section 8.2.

## 2. What the code does today

**IO callbacks (real time, C, `Sources/AudioRing/CaptureCallback.c`).**

- Device input (`capture_input_proc`, behind an AUHAL): a slice longer than `max_frames` is lost through
  `channel_ring_lose` and the callback returns `kAudioUnitErr_TooManyFramesToProcess`; otherwise `AudioUnitRender`
  fills the storage, and any non-zero status loses the slice the same way. No other record is kept: the model cannot
  tell a refusal from an oversize slice, how long the failure has lasted, or which OSStatus it is.
- Output tap (`capture_tap_io_proc`, a device IOProc on a private aggregate): never refused by a render call; a delivery
  longer than the storage keeps its first `max_frames` frames and loses the tail (P0-2).
- Storage: `max_frames = max(4096, min(16384, 2 × kAudioDevicePropertyBufferFrameSize))`, read once at start
  (`AudioCapture.prepareContext`).

**Ring (`Sources/AudioRing/AudioRing.c`).** `channel_ring_lose` adds to the atomic dropped count at once and leaves a
pending break that is marked where the next write starts (a run of losses is one break). `channel_ring_clear`, called by
every capture start and stop, empties the ring and drops pending marks and counts. `AudioCapture.stop()` returns the
dropped count read just before that clear.

**Model (`Sources/Auraliscope/MeterModel.swift`).**

- `HardwareObserver` listens to the device list, and on the captured device (the tapped output device for an output
  source) to `kAudioDevicePropertyNominalSampleRate`, `kAudioDevicePropertyDeviceIsAlive` and the preferred channel
  layout. A rate or alive change hops to the main actor; if capture is wanted, the device list is refreshed and, if the
  same source is still selected and present, `restart()` runs.
- `restart()` stops everything (`stop()`: analysis, then capture; `droppedBefore` reset), clears the measurements,
  starts capture, makes a fresh analysis at the device's rate and sets `droppedFrames = 0`. A capture that cannot
  start sets `.failure(message)`; nothing retries it.
- `refreshDroppedFrames()` (the 10 Hz readout timer, `Readouts.rate`) shows `droppedBefore + channel_ring_dropped`. A pause carries drops across
  (`droppedBefore`); a restart starts the count afresh with the fresh analysis.
- Not observed: buffer frame size, stream configuration (channel count), processor overload, `kAudioHardwarePropertyServiceRestarted`
  (coreaudiod restart). Notifications are not coalesced: each one restarts.

## 3. Failure modes

| Mode | What the callback sees | Reproduced here | Ends today when | Gap |
|---|---|---|---|---|
| Sample-rate mismatch (device rate changed, capture format not yet) | `AudioUnitRender` −10863 on every slice; slices fit storage | Yes (probe, Phase 2: 47/47 and 23/23 refused) | The rate notification's restart | No end if the notification is missed, arrives for another selection, or the restart fails |
| Slices longer than storage (device IO size grew past `max_frames`) | Oversize on every slice | No: the IO buffer size is per process (another app, a DAW included, cannot change Auraliscope's), and every device here caps it at 4,096 frames | Never (no listener) | Lasting silence, counted |
| Tap delivery longer than storage | Tail cut every cycle | No (same cap) | Never | Partial audio every cycle, counted |
| Tapped output device changes rate | Nothing fails: the IOProc keeps delivering, at the aggregate's rate | No | The rate notification's restart | If missed, the analysis runs at the wrong rate with no failure to see |
| Device gone | Callbacks stop | Device list only (stand-ins) | Device-list refresh: `.noDevice`, restored when it returns | Covered |
| Capture restart fails (`start` throws) | n/a | Stand-in only | Manual start | No retry |
| IO cycles skipped (overload) | Callbacks resume; nothing marks the gap | No | n/a | Silent gap, not counted (out of scope; see 8.4) |
| coreaudiod restart | Unit invalid; callbacks stop | No (invasive) | n/a | Not observed |

## 4. Proposal

### 4.1 Recording in the IO callback (real time)

Add a small health record next to the ring, written only by the IO thread with relaxed atomics, read by the main
thread through C accessors (Swift cannot touch C11 `_Atomic` fields):

- `slices`: callbacks since start.
- `failed_slices`; `failure_run`: consecutive failed callbacks, reset to 0 by a successful slice.
- `failure_kind` bits of the current run: `REFUSED` (render status ≠ 0), `OVERSIZE` (frames > `max_frames`),
  `TRUNCATED` (tap tail cut).
- `last_status`: the newest refusal's OSStatus; `largest_slice`: the largest frame count requested.

Cost: four or five relaxed stores per callback. No lock, allocation, logging, Objective-C or Swift, and no signal
from the callback: the main thread already polls at 10 Hz, which is enough for a threshold measured in seconds. The
existing `channel_ring_lose` calls stay as they are, so P0-1/P0-2 accounting is unchanged. `channel_ring_clear` (and so
every start) zeroes the record.

### 4.2 Detection (main thread, 10 Hz)

A pure value type, `CaptureRecoveryPolicy`, fed on each readout tick with: the time, the capture generation
(`streamID`), the health record, and whether capture is wanted. States: `healthy`, `failing(since, kind)`,
`waiting(until, attempt)`, `failed(reason)`.

- A run is **sustained** when `failure_run` has been non-zero for at least **1.0 s** of wall time and at least
  **3** consecutive slices. One second is well above the expected notification-to-restart latency (a main-queue hop and
  a device list read), so the normal rate-change path wins the race and the policy never fires for an ordinary rate
  change. The real latency must be measured on hardware (section 8.2) and the threshold set to at least 3× it.
- A successful slice ends the run; isolated failures never trigger anything (they are already counted).

### 4.3 Classification (main thread, Core Audio property reads)

On a sustained run, read the device's state before acting:

1. **Device gone** (`DeviceIsAlive` = 0, or not listed): do nothing; the device-list path owns it (`.noDevice`, then
   restoration when it returns).
2. **Sample-rate mismatch**: `kAudioDevicePropertyNominalSampleRate` ≠ the capture's rate (for a tap, the aggregate's).
   The analysis must start afresh at the new rate, exactly as the notification path does: `restart()`.
3. **Too long for the storage**: kind `OVERSIZE`/`TRUNCATED`, with `largest_slice` > `max_frames`. Restart capture with
   storage sized from `largest_slice` and AUHAL's `kAudioUnitProperty_MaximumFramesPerSlice` (raise the 16,384 cap
   accordingly, with an upper bound such as 65,536 frames). The rate is unchanged, so the analysis carries on (4.6).
4. **Unknown refusal** (rate equal, device alive, slices fit): restart capture alone, analysis kept (4.6), with backoff.

Classification uses the callback's record (what failed) and the device's state (why), so a rate mismatch is never
confused with a capacity failure: the first has slices that fit and a rate difference, the second has oversize slices
at the same rate.

### 4.4 Restarts, backoff and loop avoidance

- **One recovery at a time**: a single pending `DispatchWorkItem` on the main queue, tagged with the capture generation.
  It is cancelled, and the episode's timer reset, by anything that changes the generation or stops capture: `stop`,
  `restart` (a notification's included), pause, a source change, a permission change, demo, a DAW plugin source.
- **Budget**: at most **3** automatic attempts per episode, at 0 s, 2 s and 8 s after detection. A restart that
  succeeds but fails again the same way within 2 s counts as a failed attempt. The episode ends, and the budget refills,
  after **30 s** without a sustained failure.
- **Notification restarts count too**: the rate notification restarts at once as today, but notifications within
  250 ms are coalesced into one restart, and a notification restart during an episode uses the episode's budget. A
  device that flaps its rate cannot drive an unbounded restart loop.
- **Never** recover while capture is not wanted (paused or stopped), while permission is pending or denied, in demo
  mode, or for a DAW plugin source (plugins have their own disconnection and format paths).
- **Failed restart**: a `start` that throws is an attempt; the next one follows the backoff. After the budget, capture
  stays stopped.

### 4.5 Giving up, status and manual recovery

- While an attempt is pending: status `.recovering(reason)` ("Capture interrupted: the device's sample rate changed.
  Restarting…" or "…refused audio (OSStatus %d)…" or "…delivered more audio per cycle than expected…"). The picture
  holds as it was (as for a pause), so the panels do not show a silence that never played.
- After the budget: capture is stopped (the device is released rather than kept failing) and the status is
  `.failure` with the reason and "Choose Start Capture to try again". The diagnostic log records detection (kind, run
  length, OSStatus, frames lost), each attempt with its generation, and the outcome.
- **Manual recovery** is the existing control: Start Capture (or choosing the source again) runs `restart()` and
  refills the budget.
- New text needs keys in all six localization tables. Status wording only; no layout or style change.

### 4.6 Break accounting

- The callback keeps losing failed slices through `channel_ring_lose` (unchanged): the dropped count rises during the
  failure and each run is one break.
- **Capture-only restart (same rate)**: stop capture, add `capture.stop()`'s dropped count to `droppedBefore` (as a
  pause does), start capture again, and before IO starts mark the fresh ring with one `CHANNEL_RING_LOST` break
  carrying the frames lost in the run and the time it lasted (`channel_ring_mark` is safe there: no producer runs
  between `channel_ring_clear` and `AudioOutputUnitStart`). The frames are counted once (`channel_ring_lose` already
  added them to the dropped count); the mark only tells the analysis how much is missing. The analysis then continues
  across one break with its missing seconds, instead of being reset. This needs `AudioCapture.start` to take that
  carried loss.
- **Fresh restart (rate changed)**: as today, a new analysis with counts from zero; the frames lost before it are
  logged.
- Nothing here changes `channel_ring_lose`, the ring's marks, the snapshot or the golden digests.

### 4.7 Teardown and restart order

Unchanged mechanism (`AudioCapture.stop` and `start`), from the main thread only: cancel the pending recovery; stop the
IO (AUHAL: stop, uninitialise and dispose the unit, after which no callback runs; tap: `AudioDeviceStop` then
`AudioDeviceDestroyIOProcID`); free the storage; read the ring's dropped count and clear the ring; mark the carried loss;
configure and start the new IO; then resume the analysis or make a fresh one. Property reads used for
classification happen on the main thread before stopping, never in the callback. A device configuration notification
arriving mid-recovery cancels the pending work item and takes the normal path; the generation check makes a late work
item a no-op.

### 4.8 Also worth observing (smaller, separate changes)

- `kAudioDevicePropertyBufferFrameSize` on the captured device: re-size storage on change (the audit's original
  recommendation; cheap once the restart path is bounded).
- `kAudioDevicePropertyStreamConfiguration`: a channel count change (an aggregate rebuilt) makes the routing stale.
- `kAudioHardwarePropertyServiceRestarted`: refresh devices and restart after coreaudiod restarts.
- For output taps, a once-a-second comparison of the aggregate's nominal rate with the capture's rate (main thread): a
  tapped device's rate change produces no failed slice, so the failure record cannot see a missed notification there.

## 5. Real-time safety

The callback gains only relaxed atomic stores to fields it alone writes. No dispatch, semaphore, lock, allocation or
logging. Detection, classification, property reads, scheduling and restarts run on the main actor. `AGENTS.md`'s
real-time rules hold unchanged.

## 6. Interaction with existing behaviour

- Rate notifications still restart at once; the policy only adds a bound and a fallback.
- Pause, resume, reset, source switching, device loss and restoration keep their paths; each cancels a pending recovery.
- DAW plugin sources are untouched.
- `droppedFrames` semantics stay: carried across a pause and a capture-only recovery, reset by a fresh analysis.

## 7. Thresholds (initial, to be confirmed on hardware)

| Parameter | Proposed | Reason |
|---|---|---|
| Sustained failure | 1.0 s and ≥ 3 slices | ≥ 3× the expected notification restart latency; ignores single glitches |
| Attempts per episode | 3 | Covers a rate change racing a restart, plus one retry; then a person decides |
| Backoff | 0 s, 2 s, 8 s | First attempt immediately; later ones give a device time to settle |
| Episode reset | 30 s healthy | A device that recovers is not penalised later |
| Notification coalescing | 250 ms | One restart for a burst of rate/alive notifications |
| Storage cap | 65,536 frames | Bounds memory (64 ch × 65,536 × 4 B = 16 MiB at worst) |

## 8. What can be tested where

### 8.1 Deterministic, no hardware

- **Callback record**: headless core checks call `capture_input_proc` with an oversize slice and with an uninitialised
  AUHAL (which refuses every slice, as `BaselineChecks.captureRefusalsAreCountedAsBreaks` already does), then read the
  record: kinds, run, reset by a success (tap IOProc with an in-storage delivery), cleared by `channel_ring_clear`.
- **Policy**: a pure type with an injected clock, table-tested in `scripts/test.sh`: threshold edges, classification
  inputs, backoff times, budget exhaustion, refill after 30 s, cancellation by generation, never acting while not
  wanted.
- **Model wiring**: `--test-model-lifecycle` with the stand-in capture extended to report a failure record and a
  device state: detection leads to exactly one restart, backoff spacing, exhaustion to `.failure`, manual start refills,
  pause/stop/source change/notification cancel a pending attempt, drops carried and one break marked on a capture-only
  restart, plugin sources never touched. (A stand-in notification hook is needed for the coalescing checks.)

### 8.2 Needs real hardware or system changes

- Latency of the notification path after a real nominal-rate change on an idle loopback device (global change; needs
  approval) — sets the detection threshold.
- A driver that changes rate without notifying (field reports, or a virtual driver built for the test).
- Device unplugged while failing or while an attempt is pending; plugged back in.
- Slices above 4,096 frames (no device here allows it).
- Output taps with System Audio Recording: tapped device's rate change; aggregate behaviour.
- coreaudiod restart (invasive; approval).
- Microphone permission revoked while capturing.

### 8.3 Sanitizers

The record is single-writer relaxed atomics. A ThreadSanitizer run should cover a small C-only harness that writes the
record from one thread while another reads it; the full core checks under ThreadSanitizer did not finish in Phase 2, so
they are not the vehicle. The model wiring can run under the app's sanitizer builds, as Phase 6 did for the lifecycle
self-test.

### 8.4 Out of scope

Skipped IO cycles (processor overload) produce a silent gap that no counter sees. Comparing each callback's
`mSampleTime` with the expected next one would detect it in the callback (arithmetic only) and could lose the gap
through `channel_ring_lose`. Worth a separate change after this one.

## 9. CaptureSession: before or after?

**After**, with the policy built as separable pieces: the C health record (in `AudioRing`), the pure
`CaptureRecoveryPolicy` (testable alone), and thin glue in `MeterModel` (the readout tick, the pending work item,
statuses). Reasons:

1. The extraction is meant to change no behaviour, and Phase 5 deferred it until live checks can run. The policy changes
   behaviour and needs the same live checks (rate change, unplug, taps, permission). Doing the policy first means one
   hardware validation for the behaviour change; extracting first would need a hardware pass for the refactor and
   another for the policy.
2. Once the policy exists and is tested, the extraction moves the glue (generation tag, pending work item, status
   mapping) together with `restart`/`stop`/`pause`, and the policy's model-level checks become the extraction's
   safety net.
3. The glue is small (one tick hook, one work item, two statuses), so building it in the model first adds little
   that the extraction would have to untangle.

Order: (1) health record + policy + glue, with deterministic tests; (2) live validation (section 8.2) and threshold
calibration; (3) `CaptureSession` extraction; (4) the smaller listeners in 4.8.

## 10. Decisions needed

1. Approve implementing the policy (and the new status texts in six languages).
2. Approve a real nominal-rate change on an idle loopback device to measure notification latency.
3. Confirm capture-only recovery keeps the analysis (integrated loudness continues across one marked break) rather
   than starting afresh.
