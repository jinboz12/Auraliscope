# Auraliscope Bridge protocol, version 3 (analysis schema 1)

Between an Auraliscope Bridge plugin instance (the **plugin**) and a display (**Auraliscope LABS** today, an iOS app
later). The plugin analyses its own audio; the display receives **analysis results**, never audio, and sends a
few commands. This document is the reference; the C header `Sources/BridgeTransport/include/BridgeProtocol.h`
(framing, control messages) and `Sources/AnalysisCore/ResultProtocol.swift` (RESULT fields) implement it.

## Carrier

Locally: one Unix-domain stream socket per plugin instance, at `abr_socket_path()`
(`~/Library/Application Support/Auraliscope Bridge/bridge-v1.sock`, folder `0700`, socket `0600`, peer user ID
checked on both ends). The display listens; plugins connect. Nothing in the messages depends on the carrier: a
network carrier would frame them the same way.

## Framing

Every message is a 16-byte header and `length` payload bytes. All integers and floats are **little-endian**.

| Offset | Type | Field |
|---|---|---|
| 0 | u32 | magic `0x47524241` ("ABRG" in memory order) |
| 4 | u16 | message type |
| 6 | u16 | flags (0; ignored) |
| 8 | u32 | payload length, at most 1 MiB (`ABR_MAX_PAYLOAD`) |
| 12 | u32 | sequence: messages sent on this connection in this direction (for diagnostics) |

A wrong magic or a length above the limit closes the connection. Unknown message types are skipped.

## Fields

Payloads are a sequence of fields (HELLO and WELCOME after an 8-byte prefix):

| Offset | Type | |
|---|---|---|
| 0 | u16 | tag (per message type) |
| 2 | u8 | kind: 1 u8, 2 u32, 3 u64, 4 i64, 5 f32, 6 f64, 7 UTF-8, 8 bytes |
| 3 | u8 | flags (0; ignored) |
| 4 | u32 | element count |
| 8 | count × size | value |
| … | | zero padding to a multiple of 4 bytes |

Rules, for every receiver:

- **Unknown tags are skipped.** A later minor version may add fields without a new protocol version.
- **A known tag with another kind, or more elements than its limit, is ignored** as if absent (and counted).
- **A field running past the payload, or an unknown kind, makes the payload malformed**: fields before it stand; a
  RESULT with a malformed field is not shown.
- The last of repeated tags wins. Text is UTF-8, not NUL-terminated, at most 255 bytes (less where stated).

## Versions and compatibility

HELLO and WELCOME start with two u32 words that every version keeps: `protocol_version` and (HELLO) the plugin format,
(WELCOME) 0. A display receiving a HELLO of another version lists the plugin as needing an update and never selects
it; it answers a version-2 or later plugin with a WELCOME carrying its own version, so the plugin can say which side
needs updating; a version-1 plugin (which never waits for a reply) gets none. A plugin receiving a WELCOME of another
version shows the mismatch and retries every 5 s.

The **analysis schema** (RESULT field set and meanings) is versioned separately: HELLO says which schema the plugin
writes, WELCOME which the display reads. A display ignores results of a schema it does not read. Adding a field is
not a schema change; changing a field's meaning or units is.

## Messages

| Type | Name | Direction | Payload |
|---|---|---|---|
| 1 | HELLO | plugin → display | u32 protocol version, u32 plugin format (1 VST3, 2 AU, 99 test), then fields |
| 2 | STATUS | plugin → display | fields; on every change and at least every 250 ms |
| 5 | FOCUS | plugin → display | none: the user clicked "Show in Auraliscope LABS" |
| 6 | RESULT | plugin → display | fields; while subscribed, whenever the analysis has something new |
| 7 | ACK | plugin → display | fields: the outcome of a COMMAND |
| 16 | WELCOME | display → plugin | u32 protocol version, u32 0, then fields |
| 17 | SUBSCRIBE | display → plugin | fields: start sending RESULTs |
| 18 | UNSUBSCRIBE | display → plugin | none |
| 19 | COMMAND | display → plugin | fields |

Types 3 (FORMAT) and 4 (AUDIO) belonged to version 2, which streamed audio. Version 3 never sends audio.

### HELLO fields

| Tag | Kind | Field |
|---|---|---|
| 1 | bytes[16] | session ID: random for the life of this plugin instance (identifies the live insert) |
| 2 | bytes[16] | persistent ID: saved with the DAW project (the same insert after reopening) |
| 3 | bytes[16] | restored ID: with the COPY flag, the identity the saved state carried |
| 4 | u32 | identity flags: 1 RESTORED (from saved state), 2 COPY (another live instance holds the saved identity) |
| 5 | i64 | host process ID |
| 6 | UTF-8 ≤ 63 | host process name |
| 7 | UTF-8 ≤ 95 | host bundle identifier |
| 8 | UTF-8 ≤ 31 | plugin version |
| 9 | u32 | analysis schema the plugin writes (1) |
| 10 | u32 | capabilities: 1 RESULTS, 2 RESET, 4 RESET_TRUE_PEAK, 8 PAUSE |

