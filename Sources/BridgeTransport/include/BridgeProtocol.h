#ifndef AURALISCOPE_BRIDGE_PROTOCOL_H
#define AURALISCOPE_BRIDGE_PROTOCOL_H

// Auraliscope Bridge local transport, protocol version 1.
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
//   app → plugin   SUBSCRIBE / UNSUBSCRIBE   start or stop AUDIO for this instance
//
// Stream positions count every frame the instance processed live (not bypassed, not offline) in this session,
// whether or not it was transmitted. A receiver that sees an AUDIO position beyond the end of the previous block
// has lost exactly the difference; ABR_AUDIO_DISCONTINUITY marks the block after any loss the sender knows about.

#include <stdint.h>

#define ABR_PROTOCOL_VERSION 1u
#define ABR_MAGIC 0x47524241u  // "ABRG" in memory order
#define ABR_MAX_CHANNELS 2u
#define ABR_MAX_PAYLOAD (1u << 20)
#define ABR_STATUS_INTERVAL_MS 250u

enum {
    ABR_MSG_HELLO = 1,
    ABR_MSG_STATUS = 2,
    ABR_MSG_FORMAT = 3,
    ABR_MSG_AUDIO = 4,
    ABR_MSG_FOCUS = 5,        // no payload; a receiver that predates it ignores it
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

// STATUS flags and AUDIO flags.
enum {
    ABR_TRANSPORT_KNOWN = 1u << 0,       // the host reported its transport state
    ABR_TRANSPORT_PLAYING = 1u << 1,     // … and it was playing
    ABR_AUDIO_DISCONTINUITY = 1u << 8,   // frames before this block were dropped, or the stream (re)started
    ABR_STATUS_SUBSCRIBED = 1u << 16,    // the plugin believes it is transmitting
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
    uint8_t persistent_id[16];     // saved in the DAW project: the same insert after a reload (copies share it)
    int32_t host_pid;
    uint32_t reserved;
    char host_name[64];            // UTF-8, NUL-terminated: the DAW's process name
    char plugin_version[32];
} AbrHello;

typedef struct {
    uint32_t state;                // ABR_STATE_*
    uint32_t format_epoch;         // current format epoch (0 = never configured)
    double sample_rate;
    uint32_t channels;
    uint32_t layout;               // ABR_LAYOUT_*
    uint32_t max_block_frames;
    uint32_t flags;                // ABR_TRANSPORT_*, ABR_STATUS_SUBSCRIBED
    uint64_t frames_processed;     // live frames in this session (the stream position of the next frame)
    uint64_t frames_dropped;       // live frames the plugin could not queue or send while subscribed
    char source_name[128];         // user-facing name: the name set in the plugin, else the host's track name
    char track_name[128];          // the host's name for the track or channel, when it gives one
} AbrStatus;

typedef struct {
    uint32_t format_epoch;
    uint32_t channels;
    double sample_rate;
    uint32_t layout;               // ABR_LAYOUT_*
    uint32_t sample_format;        // ABR_SAMPLE_*
} AbrFormat;

typedef struct {
    uint32_t format_epoch;
    uint32_t frames;
    uint64_t position;             // stream position of the first frame
    uint32_t channels;
    uint32_t flags;                // ABR_AUDIO_*, ABR_TRANSPORT_*
    // followed by frames × channels float32 samples, interleaved
} AbrAudio;

typedef struct {
    uint32_t protocol_version;
    uint32_t reserved;
} AbrWelcome;
#pragma pack(pop)

_Static_assert(sizeof(AbrHeader) == 16, "header layout");
_Static_assert(sizeof(AbrHello) == 144, "hello layout");
_Static_assert(sizeof(AbrStatus) == 304, "status layout");
_Static_assert(sizeof(AbrFormat) == 24, "format layout");
_Static_assert(sizeof(AbrAudio) == 24, "audio layout");

#endif
