#ifndef AURALISCOPE_BRIDGE_PROTOCOL_H
#define AURALISCOPE_BRIDGE_PROTOCOL_H

// Auraliscope Bridge local transport, protocol version 3: analysis results, not audio. The full specification,
// with every field, limit and compatibility rule, is Bridge/PROTOCOL.md.
//
// Each Bridge plugin instance analyses its own audio (Sources/AnalysisCore, on a thread of the plugin) and sends
// the results; the desktop application only shows them. One Unix-domain stream socket per plugin instance; the
// application listens at `abr_socket_path()` and every instance (VST3 or AU alike) connects as a client.
//
// Every message is a 16-byte header followed by `length` payload bytes, all little-endian:
//
//   magic u32 ("ABRG") · type u16 · flags u16 (0) · length u32 · sequence u32 (per connection, per direction)
//
// Payloads are sequences of tagged fields (BridgeWire.h): tag u16 · kind u8 · flags u8 · count u32 · value, padded
// to 4 bytes. A receiver skips fields it does not know and ignores known fields of the wrong kind or size, so a
// minor addition never needs a new protocol version. Only HELLO and WELCOME begin with a fixed prefix (the
// protocol version), so that both ends of different versions can recognise each other.
//
//   plugin → app   HELLO     first message: u32 protocol_version, u32 plugin_format, then fields: identity
//   plugin → app   STATUS    on every change and at least every ABR_STATUS_INTERVAL_MS: state, names, counters,
//                            analysis generation and measurement state
//   plugin → app   RESULT    while subscribed: the newest analysis state plus the spectrogram and waveform columns
//                            the subscriber has not had (fields: Sources/AnalysisCore/ResultProtocol.swift)
//   plugin → app   ACK       the outcome of a COMMAND
//   plugin → app   SPATIAL_ACK  what came of a SPATIAL_CONFIG: applied (its revision and hash) or why not (build 98)
//   plugin → app   FOCUS     the user clicked "Show in Auraliscope Labs": make this instance the active source
//   app → plugin   WELCOME   reply to HELLO: u32 protocol_version, u32 reserved, then fields
//   app → plugin   SUBSCRIBE / UNSUBSCRIBE   start or stop RESULTs for this instance (a new number each time)
//   app → plugin   COMMAND   reset, reset true peak, pause or resume the instance's measurement
//   app → plugin   SPATIAL_CONFIG  the speaker geometry and spatial options the display draws with, for a plugin
//                            with ABR_CAPABILITY_SPATIAL_CONFIG only (an older one would close a message this long)
//
// Results are never replayed: every RESULT names the subscription it answers and carries the plugin's current
// state, so a receiver drops anything of an earlier subscription and never mistakes queued results for new ones.

#include <stdint.h>

#define ABR_PROTOCOL_VERSION 3u
#define ABR_ANALYSIS_SCHEMA 1u         // the RESULT field set (ResultProtocol.swift)
#define ABR_MAGIC 0x47524241u          // "ABRG" in memory order
#define ABR_MAX_CHANNELS 16u            // mono, stereo, or an immersive bus of up to 16 speakers (9.1.6)
#define ABR_MAX_PAYLOAD (1u << 20)
#define ABR_STATUS_INTERVAL_MS 250u
#define ABR_TEXT_MAX 255u              // longest UTF-8 text field, bytes

enum {
    ABR_MSG_HELLO = 1,
    ABR_MSG_STATUS = 2,
    ABR_MSG_FOCUS = 5,        // no payload
    ABR_MSG_RESULT = 6,
    ABR_MSG_ACK = 7,
    ABR_MSG_SPATIAL_ACK = 8,
    ABR_MSG_WELCOME = 16,
    ABR_MSG_SUBSCRIBE = 17,
    ABR_MSG_UNSUBSCRIBE = 18,  // no payload
    ABR_MSG_COMMAND = 19,
    ABR_MSG_SPATIAL_CONFIG = 20,
    // Network pairing (Bridge/BRIDGE_NETWORK.md): only on a pairing connection, never on a display connection.
    ABR_MSG_PAIR_REQUEST = 32,   // plugin → display: the Mac asking to be paired (after the pairing-code handshake)
    ABR_MSG_PAIR_GRANT = 33,     // display → plugin: the receiver's ID, name and the pair's key
    ABR_MSG_PAIR_DENY = 34,      // display → plugin: refused (by the person, or the pairing closed)
};
// Version 2 types, never sent by version 3: FORMAT (3) and AUDIO (4).

// What the plugin is doing with the audio at its insertion point.
enum {
    ABR_STATE_INACTIVE = 0,   // not activated by the host, or not yet configured
    ABR_STATE_LIVE = 1,       // real-time processing; the audio is analysed
    ABR_STATE_BYPASSED = 2,   // host or user bypass: audio passes, nothing is analysed
    ABR_STATE_OFFLINE = 3,    // offline (bounce/export) render: audio passes, nothing is analysed as live
};

