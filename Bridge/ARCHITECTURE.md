# Auraliscope Bridge: architecture note

```
DAW audio thread ──► Bridge core (per insert) ──► record ring (512 KB, SPSC, preallocated)
                                                        │  (no syscalls, locks or allocation above this line)
                     sender thread (one per plugin binary, every 5 ms) ──► Unix socket (one per insert)
                                                        │
Auraliscope Labs:    receiver thread (BridgeServer.c) ──► ChannelRing (the same ring device capture feeds)
                                                        │
                     DSPWorker / MeterPipeline (unchanged) ──► snapshots ──► Metal canvases and readouts
```

## Components and responsibilities

| Concern | Where |
|---|---|
| Plugin formats | `Bridge/Plugin/VST3/BridgeVST3.cpp` (VST3 SDK `SingleComponentEffect`), `Bridge/Plugin/AU/BridgeAU.cpp` (AudioUnitSDK `AUEffectBase`). Thin: they translate host calls to the core. |
| Format-independent plugin behaviour | `Bridge/Plugin/Core/` — `BridgeCore` (identity, settings, state machine, audio-thread capture, socket client), `RecordRing`, `BridgeSender.cpp` (the process-wide sender thread). |
| Plugin window | `Bridge/Plugin/Editor/BridgeEditor.mm`, shared by both formats. |
| Protocol and transport | `Sources/BridgeTransport/include/BridgeProtocol.h` (wire format), `BridgePaths.h` (rendezvous), `BridgeServer.c` (receiver), `BridgeDiscovery.c` (DNS-SD scan). No VST3 or AU types. |
| Source acquisition in the app | `Sources/Auraliscope/BridgeSource.swift` (value types + receiver wrapper), `BridgeRestoration.swift` (which connected insert is the saved one), DAW-source lifecycle in `MeterModel.swift` (`startBridge`, `pollBridge`, `followBound`, `findSaved`). |
| Analysis | `MeterPipeline`, `LoudnessAnalyzer`, `SpectrumAnalyzer`… as in the release, plus break handling: `ChannelRing` break marks (`channel_ring_mark`, `channel_ring_read_marked`) and `interrupt` in each analyser. |
| Visualisation | Unchanged, plus a *DAW plugins* section in Settings ▸ Audio ▸ Source and new status texts. |

## Framework choice

The VST3 SDK (3.8, MIT since Oct 2025) and Apple's AudioUnitSDK (Apache-2.0), used directly. JUCE would have been
quicker for the UI but is AGPLv3 or commercially licensed, and Auraliscope has no open-source licence. The two SDKs
only require their notices (`Bridge/THIRD_PARTY_NOTICES.md`, copied into both bundles). No CMake: the build scripts
compile the needed SDK sources with clang.

AUv2 rather than AUv3: every installed host loads AUv2, AUv2 runs in the host process like VST3 (so both share the
core and the socket client unchanged), and AUv3 would need an app extension container and a sandboxed transport.

## Transport

A Unix-domain stream socket per plugin instance, at
`~/Library/Application Support/Auraliscope Bridge/bridge-v1.sock` (the real home folder of the user). Labs listens;
plugins connect. Chosen because:

- Discovery, liveness and cleanup come for free: a connection is an instance, and a closed connection (plugin
  removed, DAW quit or crashed) is seen at once. No stale shared-memory segments.
- Control flows both ways on the same connection (subscribe, unsubscribe, focus).
- Bandwidth is small (48 kHz stereo float = 384 KB/s) and only the selected instance streams.
- Access is scoped to the user: the folder is created `0700` and refused if another user owns it or it is a
  symbolic link; the socket is `0600`; both ends check the peer's user ID with `getpeereid`.

Messages (protocol version 2, little-endian, 16-byte header): HELLO (session ID, persistent ID, restored ID and
identity flags, host name, bundle ID and pid, plugin format and version), STATUS (state, format epoch, rate, channels,
layout, block size, transport flags and position, counters, source, track and channel names, at least every
250 ms), FORMAT (per format epoch), AUDIO (subscription, epoch, stream position, flags and break reasons, idle time,
interleaved float32), FOCUS; from the app, WELCOME, SUBSCRIBE (with a subscription number) and UNSUBSCRIBE. Unknown
types are ignored. A plugin of another protocol version is listed by Labs as needing an update and never selected; a
version 1 plugin is not answered, so it stays connected instead of reconnecting every second.

