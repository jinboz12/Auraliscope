#include "BridgeServer.h"
#include "BridgePaths.h"
#include "BridgeWire.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>

#define MAX_CLIENTS 64
#define POLL_MS 50
#define MAX_PENDING_COMMANDS 8

typedef struct {
    uint32_t id, code, generation;
} PendingCommand;

typedef struct {
    int fd;
    uint8_t *buffer;
    size_t used, capacity;
    bool greeted;                 // a HELLO of this protocol version arrived (written under AbrServer.lock)
    bool incompatible;            // a HELLO of another version: listed, otherwise ignored (ditto)
    bool drop;                    // abr_server_disconnect asked for it to be closed (under AbrServer.lock)
    bool subscribed;              // what the server last told the plugin
    uint64_t subscribed_selection; // the selection generation that SUBSCRIBE belongs to
    uint32_t subscription;        // the number sent with that SUBSCRIBE (0: none); other results are stale
    uint32_t subscribed_spectrogram; // the ABR_SUBSCRIBE_SPECTROGRAM sent with it
    uint32_t subscribed_spectrum;    // the ABR_SUBSCRIBE_SPECTRUM sent with it
    uint32_t subscribed_coherence;   // the ABR_SUBSCRIBE_COHERENCE sent with it
    uint32_t send_sequence;
    _Atomic uint64_t last_message_ns, last_result_ns;  // read by abr_server_sources on another thread
    PendingCommand commands[MAX_PENDING_COMMANDS];  // to send (under AbrServer.lock)
    uint32_t pending_commands;
    AbrSourceInfo info;           // guarded by AbrServer.lock
} Client;

struct AbrServer {
    int listen_fd;
    int wake[2];
    pthread_t thread;
    atomic_bool stopping;
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    pthread_mutex_t lock;         // clients' info and the selection
    Client *clients[MAX_CLIENTS];
    uint32_t count;
    uint32_t next_serial;
    uint8_t selected[16];
    bool has_selection;
    uint64_t selection;           // bumped by every abr_server_select, even of the same instance
    uint32_t spectrogram;         // ABR_SUBSCRIBE_SPECTROGRAM for every subscription (under `lock`)
    uint32_t spectrum;            // ABR_SUBSCRIBE_SPECTRUM, likewise
    uint32_t coherence;           // ABR_SUBSCRIBE_COHERENCE, likewise (0: the plugin's default)
    uint8_t refused[16];          // abr_server_disconnect: this session is turned away until refused_until
    uint64_t refused_until;
    uint32_t next_subscription;   // server thread only
    uint32_t next_command;        // under `lock`
    pthread_mutex_t sink_lock;    // held while the sink runs
    AbrResultSink sink;
    void *sink_context;
};

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void set_error(char *error, size_t size, const char *message) {
    if (error && size) snprintf(error, size, "%s", message);
}

static void wake(AbrServer *server) {
    char byte = 1;
    (void)!write(server->wake[1], &byte, 1);
}

static int prepare_folder(const char *path, char *error, size_t error_size) {
    char folder[1024];
    const char *slash = strrchr(path, '/');
    if (!slash || (size_t)(slash - path) >= sizeof folder) { set_error(error, error_size, "Invalid socket path"); return -1; }
    memcpy(folder, path, (size_t)(slash - path));
    folder[slash - path] = 0;
    struct stat info;
    if (lstat(folder, &info) != 0) {
        if (errno != ENOENT || mkdir(folder, 0700) != 0 || lstat(folder, &info) != 0) {
            set_error(error, error_size, "Could not create the Bridge folder");
            return -1;
        }
    }
    // A folder someone else owns, or a symbolic link, could redirect plugins to another listener.
    if (!S_ISDIR(info.st_mode) || info.st_uid != getuid()) {
        set_error(error, error_size, "The Bridge folder is not a private folder of this user");
        return -1;
    }
    if ((info.st_mode & 077) != 0 && chmod(folder, 0700) != 0) {
        set_error(error, error_size, "Could not make the Bridge folder private");
        return -1;
    }
    return 0;
}

static bool peer_is_same_user(int fd) {
    uid_t uid;
    gid_t gid;
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid();
}