// The analysis' measurement state.
enum {
    ABR_MEASUREMENT_NONE = 0,       // no analysis: never configured, or a channel layout it cannot measure
    ABR_MEASUREMENT_MEASURING = 1,
    ABR_MEASUREMENT_PAUSED = 2,     // paused by a COMMAND: audio passes and is not accumulated
};

enum { ABR_FORMAT_VST3 = 1, ABR_FORMAT_AU = 2, ABR_FORMAT_TEST = 99 };
// Channel layouts. Stereo order is L, R; a SPEAKERS layout gives each channel's speaker role (STATUS 21, RESULT 18).
enum { ABR_LAYOUT_UNKNOWN = 0, ABR_LAYOUT_MONO = 1, ABR_LAYOUT_STEREO = 2, ABR_LAYOUT_SPEAKERS = 3 };

// Speaker roles, the same indices as Sources/AnalysisCore/Role.swift. LS/RS are the surrounds of a 5.x bed and the
// side surrounds of a 7.x or 9.x bed (whose rear surrounds are LRS/RRS); a .2 bed's one height pair is LTF/RTF.
enum {
    ABR_ROLE_L = 0, ABR_ROLE_R = 1, ABR_ROLE_C = 2, ABR_ROLE_LFE = 3, ABR_ROLE_LS = 4, ABR_ROLE_RS = 5,
    ABR_ROLE_LTF = 6, ABR_ROLE_RTF = 7, ABR_ROLE_LRS = 8, ABR_ROLE_RRS = 9, ABR_ROLE_LW = 10, ABR_ROLE_RW = 11,
    ABR_ROLE_LTM = 12, ABR_ROLE_RTM = 13, ABR_ROLE_LTR = 14, ABR_ROLE_RTR = 15,
    ABR_ROLE_COUNT = 16,
};

// STATUS flags and break reasons.
enum {
    ABR_TRANSPORT_KNOWN = 1u << 0,         // the host reported its transport state
    ABR_TRANSPORT_PLAYING = 1u << 1,       // … and it was playing
    ABR_TRANSPORT_POSITION = 1u << 2,      // (internal) the block carries a timeline position
    ABR_AUDIO_DISCONTINUITY = 1u << 8,     // the audio before this point is missing or is not its predecessor
    ABR_AUDIO_AFTER_DROP = 1u << 9,        // … frames were dropped (the analysis queue was full)
    ABR_AUDIO_AFTER_IDLE = 1u << 10,       // … the host stopped calling the plugin
    ABR_AUDIO_AFTER_BYPASS = 1u << 11,     // … the insert was bypassed
    ABR_AUDIO_AFTER_OFFLINE = 1u << 12,    // … the host rendered offline in between
    ABR_AUDIO_AFTER_RESTART = 1u << 13,    // … the host deactivated and reactivated the plugin
    ABR_AUDIO_STREAM_START = 1u << 14,     // first audio of this analysis generation
    ABR_AUDIO_TRANSPORT_JUMP = 1u << 15,   // the host's timeline jumped (locate, loop) while playing: the signal
                                           // is still continuous, so this alone is not a break
    ABR_STATUS_SUBSCRIBED = 1u << 16,      // STATUS: the plugin is sending results
};
#define ABR_AUDIO_REASONS (ABR_AUDIO_AFTER_DROP | ABR_AUDIO_AFTER_IDLE | ABR_AUDIO_AFTER_BYPASS | \
                           ABR_AUDIO_AFTER_OFFLINE | ABR_AUDIO_AFTER_RESTART | ABR_AUDIO_STREAM_START)

// HELLO identity flags.
enum {
    ABR_IDENTITY_RESTORED = 1u << 0,   // persistent_id came from the host's saved state (project, preset, undo)
    ABR_IDENTITY_COPY = 1u << 1,       // the saved state carried restored_id, which another live instance of this
                                       // plugin in this process already uses: this instance is a copy and kept an
                                       // identity of its own
};

// HELLO capabilities: the commands this plugin carries out.
enum {
    ABR_CAPABILITY_RESULTS = 1u << 0,
    ABR_CAPABILITY_RESET = 1u << 1,
    ABR_CAPABILITY_RESET_TRUE_PEAK = 1u << 2,
    ABR_CAPABILITY_PAUSE = 1u << 3,
    ABR_CAPABILITY_SPATIAL_CONFIG = 1u << 4,  // applies SPATIAL_CONFIG and then sends observations (RESULT 58)
};

