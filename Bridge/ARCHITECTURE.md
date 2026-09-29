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
| Source acquisition in the app | `Sources/Auraliscope/BridgeSource.swift` (value types + receiver wrapper), DAW-source lifecycle in `MeterModel.swift` (`startBridge`, `pollBridge`). |
| Analysis | Unchanged: `MeterPipeline`, `LoudnessAnalyzer`, `SpectrumAnalyzer`… |
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

Messages (little-endian, 16-byte header): HELLO (session ID, persistent project ID, host, pid, plugin format and
version), STATUS (state, format epoch, rate, channels, layout, block size, transport, counters, names, at least every
250 ms), FORMAT (per format epoch), AUDIO (epoch, stream position, flags, interleaved float32), FOCUS; from the app,
WELCOME, SUBSCRIBE and UNSUBSCRIBE. Unknown types are ignored, so the protocol can grow within version 1.

### Sandbox finding

An ad hoc signed, sandboxed process can neither `bind` nor `connect` to a Unix socket outside its container, even with
file temporary-exception entitlements and the network entitlements (tested on this Mac, macOS 27). So Labs is not
sandboxed. For a sandboxed, team-signed release the rendezvous must move to an application group container (or an
XPC/Mach service); whether a plugin in another vendor's DAW may reach that container without a privacy prompt must be
checked with a signed build before committing to it. The installed DAWs (REAPER, Logic Pro, Cubase, Live, FL Studio)
are not sandboxed; a sandboxed host (GarageBand) will not reach the socket.

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
21 056 in one gap) and Labs adds them to the status bar's dropped-frames count. Analysis continues across a gap.

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
| Connection closed | — | — | disconnected, waiting for it to return |

Transport position changes (loop, locate) are metadata only: they neither reset analysis nor mark a discontinuity,
because the analysed signal is what reaches the insert, not the timeline. Audio always passes through unchanged,
whatever the state and whether Auraliscope is running.

## Source lifecycle in Labs

- The receiver runs from launch to quit, so inserts are listed whatever source is being metered. Selecting one
  subscribes to it; only that insert streams.
- Labs builds a new pipeline at the insert's own sample rate and routing (mono: input 1 → L; stereo: L, R). A new
  format epoch (sample-rate or channel change, re-activation) restarts the pipeline; audio of the new epoch is
  held back until then, so analysers never interpret audio of another format.
- The selection is saved as the insert's persistent project ID. When the insert disconnects, Labs keeps it selected
  and waits; when an insert with the same project ID connects (plugin reloaded, project reopened, Labs restarted)
  it resumes. Copies of a track share the project ID; Labs then takes the first to connect (known limitation).
- One click in the plugin window (FOCUS) selects that insert and brings the meter window forward; if Labs is not
  running, the plugin launches it with `--bridge-launch` (no default-output capture, no welcome sheet) and the
  request is delivered as soon as the connection is up.

## Scanning (this Mac and the local network)

The plugin window lists what it finds:

- **This Mac:** the socket connection (authoritative), plus the running applications, to report Labs starting up, or
  the release Auraliscope running (which does not receive DAW audio).
- **Local network:** DNS-SD browsing for `_auraliscope._tcp` (`BridgeDiscovery.h` defines the TXT keys: `proto`,
  `platform`, `app`, `ver`, `role`, `transport`). A future Auraliscope for iOS advertises this service where it accepts
  connections; the Bridge lists it now and will send to it in a later release. Browsing runs only while a plugin window
  is open, so the macOS Local Network prompt (made on behalf of the DAW) appears when the user is looking at the
  plugin. `Bridge/Tools/DiscoveryBeacon.c` stands in for an iOS device.

## Towards iOS: the analysis-result boundary

The iOS client will receive analysis results, not audio. That boundary already exists in the app: `MeterPipeline`
publishes a fixed-layout snapshot (`SnapshotSlots`, `METER_SNAPSHOT_FLOATS` floats: levels, loudness, spectrum,
spectrogram column, stereo bands, waveform columns) to a triple buffer, and `MeterSnapshot` decodes it into plain
values with no UI types. A network sender would serialise that snapshot (plus a small header: stream identity, sample
rate, layout, sequence) at the 60 Hz tick — about 16 KB per frame uncompressed, so it wants delta or quantised
encoding over the LAN. The new `BridgeSource` and `BridgeCondition` are likewise plain values. Nothing in this
milestone sends anything over the network.
