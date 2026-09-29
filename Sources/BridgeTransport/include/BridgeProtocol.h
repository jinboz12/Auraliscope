#ifndef AURALISCOPE_BRIDGE_PROTOCOL_H
#define AURALISCOPE_BRIDGE_PROTOCOL_H

// Auraliscope Bridge local transport, protocol version 2.
//
// One Unix-domain stream socket per plugin instance. The desktop application listens at
// `abr_socket_path()`; every plugin instance (VST3 or AU alike) connects as a client. Nothing here depends on a
// plugin format: the plugin wrappers and the application share this header and nothing else.
//
// Every message is a 16-byte `AbrHeader` followed by `length` payload bytes. All integers and samples are
// little-endian (both ends run on the same Mac; the field is fixed so a later network relay can keep it).
//
//   plugin → app   HELLO     once, first message after connecting: identity
//   plugin → app   STATUS    on every change and at least every ABR_STATUS_INTERVAL_MS: state, name, counters
//   plugin → app   FORMAT    before the first AUDIO of each format epoch: sample rate, channels, layout, sample format
//   plugin → app   AUDIO     only while subscribed: one block of interleaved samples with its stream position
//   plugin → app   FOCUS     the user clicked "Show in Auraliscope": make this instance the active source
//   app → plugin   WELCOME   reply to HELLO: the application's protocol version
//   app → plugin   SUBSCRIBE (with a subscription number) / UNSUBSCRIBE   start or stop AUDIO for this instance
//
// Stream positions count every frame the instance processed live (not bypassed, not offline) in this session,
// whether or not it was transmitted. A receiver that sees an AUDIO position beyond the end of the previous block
// has lost exactly the difference. The first block after anything that broke the live stream carries
// ABR_AUDIO_DISCONTINUITY and a reason bit; see the ABR_AUDIO_AFTER_* flags.
//
// Every AUDIO block names the subscription it was captured for. A receiver delivers only blocks of its current
// subscription, so audio queued (in the plugin or the socket) before an unsubscribe is never replayed into a
// later subscription of the same instance.
//
// Version 2 changed the HELLO, STATUS, SUBSCRIBE and AUDIO layouts. A receiver lists a plugin of another version
// as needing an update and does not talk to it further; a plugin that finds an older receiver says so and
// retries slowly.

#include <stdint.h>

#define ABR_PROTOCOL_VERSION 2u
#define ABR_MAGIC 0x47524241u  // "ABRG" in memory order
#define ABR_MAX_CHANNELS 2u
#define ABR_MAX_PAYLOAD (1u << 20)
#define ABR_STATUS_INTERVAL_MS 250u

enum {
    ABR_MSG_HELLO = 1,
    ABR_MSG_STATUS = 2,
    ABR_MSG_FORMAT = 3,
    ABR_MSG_AUDIO = 4,
    ABR_MSG_FOCUS = 5,        // no payload
    ABR_MSG_WELCOME = 16,
    ABR_MSG_SUBSCRIBE = 17,
    ABR_MSG_UNSUBSCRIBE = 18,
};

// What the plugin is doing with the audio at its insertion point.
enum {
    ABR_STATE_INACTIVE = 0,   // not activated by the host, or not yet configured
    ABR_STATE_LIVE = 1,       // real-time processing; audio is transmitted while subscribed
    ABR_STATE_BYPASSED = 2,   // host or user bypass: audio passes, nothing is transmitted
    ABR_STATE_OFFLINE = 3,    // offline (bounce/export) render: audio passes, nothing is transmitted
};

enum { ABR_FORMAT_VST3 = 1, ABR_FORMAT_AU = 2, ABR_FORMAT_TEST = 99 };
enum { ABR_LAYOUT_UNKNOWN = 0, ABR_LAYOUT_MONO = 1, ABR_LAYOUT_STEREO = 2 };  // stereo order is L, R
enum { ABR_SAMPLE_FLOAT32_INTERLEAVED = 1 };

// STATUS flags and AUDIO flags share one namespace.
enum {
    ABR_TRANSPORT_KNOWN = 1u << 0,         // the host reported its transport state
    ABR_TRANSPORT_PLAYING = 1u << 1,       // … and it was playing
    ABR_TRANSPORT_POSITION = 1u << 2,      // AUDIO: transport_position is valid
    ABR_AUDIO_DISCONTINUITY = 1u << 8,     // the audio before this block is missing or is not its predecessor
    ABR_AUDIO_AFTER_DROP = 1u << 9,        // … frames were dropped (the position gap says how many)
    ABR_AUDIO_AFTER_IDLE = 1u << 10,       // … the host stopped calling the plugin for idle_ms
    ABR_AUDIO_AFTER_BYPASS = 1u << 11,     // … the insert was bypassed
    ABR_AUDIO_AFTER_OFFLINE = 1u << 12,    // … the host rendered offline in between
    ABR_AUDIO_AFTER_RESTART = 1u << 13,    // … the host deactivated and reactivated the plugin
    ABR_AUDIO_STREAM_START = 1u << 14,     // first block of this subscription
    ABR_AUDIO_TRANSPORT_JUMP = 1u << 15,   // the host's timeline jumped (locate, loop) while playing: the signal
                                           // is still continuous, so this alone is not a discontinuity
    ABR_STATUS_SUBSCRIBED = 1u << 16,      // STATUS: the plugin believes it is transmitting
};
#define ABR_AUDIO_REASONS (ABR_AUDIO_AFTER_DROP | ABR_AUDIO_AFTER_IDLE | ABR_AUDIO_AFTER_BYPASS | \
                           ABR_AUDIO_AFTER_OFFLINE | ABR_AUDIO_AFTER_RESTART | ABR_AUDIO_STREAM_START)