### WELCOME fields

| Tag | Kind | Field |
|---|---|---|
| 1 | u32 | newest analysis schema the display reads |

### STATUS fields

| Tag | Kind | Field |
|---|---|---|
| 1 | u32 | state: 0 inactive, 1 live, 2 bypassed, 3 offline render |
| 2 | u32 | format epoch: changes with the sample rate or channel count (0: never configured) |
| 3 | f64 | sample rate, Hz |
| 4 | u32 | channels |
| 5 | u32 | layout: 0 unknown, 1 mono, 2 stereo (L, R) |
| 6 | u32 | largest block the host announced |
| 7 | u32 | flags: 1 transport known, 2 playing, 0x10000 sending results |
| 8 | u64 | live frames processed in this session |
| 9 | u64 | live frames the analysis could not take (its queue was full); the audio itself passed |
| 10 | u32 | breaks in the live stream (bypass, offline render, host idle, restart) |
| 11 | u32 | timeline jumps while playing (locate, loop): not breaks |
| 12, 13 | UTF-8 ≤ 127 | source name (the name set in the plugin, else the track name); track name |
| 14 | UTF-8 ≤ 63 | the host's own channel ID, when it gives one |
| 15 | u32 | current analysis generation (0: none yet) |
| 16 | u32 | measurement: 0 none, 1 measuring, 2 paused |
| 17 | u64 | frames analysed in this generation |
| 18 | u32 | reasons of the newest break the analysis saw (see *Breaks*) |
| 19 | u32 | audio waiting for the analysis thread, ms |
| 20 | f64 | seconds since the host last delivered live audio (< 0: never) |

### SUBSCRIBE fields

| Tag | Kind | Field |
|---|---|---|
| 1 | u32 | subscription number, non-zero, new for every SUBSCRIBE (also when re-subscribing to the same instance) |
| 2 | u32 | waterfall analysis wanted: 0 Classic (default, also when absent), 1 Enhanced (build 72 and later; older plugins ignore it) |

A SUBSCRIBE repeating the current subscription number only changes its options: the plugin keeps sending the same
subscription's columns where it was, and the columns analysed from then on follow the new option. UNSUBSCRIBE returns
the plugin to Classic.

### COMMAND and ACK fields

COMMAND: 1 u32 command ID (chosen by the display, echoed), 2 u32 code, 3 bytes[16] the target's session ID, 4 u32 the
generation it is meant for (0: whichever is current).

Codes: 1 RESET (a new generation: every measurement starts afresh), 2 RESET_TRUE_PEAK (clear the held true peaks, also in the next RESULT while paused or idle),
3 PAUSE (pause measurement), 4 RESUME.

ACK: 1 u32 command ID, 2 u32 code, 3 u32 outcome, 4 u32 generation after it, 5 u32 measurement after it, 6
bytes[16] the answering session. Outcomes: 0 done, 1 wrong session (the command named another instance: an
obsolete selection; nothing done), 2 stale generation (the command expected an earlier generation; nothing done),
3 unsupported, 4 no analysis yet. Every COMMAND is acknowledged exactly once; PAUSE and RESUME are idempotent.

## RESULT (analysis schema 1)

A RESULT is the plugin's **latest state** plus the **ordered columns** of two series the subscriber has not had.
Per-channel arrays have one element per channel in the insert's order (mono 1; stereo L, R). Levels are linear
amplitude (1.0 = full scale); loudness in LUFS (LU for the range) with −100 meaning "no value yet" and −1 "range not
yet measurable"; spectra in dBFS with −120 for silence.