**Subscriptions.** Every SUBSCRIBE carries a new number, and every AUDIO block the number it was captured for. The
receiver delivers only blocks of its current subscription, so audio queued in the plugin or the socket before an
unsubscribe or a quick re-selection (A → B → A) is never replayed as live. The format epoch and channel count are
packed in one atomic word, so the audio thread never pairs a new epoch with an old channel count.

## Insert identity

Each insert has a **session ID** (random, for the life of this plugin instance) and a **persistent ID** (saved with
the DAW project in the plugin state). A process-wide registry in the plugin binary knows which persistent IDs live
instances hold:

- State restored into a new instance (project opened, plugin reloaded, undo) keeps its persistent ID and is flagged
  RESTORED.
- State whose ID another live instance already holds (a duplicated track, pasted settings, a preset of this insert,
  a second copy of the project in the same DAW) gets a new persistent ID and is flagged COPY, with the ID it was
  copied from. So a saved project never holds two inserts with the same ID (checked in REAPER for both formats).
- The host's own channel identity is reported when the host gives one (VST3 `IInfoListener` channel UID, e.g.
  REAPER's track GUID), with the track name (VST3 `IInfoListener`, AU `ContextName`).

Hosts in other processes cannot see each other's registry, so two DAWs running the same project each hold the ID.

## Finding the saved insert again (`BridgeRestoration`)

Labs saves the chosen insert with its context (persistent ID, session, name, track name, channel ID, host bundle ID,
plugin format) and the copies it saw being made of it. When it is not connected, the rule is never to pick one of
several possible inserts by chance:

1. The same live instance (same session) is it: Labs restarted, or the connection came back.
2. Otherwise the only insert holding the saved persistent ID, with no copy of it connected, is it (project reopened,
   plugin reloaded). A copy never inherits the selection. Copies seen appearing while the saved insert was bound are
   known not to be it and do not count (the host unloaded and reloaded the original beside its copy).
3. With several claimants (holders in two DAWs, or unknown copies beside the holder), the saved context may single
   one holder out: the host channel ID alone when both have one, otherwise plugin format, host, source and track
   names together.