static void close_client(AbrServer *server, uint32_t index) {
    Client *client = server->clients[index];
    pthread_mutex_lock(&server->lock);
    server->clients[index] = server->clients[--server->count];
    server->clients[server->count] = NULL;
    pthread_mutex_unlock(&server->lock);
    close(client->fd);
    free(client->buffer);
    free(client);
}

// Control messages are a few bytes; a plugin whose socket cannot take them is not reading and is dropped.
static bool send_message(Client *client, uint16_t type, const void *payload, uint32_t length) {
    uint8_t message[sizeof(AbrHeader) + 128];
    if (length > 128) return false;
    AbrHeader header = {ABR_MAGIC, type, 0, length, client->send_sequence++};
    memcpy(message, &header, sizeof header);
    if (length) memcpy(message + sizeof header, payload, length);
    ssize_t sent = send(client->fd, message, sizeof header + length, MSG_DONTWAIT);
    return sent == (ssize_t)(sizeof header + length);
}

// Hands one RESULT of the current subscription to the sink. The server reads only the subscription field; the
// sink decodes the rest (Sources/AnalysisCore/ResultProtocol.swift).
static void deliver_result(AbrServer *server, Client *client, const uint8_t *payload, uint32_t length) {
    uint32_t subscription = 0;
    bool found = false;
    AbrReader reader = abr_reader(payload, length);
    AbrField field;
    while (!found && abr_next_field(&reader, &field))
        if (field.tag == 1) found = abr_field_u32(&field, &subscription);  // ResultTag.subscription
    atomic_store_explicit(&client->last_result_ns, now_ns(), memory_order_relaxed);
    pthread_mutex_lock(&server->lock);
    client->info.results_received++;
    const bool selected = client->info.selected;
    const bool current = found && client->subscription != 0 && subscription == client->subscription;
    if (!found) client->info.results_malformed++;
    else if (!current) client->info.results_stale++;
    pthread_mutex_unlock(&server->lock);
    // Sent for an earlier subscription, or for a selection that has since changed: never replayed.
    if (!selected || !current) return;
    bool delivered = false;
    pthread_mutex_lock(&server->sink_lock);
    if (server->sink) {
        server->sink(server->sink_context, payload, length);
        delivered = true;
    }
    pthread_mutex_unlock(&server->sink_lock);
    if (delivered) {
        pthread_mutex_lock(&server->lock);
        client->info.results_delivered++;
        pthread_mutex_unlock(&server->lock);
    }
}

static void read_hello(AbrSourceInfo *info, const uint8_t *payload, uint32_t length) {
    AbrReader reader = abr_reader(payload + ABR_HELLO_MIN_BYTES, length - ABR_HELLO_MIN_BYTES);
    AbrField f;
    int64_t pid = 0;
    while (abr_next_field(&reader, &f)) {
        switch (f.tag) {
        case ABR_HELLO_SESSION_ID: abr_field_bytes(&f, info->session_id, 16); break;
        case ABR_HELLO_PERSISTENT_ID: abr_field_bytes(&f, info->persistent_id, 16); break;
        case ABR_HELLO_RESTORED_ID: abr_field_bytes(&f, info->restored_id, 16); break;
        case ABR_HELLO_IDENTITY_FLAGS: abr_field_u32(&f, &info->identity_flags); break;
        case ABR_HELLO_HOST_PID: if (abr_field_i64(&f, &pid)) info->host_pid = (int32_t)pid; break;
        case ABR_HELLO_HOST_NAME: abr_field_text(&f, info->host_name, sizeof info->host_name); break;
        case ABR_HELLO_HOST_BUNDLE_ID: abr_field_text(&f, info->host_bundle_id, sizeof info->host_bundle_id); break;
        case ABR_HELLO_PLUGIN_VERSION: abr_field_text(&f, info->plugin_version, sizeof info->plugin_version); break;
        case ABR_HELLO_SCHEMA: abr_field_u32(&f, &info->schema); break;
        case ABR_HELLO_CAPABILITIES: abr_field_u32(&f, &info->capabilities); break;
        default: break;  // a later addition: skipped
        }
    }
}