// SPATIAL_CONFIG: fields written and read by the analysis core (SpatialConfigWire.swift); the transport only checks the
// length. SPATIAL_ACK outcomes, and its fields.
#define ABR_SPATIAL_CONFIG_MAX 1000u
enum {
    ABR_SPATIAL_APPLIED = 0,        // in force from the next spatial transform; RESULT 58 carries its hash
    ABR_SPATIAL_INVALID = 1,        // a field missing, malformed or out of range, or unusable for this bus: unchanged
    ABR_SPATIAL_HASH_MISMATCH = 2,  // the content does not match its hash: unchanged
    ABR_SPATIAL_UNSUPPORTED = 3,    // a version or option this plugin does not know: unchanged
};
enum {  // SPATIAL_ACK
    ABR_SPATIAL_ACK_REVISION = 1,    // u32: the configuration's revision
    ABR_SPATIAL_ACK_HASH = 2,        // u64: its content hash (0 when refused)
    ABR_SPATIAL_ACK_OUTCOME = 3,     // u32: ABR_SPATIAL_*
    ABR_SPATIAL_ACK_GENERATION = 4,  // u32: the analysis generation it applies to
    ABR_SPATIAL_ACK_FRAMES = 5,      // u64: frames that generation had analysed when it took effect
    ABR_SPATIAL_ACK_SESSION_ID = 6,  // bytes[16]: the instance that answered
};

// COMMAND codes and ACK outcomes.
enum {
    ABR_COMMAND_RESET = 1,              // start a new analysis generation: every measurement starts afresh
    ABR_COMMAND_RESET_TRUE_PEAK = 2,    // clear the held true peaks only
    ABR_COMMAND_PAUSE = 3,              // pause measurement (the shared analysis, for every display)
    ABR_COMMAND_RESUME = 4,             // resume it, continuing the same measurement
};
enum {
    ABR_ACK_DONE = 0,
    ABR_ACK_WRONG_SESSION = 1,     // the command named another live instance (an obsolete selection)
    ABR_ACK_STALE_GENERATION = 2,  // the command expected a generation that is no longer current
    ABR_ACK_UNSUPPORTED = 3,
    ABR_ACK_NO_ANALYSIS = 4,       // nothing to act on: no usable format yet
};

