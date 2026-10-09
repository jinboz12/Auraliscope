#ifndef AURALISCOPE_BRIDGE_SERVER_H
#define AURALISCOPE_BRIDGE_SERVER_H

// The application end of the Bridge transport (protocol version 3): listens for plugin instances, keeps what each
// one reported, and delivers the analysis results of the one selected instance to a sink. One background thread
// does all socket work; the sink is called on that thread, never on a real-time thread, and never blocks the
// plugins (they keep only their newest result for a receiver that is slow).

#include <stddef.h>
#include <stdint.h>
#include "BridgeProtocol.h"

typedef struct AbrServer AbrServer;

// Receives one RESULT payload of the selected instance's current subscription, on the server thread. The payload
// is only valid during the call.
typedef void (*AbrResultSink)(void *_Nullable context, const uint8_t *_Nonnull payload, uint32_t length);

// One connected plugin instance, as last reported.
typedef struct {
    uint8_t session_id[16];
    uint8_t persistent_id[16];
    uint8_t restored_id[16];         // with ABR_IDENTITY_COPY: the identity its saved state carried
    uint32_t identity_flags;         // ABR_IDENTITY_*
    uint32_t protocol_version;
    int compatible;                  // 0: another protocol version; listed so it can be named, never selected
    uint32_t plugin_format;          // ABR_FORMAT_*
    int32_t host_pid;
    uint32_t schema;                 // RESULT schema the plugin writes
    uint32_t capabilities;           // ABR_CAPABILITY_*
    char host_name[64];
    char host_bundle_id[96];
    char plugin_version[32];
    char source_name[128];
    char track_name[128];
    char channel_id[64];
    uint32_t state;                  // ABR_STATE_*
    uint32_t status_flags;           // ABR_TRANSPORT_*, ABR_STATUS_SUBSCRIBED
    uint32_t format_epoch;
    double sample_rate;
    uint32_t channels;
    uint32_t layout;
    uint32_t max_block_frames;
    uint64_t frames_processed;       // as reported by the plugin
    uint64_t frames_dropped_by_plugin;  // live frames its analysis could not take
    uint32_t plugin_interruptions;   // live-stream breaks the plugin counted (bypass, offline, idle, restart)
    uint32_t transport_jumps;        // timeline jumps while playing (locate, loop), as reported
    uint32_t generation;             // the plugin's current analysis generation (0: none)
    uint32_t measurement;            // ABR_MEASUREMENT_*
    uint64_t frames_analysed;        // in that generation
    uint32_t last_break_reasons;     // of the newest break its analysis saw
    uint32_t backlog_ms;             // audio waiting for its analysis thread
    double plugin_seconds_since_audio;  // since the host last delivered live audio to it (< 0: never)
    uint64_t results_received;       // RESULTs that arrived here
    uint64_t results_delivered;      // … handed to the sink
    uint64_t results_stale;          // … of an earlier subscription (in flight when it changed): dropped
    uint64_t results_malformed;      // … without a readable subscription field: dropped
    uint32_t acks_received;
    uint32_t last_ack_id;            // the newest ACK: which command, and what came of it
    uint32_t last_ack_command;
    uint32_t last_ack_outcome;       // ABR_ACK_*
    uint32_t last_ack_generation;
    uint32_t last_ack_measurement;
    double seconds_since_message;
    double seconds_since_result;     // < 0 when no result arrived yet
    uint32_t connection_serial;      // increments per accepted connection; unique while the server runs
    int selected;                    // 1 for the selected instance
    int delivering;                  // 1 while its results reach the sink
    uint32_t focus_requests;         // FOCUS messages received: the owner selects the instance when this grows
} AbrSourceInfo;

// Starts listening at `path` (NULL: abr_socket_path()). On failure returns NULL and writes a reason to `error`.
AbrServer *_Nullable abr_server_start(const char *_Nullable path, char *_Nullable error, size_t error_size);
void abr_server_stop(AbrServer *_Nullable server);

// Copies up to `capacity` sources, in connection order; returns how many there are in total. Plugins of another
// protocol version are included with `compatible` 0.
uint32_t abr_server_sources(AbrServer *_Nonnull server, AbrSourceInfo *_Nullable out, uint32_t capacity);

// Closes the connection of one instance (as if it had broken) and turns it away for `refuse_ms`; the plugin
// reconnects by itself after that. For diagnostics: it lets a test watch a display wait for, and carry on with,
// the same live insert.
void abr_server_disconnect(AbrServer *_Nonnull server, const uint8_t *_Nonnull session_id, uint32_t refuse_ms);

// Subscribes to one instance (NULL: none); the previous one is unsubscribed. Each subscription gets a new number,
// and only results sent for it are delivered: nothing queued for an earlier one is ever replayed.
void abr_server_select(AbrServer *_Nonnull server, const uint8_t *_Nullable session_id);

// The waterfall analysis to ask every subscription for (ABR_SUBSCRIBE_SPECTROGRAM: 0 Classic, 1 Enhanced). A change
// reaches the subscribed instance at once, without a new subscription.
void abr_server_set_spectrogram(AbrServer *_Nonnull server, uint32_t mode);

// Delivers the selected instance's results to `sink` until detached.
void abr_server_attach(AbrServer *_Nonnull server, AbrResultSink _Nonnull sink, void *_Nullable context);
// After return, the sink is not running and will not be called again.
void abr_server_detach(AbrServer *_Nonnull server);

// Sends a COMMAND (ABR_COMMAND_*) to one instance, for analysis generation `generation` (0: whichever is current).
// Returns the command's ID (never 0); its ACK shows up in that instance's `last_ack_*` fields. Returns 0 when the
// instance is not connected.
uint32_t abr_server_command(AbrServer *_Nonnull server, const uint8_t *_Nonnull session_id, uint32_t command,
                            uint32_t generation);

#endif