static void read_status(AbrSourceInfo *info, const uint8_t *payload, uint32_t length) {
    AbrReader reader = abr_reader(payload, length);
    AbrField f;
    // Every STATUS carries the whole layout: one without roles (a layout the plugin cannot measure, a plugin before
    // build 77) has none.
    info->role_count = 0;
    memset(info->roles, 0, sizeof info->roles);
    info->layout_name[0] = 0;
    while (abr_next_field(&reader, &f)) {
        switch (f.tag) {
        case ABR_STATUS_STATE: abr_field_u32(&f, &info->state); break;
        case ABR_STATUS_FORMAT_EPOCH: abr_field_u32(&f, &info->format_epoch); break;
        case ABR_STATUS_SAMPLE_RATE: abr_field_f64(&f, &info->sample_rate); break;
        case ABR_STATUS_CHANNELS: abr_field_u32(&f, &info->channels); break;
        case ABR_STATUS_LAYOUT: abr_field_u32(&f, &info->layout); break;
        case ABR_STATUS_MAX_BLOCK: abr_field_u32(&f, &info->max_block_frames); break;
        case ABR_STATUS_FLAGS: abr_field_u32(&f, &info->status_flags); break;
        case ABR_STATUS_FRAMES_PROCESSED: abr_field_u64(&f, &info->frames_processed); break;
        case ABR_STATUS_FRAMES_DROPPED: abr_field_u64(&f, &info->frames_dropped_by_plugin); break;
        case ABR_STATUS_INTERRUPTIONS: abr_field_u32(&f, &info->plugin_interruptions); break;
        case ABR_STATUS_TRANSPORT_JUMPS: abr_field_u32(&f, &info->transport_jumps); break;
        case ABR_STATUS_SOURCE_NAME: abr_field_text(&f, info->source_name, sizeof info->source_name); break;
        case ABR_STATUS_TRACK_NAME: abr_field_text(&f, info->track_name, sizeof info->track_name); break;
        case ABR_STATUS_CHANNEL_ID: abr_field_text(&f, info->channel_id, sizeof info->channel_id); break;
        case ABR_STATUS_GENERATION: abr_field_u32(&f, &info->generation); break;
        case ABR_STATUS_MEASUREMENT: abr_field_u32(&f, &info->measurement); break;
        case ABR_STATUS_FRAMES_ANALYSED: abr_field_u64(&f, &info->frames_analysed); break;
        case ABR_STATUS_LAST_BREAK: abr_field_u32(&f, &info->last_break_reasons); break;
        case ABR_STATUS_BACKLOG_MS: abr_field_u32(&f, &info->backlog_ms); break;
        case ABR_STATUS_SECONDS_SINCE_AUDIO: abr_field_f64(&f, &info->plugin_seconds_since_audio); break;
        case ABR_STATUS_ROLES:
            if (f.kind == ABR_KIND_U8 && f.count <= sizeof info->roles) {
                memset(info->roles, 0, sizeof info->roles);
                memcpy(info->roles, f.value, f.count);
                info->role_count = f.count;
            }
            break;
        case ABR_STATUS_LAYOUT_NAME: abr_field_text(&f, info->layout_name, sizeof info->layout_name); break;
        default: break;
        }
    }
}

static void read_ack(AbrSourceInfo *info, const uint8_t *payload, uint32_t length) {
    AbrReader reader = abr_reader(payload, length);
    AbrField f;
    uint32_t id = 0, code = 0, outcome = 0, generation = 0, measurement = 0;
    while (abr_next_field(&reader, &f)) {
        switch (f.tag) {
        case ABR_ACK_COMMAND_ID: abr_field_u32(&f, &id); break;
        case ABR_ACK_COMMAND_CODE: abr_field_u32(&f, &code); break;
        case ABR_ACK_OUTCOME: abr_field_u32(&f, &outcome); break;
        case ABR_ACK_GENERATION: abr_field_u32(&f, &generation); break;
        case ABR_ACK_MEASUREMENT: abr_field_u32(&f, &measurement); break;
        default: break;
        }
    }
    info->acks_received++;
    info->last_ack_id = id;
    info->last_ack_command = code;
    info->last_ack_outcome = outcome;
    info->last_ack_generation = generation;
    info->last_ack_measurement = measurement;
}

