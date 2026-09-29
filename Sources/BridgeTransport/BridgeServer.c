#include "BridgeServer.h"
#include "BridgePaths.h"

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

typedef struct {
    int fd;
    uint8_t *buffer;
    size_t used, capacity;
    bool greeted;                 // a HELLO of this protocol version arrived (written under AbrServer.lock)
    bool incompatible;            // a HELLO of another version: listed, otherwise ignored (ditto)
    bool subscribed;              // what the server last told the plugin
    uint64_t subscribed_selection; // the selection generation that SUBSCRIBE belongs to
    uint32_t subscription;        // the number sent with that SUBSCRIBE (0: none); other audio is stale
    uint32_t send_sequence;
    _Atomic uint64_t last_message_ns, last_audio_ns;  // read by abr_server_sources on another thread
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
    uint32_t next_subscription;   // server thread only
    pthread_mutex_t sink_lock;    // held while the sink runs; guards the delivery state below
    AbrSink sink;
    AbrBoundary boundary;
    void *sink_context;
    uint32_t sink_epoch;
    bool mark_start;
    uint64_t attach_generation;
    uint64_t delivery_generation; // attach generation of the newest delivered block
    bool have_expectation;        // the selected instance delivered since it was selected
    uint64_t expected_position;   // end of its newest delivered block
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
    uint8_t message[sizeof(AbrHeader) + 64];
    if (length > 64) return false;
    AbrHeader header = {ABR_MAGIC, type, 0, length, client->send_sequence++};
    memcpy(message, &header, sizeof header);
    if (length) memcpy(message + sizeof header, payload, length);
    ssize_t sent = send(client->fd, message, sizeof header + length, MSG_DONTWAIT);
    return sent == (ssize_t)(sizeof header + length);
}

static void copy_string(char *destination, const char *source, size_t size) {
    memcpy(destination, source, size);
    destination[size - 1] = 0;
}

// Hands one block to the sink, telling the boundary callback first when it does not continue the audio before
// it: the plugin said so (ABR_AUDIO_DISCONTINUITY and its reasons), or its stream position skipped frames.
static void deliver_audio(AbrServer *server, Client *client, const AbrAudio *audio, const float *samples) {
    pthread_mutex_lock(&server->lock);
    bool selected = client->info.selected;
    uint32_t channels = client->info.channels;
    uint32_t epoch = client->info.format_epoch;
    client->info.frames_received += audio->frames;
    bool current = client->subscription != 0 && audio->subscription == client->subscription;
    if (!current) client->info.frames_stale += audio->frames;
    pthread_mutex_unlock(&server->lock);
    atomic_store_explicit(&client->last_audio_ns, now_ns(), memory_order_relaxed);
    // Queued before an unsubscribe, or for a selection that has since changed: never replayed.
    if (!selected || !current) return;

    uint64_t delivered = 0, discarded = 0, lost = 0, gaps = 0;
    uint32_t reasons = 0;
    pthread_mutex_lock(&server->sink_lock);
    if (server->sink && server->sink_epoch == audio->format_epoch && epoch == audio->format_epoch
        && channels == audio->channels) {
        const bool first = server->delivery_generation != server->attach_generation;
        server->delivery_generation = server->attach_generation;
        if (audio->flags & ABR_AUDIO_DISCONTINUITY) reasons = audio->flags & ABR_AUDIO_REASONS;
        if (server->have_expectation && audio->position > server->expected_position) {
            lost = audio->position - server->expected_position;
            reasons |= ABR_AUDIO_AFTER_DROP;
        }
        // The first block after an attach without `mark_start` opens a fresh or deliberately continued analysis.
        if (first && !server->mark_start) reasons = 0, lost = 0;
        if (reasons) {
            gaps = 1;
            if (server->boundary)
                server->boundary(server->sink_context, reasons, lost,
                                 (audio->flags & ABR_AUDIO_AFTER_IDLE) ? audio->idle_ms : 0);
        }
        server->have_expectation = true;
        server->expected_position = audio->position + audio->frames;
        server->sink(server->sink_context, samples, audio->frames, audio->channels);
        delivered = audio->frames;
    } else if (server->sink) {
        discarded = audio->frames;  // attached, but for another format: the owner has yet to reconfigure
    }
    pthread_mutex_unlock(&server->sink_lock);

    pthread_mutex_lock(&server->lock);
    client->info.frames_delivered += delivered;
    client->info.frames_discarded += discarded;
    client->info.frames_lost += lost;
    client->info.discontinuities += gaps;
    if (gaps) client->info.last_reasons = reasons;
    pthread_mutex_unlock(&server->lock);
}

