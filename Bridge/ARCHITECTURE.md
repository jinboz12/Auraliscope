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
| `Sources/AnalysisCore` (Swift) | `LoudnessAnalyzer`, `SpectrumAnalyzer`, `WaveformEnvelope`, `FormatDetector`, `MeterPipeline` and its snapshot layout (moved unchanged from the app), plus `StreamAnalyzer` (pushed audio, audio-clocked ticks, result encoding), `ResultProtocol` (RESULT fields) and `ResultAssembler` (results back into snapshots) | Foundation, Accelerate, AnalysisKernels; **no AppKit, SwiftUI, Core Audio or views** |

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
- **Clicking TRUE PEAK** sends RESET_TRUE_PEAK.
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