static bool send_welcome(Client *client) {
    uint8_t payload[64];
    abr_put32(payload, ABR_PROTOCOL_VERSION);
    abr_put32(payload + 4, 0);
    AbrWriter w = abr_writer(payload + 8, sizeof payload - 8);
    abr_put_u32(&w, ABR_WELCOME_SCHEMA, ABR_ANALYSIS_SCHEMA);
    return send_message(client, ABR_MSG_WELCOME, payload, (uint32_t)(8 + w.used));
}

// Returns false on a protocol violation.
static bool handle_message(AbrServer *server, Client *client, const AbrHeader *header, const uint8_t *payload) {
    atomic_store_explicit(&client->last_message_ns, now_ns(), memory_order_relaxed);
    if (client->incompatible) return true;  // listed as needing an update; nothing it says can be read
    switch (header->type) {
    case ABR_MSG_HELLO: {
        if (client->greeted || header->length < ABR_HELLO_MIN_BYTES) return false;
        const uint32_t version = abr_get32(payload), format = abr_get32(payload + 4);
        if (version != ABR_PROTOCOL_VERSION) {
            // Another version: listed, so Auraliscope can say which plugin needs an update, but never selected.
            // A newer plugin hears this receiver's version and says so itself; an older one reads the version at
            // the start of the WELCOME, says so, and retries slowly (version 1 does not wait for a reply, so none
            // is sent to it and it stays connected instead of reconnecting every second).
            pthread_mutex_lock(&server->lock);
            client->info.protocol_version = version;
            client->info.plugin_format = format;
            client->incompatible = true;
            pthread_mutex_unlock(&server->lock);
            if (version >= 2 && !send_welcome(client)) return false;
            return true;
        }
        AbrSourceInfo hello;
        memset(&hello, 0, sizeof hello);
        read_hello(&hello, payload, header->length);
        pthread_mutex_lock(&server->lock);
        const bool refused = now_ns() < server->refused_until && memcmp(server->refused, hello.session_id, 16) == 0;
        pthread_mutex_unlock(&server->lock);
        if (refused) return false;
        pthread_mutex_lock(&server->lock);
        AbrSourceInfo *info = &client->info;
        memcpy(info->session_id, hello.session_id, 16);
        memcpy(info->persistent_id, hello.persistent_id, 16);
        memcpy(info->restored_id, hello.restored_id, 16);
        info->identity_flags = hello.identity_flags;
        info->protocol_version = version;
        info->compatible = 1;
        info->plugin_format = format;
        info->host_pid = hello.host_pid;
        info->schema = hello.schema;
        info->capabilities = hello.capabilities;
        memcpy(info->host_name, hello.host_name, sizeof info->host_name);
        memcpy(info->host_bundle_id, hello.host_bundle_id, sizeof info->host_bundle_id);
        memcpy(info->plugin_version, hello.plugin_version, sizeof info->plugin_version);
        info->plugin_seconds_since_audio = -1;
        pthread_mutex_unlock(&server->lock);
        if (!send_welcome(client)) return false;
        pthread_mutex_lock(&server->lock);
        client->greeted = true;
        pthread_mutex_unlock(&server->lock);
        return true;
    }
    case ABR_MSG_STATUS:
        if (!client->greeted) return false;
        pthread_mutex_lock(&server->lock);
        read_status(&client->info, payload, header->length);
        pthread_mutex_unlock(&server->lock);
        return true;
    case ABR_MSG_RESULT:
        if (!client->greeted) return false;
        deliver_result(server, client, payload, header->length);
        return true;
    case ABR_MSG_ACK:
        if (!client->greeted) return false;
        pthread_mutex_lock(&server->lock);
        read_ack(&client->info, payload, header->length);
        pthread_mutex_unlock(&server->lock);
        return true;
    case ABR_MSG_FOCUS:
        if (!client->greeted) return false;
        pthread_mutex_lock(&server->lock);
        client->info.focus_requests++;
        pthread_mutex_unlock(&server->lock);
        return true;
    default:
        return true;  // unknown messages are ignored, so later minor additions stay compatible
    }
}