4. Anything else is **ambiguous**: analysis stops, the status says how many inserts could be it, and nothing is
   analysed until the person chooses one (in the source list, or with the plugin window's one-click button).

A new instance found by rule 2 or 3 is bound after a one-second settle (a project still loading may bring more
claimants) and stays provisional for five seconds: a claimant arriving meanwhile makes it ambiguous.

### Sandbox finding and the production transport

An ad hoc signed, sandboxed process can neither `bind` nor `connect` to a Unix socket outside its container, even with
file temporary-exception entitlements and the network entitlements (tested on this Mac, macOS 27). So Labs is not
sandboxed, while the release Auraliscope is. See "Production transport" below for the recommendation and the
feasibility test.

## Real-time behaviour

The audio callback (`BridgeCore::process`) reads a few atomics, and when the insert is live and subscribed
interleaves the block straight into the ring (`RecordRing::write`: two memcpy-sized copies at most, no allocation, no
lock, no system call). Everything else — sockets, status, format messages — runs on the sender thread. The ring and
all buffers are allocated when the plugin is created. Measured worst `process()` time on a real-time thread: under
35 µs per 256-frame block (harness), 7.7 µs through a one-second receiver stall (transport test).

Drop policy when Auraliscope cannot keep up:
1. The sender keeps at most 150 ms of audio queued; older records are discarded, oldest first, so what arrives is
   recent.
2. The socket buffers are small (128 KB), so the kernel cannot hide seconds of backlog.
3. If the sender thread itself stalls until the ring is full, the audio thread drops the newest block.

Every block carries its stream position (live frames processed in this session), and the first block after any loss
is flagged. The receiver counts exactly the frames lost (the transport test: plugin dropped 21 056, receiver counted
21 056 in one gap) and Labs adds them to the status bar's dropped-frames count.

## Analysis at breaks

A break is any point where the delivered audio does not continue the audio before it: frames dropped, the host not
processing (idle longer than a block plus 350 ms, or three blocks), bypass, offline render, deactivate/reactivate,
or the connection coming back. The plugin sets the reasons on the first live block after the break; the receiver adds
position gaps; Labs marks the exact frame in `ChannelRing`, and the analysis thread splits its reads there and calls
`MeterPipeline.interrupt` between the two parts:

| Restarts at a break | Carries on |
|---|---|
| K-weighting filter state, the 100 ms block being built, momentary and short-term loudness | integrated loudness (its gated blocks), loudness range |
| spectrum FFT window (no transform mixes audio from both sides) | held peak and true-peak maxima |
| band splitter, correlation and stereo balance | the waveform history, with a notch of 12–48 columns at the break |
| true-peak interpolator (never measured across the cut, so a break cannot make a false over) | |

The status bar reads "Interrupted N× · x s missing" (`SnapshotSlots.breaks`, `.missing`). A timeline jump (loop,
locate) is not a break: the insert's input stays one signal, and only a counter records it. The user's pause and
resume keep the release behaviour: resuming continues the same measurement, and no break is marked for the paused
time.

## States and policies

| Situation | Plugin state | Transmission | Labs shows |
|---|---|---|---|
| Real-time processing | LIVE | while selected | streaming |
| Host bypass reported to the plugin (VST3 `kIsBypass` parameter, AU `BypassEffect`) | BYPASSED | none; position stands still; next live block flagged | bypassed |
| Host stops calling the plugin (REAPER FX bypass; transport stop in some hosts) | LIVE | none arrives | no audio (after 0.5 s) |
| Transport stopped but host keeps processing (REAPER) | LIVE | silence streams | streaming |
| Offline render (VST3 `kOffline`, AU `OfflineRender`) | OFFLINE | none: offline audio is never presented as live | offline render, not metered |
| Not activated / not initialised | INACTIVE | none | inactive |
| No message for 2 s | — | — | not responding |
| Connection closed, analysis running | — | — | disconnected, measurement held in case this plugin instance reconnects; continues (with a break) if the same session returns |
| Connection closed, nothing measured yet | — | — | disconnected, waiting for it to return |

Transport position changes (loop, locate) are metadata only: they neither reset analysis nor mark a discontinuity,
because the analysed signal is what reaches the insert, not the timeline. (A host that stops processing around a
locate for longer than the idle threshold does produce a break, as it should: audio was missing.) Audio always passes
through unchanged, whatever the state and whether Auraliscope is running.

## Source lifecycle in Labs

- The receiver runs from launch to quit, so inserts are listed whatever source is being metered. Selecting one
  subscribes to it; only that insert streams.
- Labs builds a new pipeline at the insert's own sample rate and routing (mono: input 1 → L; stereo: L, R). A new
  format epoch (sample-rate or channel change, re-activation) restarts the pipeline; audio of the new epoch is
  held back until then, so analysers never interpret audio of another format.
- The selection is saved with its context (above). When the insert disconnects, Labs keeps it selected, holds the
  measurement and waits; the same session returning continues it, a new instance of the saved insert starts afresh,
  and an ambiguous choice waits for the person.
- One click in the plugin window (FOCUS) selects that insert and brings the meter window forward; if Labs is not
  running, the plugin launches it with `--bridge-launch` (no default-output capture, no welcome sheet) and the
  request is delivered as soon as the connection is up.

## Scanning (this Mac and the local network)

The plugin window (440 × 466) answers, top to bottom: which Labs it talks to; whether **this insert** is the one
Labs analyses (with one click to make it so, or the reason it cannot be: bypassed, offline, another insert chosen,
ambiguous); whether fresh audio is arriving (frames sent, dropped, age of the newest block); and how many times the
stream was interrupted and why.

- **This Mac:** the socket connection (authoritative), plus the running applications, to report Labs starting up, or
  the release Auraliscope running (which does not receive DAW audio).
- **Network · Preview**, a collapsed card at the bottom: DNS-SD browsing for `_auraliscope._tcp` (`BridgeDiscovery.h`
  defines the TXT keys: `proto`, `platform`, `app`, `ver`, `role`, `transport`) runs only when the person clicks
  **Scan**, and the card says that iPhone and iPad receivers cannot receive analysis yet. The macOS Local Network
  prompt (made on behalf of the DAW) therefore appears only after that click. `Bridge/Tools/DiscoveryBeacon.c` stands
  in for an iOS device.

## Towards iOS: the analysis-result boundary

The iOS client will receive analysis results, not audio. That boundary already exists in the app: `MeterPipeline`
publishes a fixed-layout snapshot (`SnapshotSlots`, `METER_SNAPSHOT_FLOATS` floats: levels, loudness, spectrum,
spectrogram column, stereo bands, waveform columns) to a triple buffer, and `MeterSnapshot` decodes it into plain
values with no UI types. A network sender would serialise that snapshot (plus a small header: stream identity, sample
rate, layout, sequence) at the 60 Hz tick — about 16 KB per frame uncompressed, so it wants delta or quantised
encoding over the LAN. The new `BridgeSource` and `BridgeCondition` are likewise plain values. Nothing in this
milestone sends anything over the network.

## Production transport (recommendation)

The release app is sandboxed (`Resources/Auraliscope.entitlements`); the plugins run unsandboxed inside the DAW's
process (REAPER, Logic Pro, Cubase, Live and FL Studio are not sandboxed). The carrier has to work across that
boundary. `Bridge/scripts/probe-sandbox-transport.sh` (`Bridge/Tools/SandboxTransportProbe.c`) builds a sandboxed
receiver app with an application group and an unsandboxed "plugin", and runs them against each other. Ad hoc signed,
macOS 27.2, M1 Max:

| Carrier | Sandboxed receiver | Unsandboxed plugin | Result |
|---|---|---|---|
| Unix socket in `~/Library/Group Containers/<group>/` | `bind`: Operation not permitted | nothing to connect to | not available ad hoc; unverified with a team signature |
| Mach port, `CFMessagePort` named `<group>.bridge` | registered | found; 1000 × 4 KB requests answered, mean 35 µs, worst 122–254 µs | **works** |
| Mach port the plugin registers as `<group>.plugin` | looked up and sent to | received | **works** (the app can reach each insert) |
| Mach port without the group prefix | lookup refused | registered | refused: the sandbox is enforcing the rule |

**Recommendation:** keep protocol version 2 and its framing unchanged and replace only the carrier with Mach
messaging on application-group–prefixed service names (`TEAMID.com.jinboz.SoundMeterJBZ.bridge` for the app, one
port per plugin instance for control). The sandbox explicitly allows a sandboxed app to register and look up names
under its own group prefix, a non-sandboxed plugin can look up any name in the user's session, no files are shared
(so no "access data from other apps" prompt for the DAW), and the kernel reports a dead peer (a port's dead-name
notification replaces the socket's close). The bandwidth (≈ 94 messages of 4 KB per second for 48 kHz stereo) is
trivial for Mach messages. Audio would go as one-way messages from the sender thread; the audio thread stays as it is
(ring only).

What must still be verified before committing, with a Developer ID or App Store team signature (the probe takes the
identity and group as arguments): that the group prefix is honoured for a team-signed app without a provisioning
profile; that registering the name from the app (not a launchd-declared service) survives App Review if the Mac App
Store is the channel; peer identity (a Mach message carries an audit token: check the sender's user ID, and whether
to require the plugin's team ID). The alternatives are weaker: a Unix socket in the group container requires the
DAW to open another app's group container, which macOS 15 and later may put behind a privacy prompt shown on behalf
of the DAW; an XPC service needs a launch agent helper (`SMAppService`) that the release does not otherwise need; and
shipping unsandboxed (Developer ID only) keeps today's socket but gives up the release's sandbox. Sandboxed hosts
(GarageBand) were not tested: a plugin inside one is subject to that host's sandbox, which is unlikely to allow
another vendor's names (AUv3 in an app extension would be the path there).