| Tag | Kind | Field |
|---|---|---|
| 1 | u32 | subscription this result answers |
| 2 | u32 | schema (1) |
| 3 | u32 | analysis generation |
| 4 | u32 | format epoch the generation analyses |
| 5 | f64 | sample rate |
| 6 | u32 | channels (1–2) |
| 7 | u32 | layout |
| 8 | u64 | results encoded in this generation (latest state: gaps are expected and harmless) |
| 9 | u64 | analysis tick this state closes (60 per second of audio; idle ticks included) |
| 10 | f64 | tick rate (60) |
| 11 | u64 | stream position just after the newest frame analysed (plugin session frames) |
| 12 | u64 | frames analysed in this generation |
| 13 | u32 | measurement: 1 measuring, 2 paused |
| 14 | u32 | flags: 1 idle (published with no new audio: the host is not processing) |
| 15 | u32 | breaks in the analysed audio in this generation |
| 16 | f64 | seconds of audio known to be missing at those breaks |
| 17 | u32 | reasons of the newest break |
| 20–24 | f32[ch] | sample peak, RMS, true peak (the newest 1/30 s); held sample peak, held true peak |
| 30–33 | f32 | momentary, short-term, integrated loudness; loudness range |
| 40 | f32[64] | spectrum: display bands, L and R combined |
| 41 | f32[2] | dominant peak: frequency (Hz), level (dBFS) |
| 42 | f32[12] | up to six notes: (frequency Hz, level dBFS) pairs; frequency 0 = none |
| 43 | f32 | L/R correlation, −1…1; −2 = nothing to correlate (silence, one side silent) |
| 44–47 | f32[9] | per band group (five bands, three, overall): correlation (−2 none), width, balance, level (dBFS) |
| 48 | f32[1280] | stereometer: per stereo band, 128 (L, R) points |
| 49 | f32[ch × 5] | each channel's mean square per stereo band |
| 50 | u32 | detected format (0 stereo, 2 mono) |
| 51 | f32[128] | fine spectrum: each display band of tag 40 halved, from the same transform (build 71 and later; a display that does not receive it shows each of the 64 bands across its two halves) |
| 60 | u64 | serial of the first spectrogram column carried (serials start at 1 per generation) |
| 61 | u32 | values per spectrogram column (512) |
| 62 | f32[n × 512] | n spectrogram columns, oldest first, dBFS (30 per second of audio) |
| 63 | u64 | newest spectrogram column the analysis has produced |
| 64 | u64 | spectrogram columns skipped just before the first carried: they left the plugin's queue before they could be sent |
| 65 | u32 | analysis of the newest columns: 0 Classic, 1 Enhanced (build 72 and later; absent: Classic) |
| 70–74 | | the same for the waveform: first serial, column rate (f64, 240 per second of audio), columns (f32[n × ch × 2], (min, max) per channel), newest, skipped |
| 80 | u32 | Spectrum FFT size (8192 at 44.1 and 48 kHz, 16384 at 88.2 and 96, 32768 at 176.4 and 192; since build 69, 8192 before) |
| 81 | u32 | spectrum bands (64) |
| 82 | f32 | correlation integration time, s (0.25) |
| 83 | f32 | level window, s (1/30) |

Required for a result to be shown: schema, generation, a sample rate of 8–384 kHz, 1–2 channels, the five level
arrays of that many elements, whole columns, no malformed field.

### Delivery policy

- **Latest state replaces older state.** The plugin keeps one encoded result waiting for the sender; a newer one
  replaces it. The socket buffers are small (32 KB each way), so a stalled display finds a handful of results waiting
  and receives the current state right after them; it never works through a backlog of old ones.
- **Columns are ordered and never repeated.** Each result carries the columns after the last one this subscriber was
  sent, from a bounded queue in the plugin (64 spectrogram columns, 512 waveform columns: about 2 s). A new
  subscriber starts from the oldest column held; each result carries at most 24 spectrogram and 256 waveform columns,
  so catching up takes a few results. A subscriber that falls further behind than the queue sees a gap in the serials
  and the count of skipped columns; it never receives a column twice.
- **Nothing is replayed across subscriptions.** Every SUBSCRIBE has a new number; a display drops results carrying
  any other (they were in flight before the change).
- **Generations.** A new generation (a RESET, a sample-rate or channel change) restarts every series at serial 1; a
  display treats it as a new stream (clears its histories).
- **Bounded everywhere.** The plugin's queues, mailbox and output buffer are fixed; a slow or absent display costs
  it nothing but skipped columns, and never blocks analysis or the host's audio.

## Breaks

Reason bits (in STATUS 18 and RESULT 17): 0x200 frames dropped (the analysis queue overflowed), 0x400 the host
stopped processing (longer than a block plus 350 ms), 0x800 bypass, 0x1000 offline render in between, 0x2000
restart (deactivate and reactivate), 0x4000 start of a generation. A timeline jump (0x8000) is recorded but is not a
break. At a break the analysis restarts what must not span it (K-weighting and loudness windows, FFT window, true-peak
interpolator, correlation integrators) and keeps what is made of complete windows (integrated loudness, loudness
range, held peaks, histories).

## Security and limits

Local only in this version: the socket is private to the user, both ends check the peer's user ID, and every length
is checked before use. A future network carrier would need authentication and encryption; see ARCHITECTURE.md.