// Reads what is available; returns false when the connection should close.
static bool service_client(AbrServer *server, Client *client) {
    for (;;) {
        if (client->capacity - client->used < 65536) {
            size_t capacity = client->capacity ? client->capacity * 2 : 262144;
            if (capacity > sizeof(AbrHeader) + ABR_MAX_PAYLOAD + 65536) capacity = sizeof(AbrHeader) + ABR_MAX_PAYLOAD + 65536;
            if (capacity > client->capacity) {
                uint8_t *grown = realloc(client->buffer, capacity);
                if (!grown) return false;
                client->buffer = grown;
                client->capacity = capacity;
            }
        }
        ssize_t count = recv(client->fd, client->buffer + client->used, client->capacity - client->used, MSG_DONTWAIT);
        if (count == 0) return false;
        if (count < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
        client->used += (size_t)count;
        size_t offset = 0;
        while (client->used - offset >= sizeof(AbrHeader)) {
            AbrHeader header;
            memcpy(&header, client->buffer + offset, sizeof header);
            if (header.magic != ABR_MAGIC || header.length > ABR_MAX_PAYLOAD) return false;
            if (client->used - offset < sizeof header + header.length) break;
            if (!handle_message(server, client, &header, client->buffer + offset + sizeof header)) return false;
            offset += sizeof header + header.length;
        }
        if (offset) {
            memmove(client->buffer, client->buffer + offset, client->used - offset);
            client->used -= offset;
        }
    }
}

static void accept_clients(AbrServer *server) {
    for (;;) {
        int fd = accept(server->listen_fd, NULL, NULL);
        if (fd < 0) return;
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        int buffer = 32 * 1024;  // see the sender: small buffers keep stale results from queuing up
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof buffer);
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        if (!peer_is_same_user(fd) || server->count >= MAX_CLIENTS) { close(fd); continue; }
        Client *client = calloc(1, sizeof(Client));
        if (!client) { close(fd); continue; }
        client->fd = fd;
        atomic_store_explicit(&client->last_message_ns, now_ns(), memory_order_relaxed);
        pthread_mutex_lock(&server->lock);
        client->info.connection_serial = ++server->next_serial;
        server->clients[server->count++] = client;
        pthread_mutex_unlock(&server->lock);
    }
}