// HELLO identity flags.
enum {
    ABR_IDENTITY_RESTORED = 1u << 0,   // persistent_id came from the host's saved state (project, preset, undo)
    ABR_IDENTITY_COPY = 1u << 1,       // the saved state carried restored_id, which another live instance of this
                                       // plugin in this process already uses: this instance is a copy (duplicated
                                       // track, pasted settings, a second project with the same inserts) and
                                       // kept an identity of its own
};

#pragma pack(push, 4)
typedef struct {
    uint32_t magic;
    uint16_t type;
    uint16_t reserved;
    uint32_t length;     // payload bytes after this header
    uint32_t sequence;   // per-connection message counter, for debugging
} AbrHeader;

typedef struct {
    uint32_t protocol_version;
    uint32_t plugin_format;        // ABR_FORMAT_*
    uint8_t session_id[16];        // random per plugin instance lifetime: identifies this live instance
    uint8_t persistent_id[16];     // saved in the DAW project: the same insert after a reload
    uint8_t restored_id[16];       // with ABR_IDENTITY_COPY: the identity the saved state carried; else zero
    uint32_t identity_flags;       // ABR_IDENTITY_*
    int32_t host_pid;
    char host_name[64];            // UTF-8, NUL-terminated: the DAW's process name
    char host_bundle_id[96];       // the DAW's bundle identifier, when it has one
    char plugin_version[32];
} AbrHello;

typedef struct {
    uint32_t state;                // ABR_STATE_*
    uint32_t format_epoch;         // current format epoch (0 = never configured); changes with rate or channels
    double sample_rate;
    uint32_t channels;
    uint32_t layout;               // ABR_LAYOUT_*
    uint32_t max_block_frames;
    uint32_t flags;                // ABR_TRANSPORT_*, ABR_STATUS_SUBSCRIBED
    uint64_t frames_processed;     // live frames in this session (the stream position of the next frame)
    uint64_t frames_dropped;       // live frames the plugin could not queue or send while subscribed
    uint32_t interruptions;        // times the live stream broke (bypass, offline, idle, restart) in this session
    uint32_t transport_jumps;      // timeline jumps while playing (locate, loop)
    char source_name[128];         // user-facing name: the name set in the plugin, else the host's track name
    char track_name[128];          // the host's name for the track or channel, when it gives one
    char channel_id[64];           // the host's own unique ID for the channel, when it gives one (VST3 hosts)
} AbrStatus;

typedef struct {
    uint32_t format_epoch;
    uint32_t channels;
    double sample_rate;
    uint32_t layout;               // ABR_LAYOUT_*
    uint32_t sample_format;        // ABR_SAMPLE_*
} AbrFormat;

typedef struct {
    uint32_t subscription;         // the SUBSCRIBE this block was captured for
    uint32_t format_epoch;
    uint64_t position;             // stream position of the first frame
    uint32_t frames;
    uint32_t channels;
    uint32_t flags;                // ABR_AUDIO_*, ABR_TRANSPORT_*
    uint32_t idle_ms;              // with ABR_AUDIO_AFTER_IDLE: how long the host did not process (capped)
    int64_t transport_position;    // with ABR_TRANSPORT_POSITION: the host timeline sample of the first frame
    // followed by frames × channels float32 samples, interleaved
} AbrAudio;

typedef struct {
    uint32_t protocol_version;
    uint32_t reserved;
} AbrWelcome;

typedef struct {
    uint32_t subscription;         // non-zero; echoed in every AUDIO of this subscription
    uint32_t reserved;
} AbrSubscribe;
#pragma pack(pop)

_Static_assert(sizeof(AbrHeader) == 16, "header layout");
_Static_assert(sizeof(AbrHello) == 256, "hello layout");
_Static_assert(sizeof(AbrStatus) == 376, "status layout");
_Static_assert(sizeof(AbrFormat) == 24, "format layout");
_Static_assert(sizeof(AbrAudio) == 40, "audio layout");
_Static_assert(sizeof(AbrSubscribe) == 8, "subscribe layout");

// Version 1 HELLO began with the same two words, so any version can be recognised from them.
#define ABR_HELLO_MIN_BYTES 8u

#endif