// Field tags, per message type (a RESULT's are in ResultProtocol.swift).
enum {  // HELLO, after the fixed prefix
    ABR_HELLO_SESSION_ID = 1,        // bytes[16]: random per plugin instance lifetime
    ABR_HELLO_PERSISTENT_ID = 2,     // bytes[16]: saved in the DAW project
    ABR_HELLO_RESTORED_ID = 3,       // bytes[16]: with ABR_IDENTITY_COPY, the identity the saved state carried
    ABR_HELLO_IDENTITY_FLAGS = 4,    // u32
    ABR_HELLO_HOST_PID = 5,          // i64
    ABR_HELLO_HOST_NAME = 6,         // utf8 ≤ 63
    ABR_HELLO_HOST_BUNDLE_ID = 7,    // utf8 ≤ 95
    ABR_HELLO_PLUGIN_VERSION = 8,    // utf8 ≤ 31
    ABR_HELLO_SCHEMA = 9,            // u32: RESULT schema the plugin writes
    ABR_HELLO_CAPABILITIES = 10,     // u32: ABR_CAPABILITY_*
    // Over the network only (BRIDGE_NETWORK.md); a display that does not know them skips them.
    ABR_HELLO_DEVICE_ID = 11,        // bytes[16]: the sending Mac's pairing ID (its PSK identity)
    ABR_HELLO_COMPUTER_NAME = 12,    // utf8 ≤ 63: the sending Mac's name
};
enum {  // PAIR_REQUEST
    ABR_PAIR_DEVICE_ID = 1,          // bytes[16]
    ABR_PAIR_COMPUTER_NAME = 2,      // utf8 ≤ 63
    ABR_PAIR_HOST_NAME = 3,          // utf8 ≤ 63: the DAW
    ABR_PAIR_PLUGIN_VERSION = 4,     // utf8 ≤ 31
};
enum {  // PAIR_GRANT, PAIR_DENY
    ABR_PAIR_RECEIVER_ID = 1,        // bytes[16]
    ABR_PAIR_RECEIVER_NAME = 2,      // utf8 ≤ 63
    ABR_PAIR_KEY = 3,                // bytes[32]: the pre-shared key of this Mac and this display
    ABR_PAIR_DENY_REASON = 1,        // utf8 ≤ 127
};
enum {  // WELCOME, after the fixed prefix
    ABR_WELCOME_SCHEMA = 1,          // u32: newest RESULT schema the application reads
    ABR_WELCOME_CAPABILITIES = 2,    // u32: ABR_DISPLAY_* (after build 98; absent: none)
};
// WELCOME capabilities: what the display does with the results.
enum {
    ABR_DISPLAY_KEEPS_OBSERVATIONS = 1u << 0,  // keeps a RESULT's observations (tag 58) until one carries new ones, so
                                               // each observation frame is sent to it once
};
enum {  // STATUS
    ABR_STATUS_STATE = 1,            // u32: ABR_STATE_*
    ABR_STATUS_FORMAT_EPOCH = 2,     // u32: changes with the sample rate or channel count (0: never configured)
    ABR_STATUS_SAMPLE_RATE = 3,      // f64
    ABR_STATUS_CHANNELS = 4,         // u32
    ABR_STATUS_LAYOUT = 5,           // u32: ABR_LAYOUT_*
    ABR_STATUS_MAX_BLOCK = 6,        // u32
    ABR_STATUS_FLAGS = 7,            // u32: ABR_TRANSPORT_*, ABR_STATUS_SUBSCRIBED
    ABR_STATUS_FRAMES_PROCESSED = 8, // u64: live frames in this session
    ABR_STATUS_FRAMES_DROPPED = 9,   // u64: live frames the analysis could not take (its queue was full)
    ABR_STATUS_INTERRUPTIONS = 10,   // u32: breaks in the live stream (bypass, offline, idle, restart)
    ABR_STATUS_TRANSPORT_JUMPS = 11, // u32: timeline jumps while playing
    ABR_STATUS_SOURCE_NAME = 12,     // utf8 ≤ 127: the name set in the plugin, else the host's track name
    ABR_STATUS_TRACK_NAME = 13,      // utf8 ≤ 127
    ABR_STATUS_CHANNEL_ID = 14,      // utf8 ≤ 63: the host's unique channel ID, when it gives one
    ABR_STATUS_GENERATION = 15,      // u32: current analysis generation (0: none)
    ABR_STATUS_MEASUREMENT = 16,     // u32: ABR_MEASUREMENT_*
    ABR_STATUS_FRAMES_ANALYSED = 17, // u64: in this generation
    ABR_STATUS_LAST_BREAK = 18,      // u32: reasons of the newest break the analysis saw
    ABR_STATUS_BACKLOG_MS = 19,      // u32: audio waiting to be analysed
    ABR_STATUS_SECONDS_SINCE_AUDIO = 20,  // f64: since the host last delivered live audio (< 0: never)
    ABR_STATUS_ROLES = 21,           // u8[channels]: each channel's speaker role (ABR_ROLE_*), in the bus's order
    ABR_STATUS_LAYOUT_NAME = 22,     // utf8 ≤ 15: the layout as the plugin names it ("Stereo", "5.1", "7.1.4")
};
enum {  // SUBSCRIBE
    ABR_SUBSCRIBE_SUBSCRIPTION = 1,  // u32, non-zero: echoed in every RESULT of this subscription
    ABR_SUBSCRIBE_SPECTROGRAM = 2,   // u32: the waterfall analysis wanted, 0 Classic (default), 1 Enhanced
    ABR_SUBSCRIBE_SPECTRUM = 3,      // u32: what the spectrum and spectrogram sum, 0 L and R (default), 1 every channel
    ABR_SUBSCRIBE_COHERENCE = 4,     // u32: the spatial field's coherence threshold in thousandths (50–950); absent or
                                     // 0: the default 300 (build 80 and later)
};
enum {  // COMMAND
    ABR_COMMAND_ID = 1,              // u32: chosen by the application, echoed in the ACK
    ABR_COMMAND_CODE = 2,            // u32: ABR_COMMAND_*
    ABR_COMMAND_SESSION_ID = 3,      // bytes[16]: the instance it is meant for
    ABR_COMMAND_GENERATION = 4,      // u32: the generation it is meant for (0: whichever is current)
};
enum {  // ACK
    ABR_ACK_COMMAND_ID = 1,          // u32
    ABR_ACK_COMMAND_CODE = 2,        // u32
    ABR_ACK_OUTCOME = 3,             // u32: ABR_ACK_*
    ABR_ACK_GENERATION = 4,          // u32: the generation after the command
    ABR_ACK_MEASUREMENT = 5,         // u32: the measurement state after the command
    ABR_ACK_SESSION_ID = 6,          // bytes[16]: the instance that answered
};

#pragma pack(push, 4)
typedef struct {
    uint32_t magic;
    uint16_t type;
    uint16_t flags;
    uint32_t length;     // payload bytes after this header
    uint32_t sequence;   // per-connection message counter, for debugging
} AbrHeader;
#pragma pack(pop)
_Static_assert(sizeof(AbrHeader) == 16, "header layout");

// HELLO and WELCOME begin with these two words in every protocol version.
#define ABR_HELLO_MIN_BYTES 8u

#endif