// Tells each greeted plugin whether it is the selected one, when that changed. Every subscription gets a new
// number; from here on only audio carrying it is delivered.
static void reconcile_subscriptions(AbrServer *server) {
    for (uint32_t i = 0; i < server->count;) {
        Client *client = server->clients[i];
        pthread_mutex_lock(&server->lock);
        const bool drop = client->drop;
        pthread_mutex_unlock(&server->lock);
        if (drop) {
            close_client(server, i);
            continue;
        }
        pthread_mutex_lock(&server->lock);
        bool wanted = client->greeted && server->has_selection && memcmp(server->selected, client->info.session_id, 16) == 0;
        client->info.selected = wanted;
        const uint64_t selection = server->selection;
        const uint32_t spectrogram = server->spectrogram, spectrum = server->spectrum, coherence = server->coherence;
        pthread_mutex_unlock(&server->lock);
        // Selected again (A → B → A): a fresh subscription, so nothing captured for the earlier one is delivered.
        const bool renew = wanted && client->subscribed && client->subscribed_selection != selection;
        // Other analysis options wanted: the same subscription again with the new options, so the columns carry on.
        const bool retune = wanted && client->subscribed && !renew
            && (client->subscribed_spectrogram != spectrogram || client->subscribed_spectrum != spectrum
                || client->subscribed_coherence != coherence);
        if (client->greeted && retune) {
            uint8_t payload[64];
            AbrWriter w = abr_writer(payload, sizeof payload);
            pthread_mutex_lock(&server->lock);
            const uint32_t current = client->subscription;
            pthread_mutex_unlock(&server->lock);
            abr_put_u32(&w, ABR_SUBSCRIBE_SUBSCRIPTION, current);
            abr_put_u32(&w, ABR_SUBSCRIBE_SPECTROGRAM, spectrogram);
            abr_put_u32(&w, ABR_SUBSCRIBE_SPECTRUM, spectrum);
            if (coherence != 0) abr_put_u32(&w, ABR_SUBSCRIBE_COHERENCE, coherence);
            if (current != 0 && !send_message(client, ABR_MSG_SUBSCRIBE, payload, (uint32_t)w.used)) {
                close_client(server, i);
                continue;
            }
            client->subscribed_spectrogram = spectrogram;
            client->subscribed_spectrum = spectrum;
            client->subscribed_coherence = coherence;
        }
        if (client->greeted && (wanted != client->subscribed || renew)) {
            bool sent;
            uint32_t subscription = 0;
            if (wanted) {
                if (++server->next_subscription == 0) server->next_subscription = 1;
                subscription = server->next_subscription;
                uint8_t payload[64];
                AbrWriter w = abr_writer(payload, sizeof payload);
                abr_put_u32(&w, ABR_SUBSCRIBE_SUBSCRIPTION, subscription);
                abr_put_u32(&w, ABR_SUBSCRIBE_SPECTROGRAM, spectrogram);
                abr_put_u32(&w, ABR_SUBSCRIBE_SPECTRUM, spectrum);
                if (coherence != 0) abr_put_u32(&w, ABR_SUBSCRIBE_COHERENCE, coherence);
                client->subscribed_spectrogram = spectrogram;
                client->subscribed_spectrum = spectrum;
                client->subscribed_coherence = coherence;
                sent = send_message(client, ABR_MSG_SUBSCRIBE, payload, (uint32_t)w.used);
            } else {
                sent = send_message(client, ABR_MSG_UNSUBSCRIBE, NULL, 0);
            }
            if (!sent) {
                close_client(server, i);
                continue;
            }
            // A selection made meanwhile has already invalidated this subscription: keep it invalid, and the
            // next pass subscribes afresh.
            pthread_mutex_lock(&server->lock);
            client->subscription = server->selection == selection ? subscription : 0;
            pthread_mutex_unlock(&server->lock);
            client->subscribed = wanted;
            client->subscribed_selection = selection;
        }
        // Commands waiting for this instance.
        PendingCommand commands[MAX_PENDING_COMMANDS];
        pthread_mutex_lock(&server->lock);
        const uint32_t pending = client->greeted ? client->pending_commands : 0;
        memcpy(commands, client->commands, pending * sizeof commands[0]);
        uint8_t session[16];
        memcpy(session, client->info.session_id, 16);
        if (client->greeted) client->pending_commands = 0;
        pthread_mutex_unlock(&server->lock);
        bool failed = false;
        for (uint32_t c = 0; c < pending && !failed; ++c) {
            uint8_t payload[96];
            AbrWriter w = abr_writer(payload, sizeof payload);
            abr_put_u32(&w, ABR_COMMAND_ID, commands[c].id);
            abr_put_u32(&w, ABR_COMMAND_CODE, commands[c].code);
            abr_put_bytes(&w, ABR_COMMAND_SESSION_ID, session, 16);
            abr_put_u32(&w, ABR_COMMAND_GENERATION, commands[c].generation);
            failed = !send_message(client, ABR_MSG_COMMAND, payload, (uint32_t)w.used);
        }
        if (failed) {
            close_client(server, i);
            continue;
        }
        ++i;
    }
}

static void *run(void *argument) {
    AbrServer *server = argument;
    pthread_setname_np("Auraliscope Bridge receiver");
    struct pollfd fds[MAX_CLIENTS + 2];
    while (!atomic_load(&server->stopping)) {
        reconcile_subscriptions(server);
        fds[0] = (struct pollfd){server->listen_fd, POLLIN, 0};
        fds[1] = (struct pollfd){server->wake[0], POLLIN, 0};
        uint32_t count = server->count;
        for (uint32_t i = 0; i < count; ++i) fds[i + 2] = (struct pollfd){server->clients[i]->fd, POLLIN, 0};
        if (poll(fds, count + 2, POLL_MS) < 0 && errno != EINTR) break;
        if (fds[1].revents) {
            char drain[64];
            while (read(server->wake[0], drain, sizeof drain) > 0) {}
        }
        // Service from the back so closing (which moves the last client into the hole) skips nobody.
        for (uint32_t i = count; i-- > 0;) {
            if (fds[i + 2].revents && !service_client(server, server->clients[i])) close_client(server, i);
        }
        if (fds[0].revents) accept_clients(server);
    }
    return NULL;
}

