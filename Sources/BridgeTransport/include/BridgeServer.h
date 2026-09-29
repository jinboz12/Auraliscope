#ifndef AURALISCOPE_BRIDGE_SERVER_H
#define AURALISCOPE_BRIDGE_SERVER_H

// The application end of the Bridge transport: listens for plugin instances, keeps what each one reported, and
// delivers the audio of the one selected instance to a sink. One background thread does all socket work; the
// sink is called on that thread, never on a real-time thread, and never blocks the plugins (they drop audio
// instead, and the drop shows up here as lost frames).

#include <stddef.h>
#include <stdint.h>
#include "BridgeProtocol.h"

typedef struct AbrServer AbrServer;

// Receives the selected instance's interleaved float32 PCM on the server thread.
typedef void (*AbrSink)(void *_Nullable context, const float *_Nonnull interleaved, uint32_t frames, uint32_t channels);

// One connected plugin instance, as last reported.
typedef struct {
    uint8_t session_id[16];
    uint8_t persistent_id[16];
    uint32_t protocol_version;
    uint32_t plugin_format;          // ABR_FORMAT_*
    int32_t host_pid;
    char host_name[64];
    char plugin_version[32];
    char source_name[128];
    char track_name[128];
    uint32_t state;                  // ABR_STATE_*
    uint32_t status_flags;           // ABR_TRANSPORT_*, ABR_STATUS_SUBSCRIBED
    uint32_t format_epoch;           // from the newest STATUS or FORMAT
    double sample_rate;
    uint32_t channels;
    uint32_t layout;
    uint32_t max_block_frames;
    uint64_t frames_processed;       // as reported by the plugin
    uint64_t frames_dropped_by_plugin;
    uint64_t frames_received;        // AUDIO frames that arrived here
    uint64_t frames_delivered;       // … handed to the sink
    uint64_t frames_lost;            // position gaps seen while delivering
    uint64_t discontinuities;        // gaps or flagged restarts seen while delivering
    uint64_t frames_discarded;       // arrived for a format epoch the sink was not attached to
    double seconds_since_message;
    double seconds_since_audio;      // < 0 when no audio arrived yet
    uint32_t connection_serial;      // increments per accepted connection; unique while the server runs
    int selected;                    // 1 for the selected instance
    int delivering;                  // 1 while its audio reaches the sink
    uint32_t delivered_epoch;        // the epoch the sink is attached to (when selected)
    uint32_t focus_requests;         // FOCUS messages received: the owner selects the instance when this grows
} AbrSourceInfo;

// Starts listening at `path` (NULL: abr_socket_path()). On failure returns NULL and writes a reason to `error`.
AbrServer *_Nullable abr_server_start(const char *_Nullable path, char *_Nullable error, size_t error_size);
void abr_server_stop(AbrServer *_Nullable server);

// Copies up to `capacity` sources, in connection order; returns how many there are in total.
uint32_t abr_server_sources(AbrServer *_Nonnull server, AbrSourceInfo *_Nullable out, uint32_t capacity);

// Subscribes to one instance (NULL: none); the previous one is unsubscribed. Also detaches the sink.
void abr_server_select(AbrServer *_Nonnull server, const uint8_t *_Nullable session_id);

// Delivers the selected instance's audio of `format_epoch` to `sink` until detached. Audio of any other epoch is
// discarded and counted: the owner re-attaches after it has reconfigured for the new format.
void abr_server_attach(AbrServer *_Nonnull server, uint32_t format_epoch, AbrSink _Nonnull sink, void *_Nullable context);
// After return, the sink is not running and will not be called again.
void abr_server_detach(AbrServer *_Nonnull server);

#endif