// Returns false on a protocol violation.
static bool handle_message(AbrServer *server, Client *client, const AbrHeader *header, const uint8_t *payload) {
    atomic_store_explicit(&client->last_message_ns, now_ns(), memory_order_relaxed);
    if (client->incompatible) return true;  // listed as needing an update; nothing it says can be read
    switch (header->type) {
    case ABR_MSG_HELLO: {
        if (client->greeted || header->length < ABR_HELLO_MIN_BYTES) return false;
        uint32_t words[2];
        memcpy(words, payload, sizeof words);
        if (words[0] != ABR_PROTOCOL_VERSION) {
            // Another version: listed, so Auraliscope can say which plugin needs an update, but never selected.
            // A newer plugin hears this receiver's version and says so itself; an older one (version 1) does not
            // wait for a reply, so none is sent and it stays connected instead of reconnecting every second.
            pthread_mutex_lock(&server->lock);
            client->info.protocol_version = words[0];
            client->info.plugin_format = words[1];
            client->incompatible = true;
            pthread_mutex_unlock(&server->lock);
            if (words[0] > ABR_PROTOCOL_VERSION) {
                AbrWelcome welcome = {ABR_PROTOCOL_VERSION, 0};
                if (!send_message(client, ABR_MSG_WELCOME, &welcome, sizeof welcome)) return false;
            }
            return true;
        }
        if (header->length < sizeof(AbrHello)) return false;
        AbrHello hello;
        memcpy(&hello, payload, sizeof hello);
        pthread_mutex_lock(&server->lock);
        AbrSourceInfo *info = &client->info;
        memcpy(info->session_id, hello.session_id, 16);
        memcpy(info->persistent_id, hello.persistent_id, 16);
        memcpy(info->restored_id, hello.restored_id, 16);
        info->identity_flags = hello.identity_flags;
        info->protocol_version = hello.protocol_version;
        info->compatible = 1;
        info->plugin_format = hello.plugin_format;
        info->host_pid = hello.host_pid;
        copy_string(info->host_name, hello.host_name, sizeof info->host_name);
        copy_string(info->host_bundle_id, hello.host_bundle_id, sizeof info->host_bundle_id);
        copy_string(info->plugin_version, hello.plugin_version, sizeof info->plugin_version);
        pthread_mutex_unlock(&server->lock);
        AbrWelcome welcome = {ABR_PROTOCOL_VERSION, 0};
        if (!send_message(client, ABR_MSG_WELCOME, &welcome, sizeof welcome)) return false;
        pthread_mutex_lock(&server->lock);
        client->greeted = true;
        pthread_mutex_unlock(&server->lock);
        return true;
    }
    case ABR_MSG_STATUS: {
        if (!client->greeted || header->length < sizeof(AbrStatus)) return false;
        AbrStatus status;
        memcpy(&status, payload, sizeof status);
        pthread_mutex_lock(&server->lock);
        AbrSourceInfo *info = &client->info;
        info->state = status.state;
        info->status_flags = status.flags;
        // FORMAT is authoritative for audio; STATUS carries the same numbers so an unsubscribed instance is
        // described too.
        if (status.format_epoch >= info->format_epoch) {
            info->format_epoch = status.format_epoch;
            info->sample_rate = status.sample_rate;
            info->channels = status.channels;
            info->layout = status.layout;
        }
        info->max_block_frames = status.max_block_frames;
        info->frames_processed = status.frames_processed;
        info->frames_dropped_by_plugin = status.frames_dropped;
        info->plugin_interruptions = status.interruptions;
        info->transport_jumps = status.transport_jumps;
        copy_string(info->source_name, status.source_name, sizeof info->source_name);
        copy_string(info->track_name, status.track_name, sizeof info->track_name);
        copy_string(info->channel_id, status.channel_id, sizeof info->channel_id);
        pthread_mutex_unlock(&server->lock);
        return true;
    }
    case ABR_MSG_FORMAT: {
        if (!client->greeted || header->length < sizeof(AbrFormat)) return false;
        AbrFormat format;
        memcpy(&format, payload, sizeof format);
        if (format.channels == 0 || format.channels > ABR_MAX_CHANNELS
            || format.sample_format != ABR_SAMPLE_FLOAT32_INTERLEAVED
            || !(format.sample_rate >= 8000 && format.sample_rate <= 768000)) return false;
        pthread_mutex_lock(&server->lock);
        client->info.format_epoch = format.format_epoch;
        client->info.sample_rate = format.sample_rate;
        client->info.channels = format.channels;
        client->info.layout = format.layout;
        pthread_mutex_unlock(&server->lock);
        return true;
    }
    case ABR_MSG_AUDIO: {
        if (!client->greeted || header->length < sizeof(AbrAudio)) return false;
        AbrAudio audio;
        memcpy(&audio, payload, sizeof audio);
        if (audio.channels == 0 || audio.channels > ABR_MAX_CHANNELS
            || header->length != sizeof audio + (uint64_t)audio.frames * audio.channels * sizeof(float)) return false;
        // The payload sits at a 4-byte boundary after the 16-byte header, so the samples are float-aligned.
        deliver_audio(server, client, &audio, (const float *)(payload + sizeof audio));
        return true;
    }
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
        int buffer = 128 * 1024;  // see the sender: small buffers keep latency bounded under overload
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
        bool wanted = client->greeted && server->has_selection && memcmp(server->selected, client->info.session_id, 16) == 0;
        client->info.selected = wanted;
        const uint64_t selection = server->selection;
        pthread_mutex_unlock(&server->lock);
        // Selected again (A → B → A): a fresh subscription, so nothing captured for the earlier one is delivered.
        const bool renew = wanted && client->subscribed && client->subscribed_selection != selection;
        if (client->greeted && (wanted != client->subscribed || renew)) {
            bool sent;
            uint32_t subscription = 0;
            if (wanted) {
                if (++server->next_subscription == 0) server->next_subscription = 1;
                subscription = server->next_subscription;
                AbrSubscribe subscribe = {subscription, 0};
                sent = send_message(client, ABR_MSG_SUBSCRIBE, &subscribe, sizeof subscribe);
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
            const uint64_t audio = atomic_load_explicit(&client->last_audio_ns, memory_order_relaxed);
            info->seconds_since_message = message && now > message ? (double)(now - message) / 1e9 : 0;
            info->seconds_since_audio = audio ? (now > audio ? (double)(now - audio) / 1e9 : 0) : -1;
            info->delivering = info->selected && server->sink != NULL && server->sink_epoch == info->format_epoch;
            info->delivered_epoch = info->selected && server->sink ? server->sink_epoch : 0;
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

void abr_server_select(AbrServer *server, const uint8_t *session_id) {
    abr_server_detach(server);
    pthread_mutex_lock(&server->sink_lock);
    server->have_expectation = false;  // a new selection: its positions have nothing to continue
    pthread_mutex_unlock(&server->sink_lock);
    pthread_mutex_lock(&server->lock);
    server->has_selection = session_id != NULL;
    if (session_id) memcpy(server->selected, session_id, 16);
    server->selection++;
    for (uint32_t i = 0; i < server->count; ++i) {
        Client *client = server->clients[i];
        client->info.selected = client->greeted && session_id && memcmp(session_id, client->info.session_id, 16) == 0;
        // Whatever is in flight now was captured for the previous selection: stale from this moment, until the
        // server thread sends the new subscription.
        client->subscription = 0;
    }
    pthread_mutex_unlock(&server->lock);
    wake(server);
}

void abr_server_attach(AbrServer *server, uint32_t format_epoch, AbrSink sink, AbrBoundary boundary, void *context,
                       int mark_start) {
    pthread_mutex_lock(&server->sink_lock);
    pthread_mutex_lock(&server->lock);
    server->sink = sink;
    server->boundary = boundary;
    server->sink_context = context;
    server->sink_epoch = format_epoch;
    server->mark_start = mark_start != 0;
    server->attach_generation++;
    pthread_mutex_unlock(&server->lock);
    pthread_mutex_unlock(&server->sink_lock);
}

void abr_server_detach(AbrServer *server) {
    pthread_mutex_lock(&server->sink_lock);
    pthread_mutex_lock(&server->lock);
    server->sink = NULL;
    server->boundary = NULL;
    server->sink_context = NULL;
    pthread_mutex_unlock(&server->lock);
    pthread_mutex_unlock(&server->sink_lock);
}