AbrServer *abr_server_start(const char *path, char *error, size_t error_size) {
    AbrServer *server = calloc(1, sizeof(AbrServer));
    if (!server) { set_error(error, error_size, "Out of memory"); return NULL; }
    if (path) {
        if (strlen(path) + 1 > sizeof server->path) { set_error(error, error_size, "Socket path too long"); free(server); return NULL; }
        strcpy(server->path, path);
    } else if (abr_socket_path(server->path, sizeof server->path) != 0) {
        set_error(error, error_size, "Socket path unavailable or too long");
        free(server);
        return NULL;
    }
    if (prepare_folder(server->path, error, error_size) != 0) { free(server); return NULL; }

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strcpy(address.sun_path, server->path);
    // A socket file left by a crashed receiver is replaced; a live receiver is not.
    int probe = socket(AF_UNIX, SOCK_STREAM, 0);
    if (probe >= 0) {
        bool live = connect(probe, (struct sockaddr *)&address, sizeof address) == 0;
        close(probe);
        if (live) { set_error(error, error_size, "Another receiver is already listening"); free(server); return NULL; }
    }
    unlink(server->path);
    server->listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    mode_t previous = umask(077);
    bool bound = server->listen_fd >= 0 && bind(server->listen_fd, (struct sockaddr *)&address, sizeof address) == 0;
    umask(previous);
    if (!bound || chmod(server->path, 0600) != 0 || listen(server->listen_fd, 16) != 0 || pipe(server->wake) != 0) {
        set_error(error, error_size, strerror(errno));
        if (server->listen_fd >= 0) close(server->listen_fd);
        if (bound) unlink(server->path);
        free(server);
        return NULL;
    }
    fcntl(server->listen_fd, F_SETFL, fcntl(server->listen_fd, F_GETFL) | O_NONBLOCK);
    fcntl(server->wake[0], F_SETFL, fcntl(server->wake[0], F_GETFL) | O_NONBLOCK);
    fcntl(server->wake[1], F_SETFL, fcntl(server->wake[1], F_GETFL) | O_NONBLOCK);
    pthread_mutex_init(&server->lock, NULL);
    pthread_mutex_init(&server->sink_lock, NULL);
    atomic_init(&server->stopping, false);
    if (pthread_create(&server->thread, NULL, run, server) != 0) {
        set_error(error, error_size, "Could not start the receiver thread");
        close(server->listen_fd);
        close(server->wake[0]);
        close(server->wake[1]);
        unlink(server->path);
        free(server);
        return NULL;
    }
    return server;
}

void abr_server_stop(AbrServer *server) {
    if (!server) return;
    atomic_store(&server->stopping, true);
    wake(server);
    pthread_join(server->thread, NULL);
    while (server->count) close_client(server, server->count - 1);
    close(server->listen_fd);
    close(server->wake[0]);
    close(server->wake[1]);
    unlink(server->path);
    pthread_mutex_destroy(&server->lock);
    pthread_mutex_destroy(&server->sink_lock);
    free(server);
}

uint32_t abr_server_sources(AbrServer *server, AbrSourceInfo *out, uint32_t capacity) {
    uint64_t now = now_ns();
    pthread_mutex_lock(&server->lock);
    uint32_t listed = 0;
    for (uint32_t i = 0; i < server->count; ++i) {
        Client *client = server->clients[i];
        if (!client->greeted && !client->incompatible) continue;
        if (out && listed < capacity) {
            AbrSourceInfo *info = &out[listed];
            *info = client->info;
            const uint64_t message = atomic_load_explicit(&client->last_message_ns, memory_order_relaxed);
            const uint64_t result = atomic_load_explicit(&client->last_result_ns, memory_order_relaxed);
            info->seconds_since_message = message && now > message ? (double)(now - message) / 1e9 : 0;
            info->seconds_since_result = result ? (now > result ? (double)(now - result) / 1e9 : 0) : -1;
            info->delivering = info->selected && server->sink != NULL;
        }
        ++listed;
    }
    pthread_mutex_unlock(&server->lock);
    // Connection order: the server swaps clients on close, so sort by serial.
    if (out) {
        uint32_t n = listed < capacity ? listed : capacity;
        for (uint32_t i = 1; i < n; ++i) {
            AbrSourceInfo key = out[i];
            uint32_t j = i;
            for (; j > 0 && out[j - 1].connection_serial > key.connection_serial; --j) out[j] = out[j - 1];
            out[j] = key;
        }
    }
    return listed;
}

void abr_server_disconnect(AbrServer *server, const uint8_t *session_id, uint32_t refuse_ms) {
    pthread_mutex_lock(&server->lock);
    memcpy(server->refused, session_id, 16);
    server->refused_until = now_ns() + (uint64_t)refuse_ms * 1000000ull;
    for (uint32_t i = 0; i < server->count; ++i)
        if (memcmp(server->clients[i]->info.session_id, session_id, 16) == 0) server->clients[i]->drop = true;
    pthread_mutex_unlock(&server->lock);
    wake(server);
}

void abr_server_select(AbrServer *server, const uint8_t *session_id) {
    pthread_mutex_lock(&server->lock);
    server->has_selection = session_id != NULL;
    if (session_id) memcpy(server->selected, session_id, 16);
    server->selection++;
    for (uint32_t i = 0; i < server->count; ++i) {
        Client *client = server->clients[i];
        client->info.selected = client->greeted && session_id && memcmp(session_id, client->info.session_id, 16) == 0;
        // Whatever is in flight now was sent for the previous selection: stale from this moment, until the server
        // thread sends the new subscription.
        client->subscription = 0;
    }
    pthread_mutex_unlock(&server->lock);
    wake(server);
}

void abr_server_set_spectrogram(AbrServer *server, uint32_t mode) {
    pthread_mutex_lock(&server->lock);
    const bool changed = server->spectrogram != mode;
    server->spectrogram = mode;
    pthread_mutex_unlock(&server->lock);
    if (changed) wake(server);
}

void abr_server_set_spectrum(AbrServer *server, uint32_t channels) {
    pthread_mutex_lock(&server->lock);
    const bool changed = server->spectrum != channels;
    server->spectrum = channels;
    pthread_mutex_unlock(&server->lock);
    if (changed) wake(server);
}

void abr_server_set_coherence(AbrServer *server, uint32_t thousandths) {
    pthread_mutex_lock(&server->lock);
    const bool changed = server->coherence != thousandths;
    server->coherence = thousandths;
    pthread_mutex_unlock(&server->lock);
    if (changed) wake(server);
}

void abr_server_attach(AbrServer *server, AbrResultSink sink, void *context) {
    pthread_mutex_lock(&server->sink_lock);
    server->sink = sink;
    server->sink_context = context;
    pthread_mutex_unlock(&server->sink_lock);
}

void abr_server_detach(AbrServer *server) {
    pthread_mutex_lock(&server->sink_lock);
    server->sink = NULL;
    server->sink_context = NULL;
    pthread_mutex_unlock(&server->sink_lock);
}

uint32_t abr_server_command(AbrServer *server, const uint8_t *session_id, uint32_t command, uint32_t generation) {
    uint32_t id = 0;
    pthread_mutex_lock(&server->lock);
    for (uint32_t i = 0; i < server->count; ++i) {
        Client *client = server->clients[i];
        if (!client->greeted || memcmp(client->info.session_id, session_id, 16) != 0) continue;
        if (client->pending_commands == MAX_PENDING_COMMANDS) break;
        if (++server->next_command == 0) server->next_command = 1;
        id = server->next_command;
        client->commands[client->pending_commands++] = (PendingCommand){id, command, generation};
        break;
    }
    pthread_mutex_unlock(&server->lock);
    if (id) wake(server);
    return id;
}
