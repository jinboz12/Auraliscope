// A standalone receiver for checking the plugins without Auraliscope: lists the instances it hears from, and with
// --verify, subscribes to one and compares every delivered frame with the harness signal (see HostHarness.mm).
//
//   ReceiverProbe [--seconds s] [--verify <name> --instance i]
//
// Uses the default socket, so it cannot run while Auraliscope Labs is open (and says so), unless
// AURALISCOPE_BRIDGE_SOCKET points both it and the plugins' host somewhere private.

#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "BridgeServer.h"

typedef struct {
    pthread_mutex_t lock;
    float *samples;
    size_t count, capacity;
    uint32_t channels;
    uint32_t breaks, reasons;
} Capture;

static void boundary(void *context, uint32_t reasons, uint64_t lost, uint32_t idle_ms) {
    Capture *capture = context;
    pthread_mutex_lock(&capture->lock);
    capture->breaks++;
    capture->reasons |= reasons;
    pthread_mutex_unlock(&capture->lock);
    printf("[probe] break before frame %zu: reasons 0x%x, %llu lost, idle %u ms\n",
           capture->channels ? capture->count / capture->channels : 0, reasons, (unsigned long long)lost, idle_ms);
}

static void sink(void *context, const float *interleaved, uint32_t frames, uint32_t channels) {
    Capture *capture = context;
    pthread_mutex_lock(&capture->lock);
    size_t needed = capture->count + (size_t)frames * channels;
    if (needed > capture->capacity) {
        capture->capacity = needed * 2;
        capture->samples = realloc(capture->samples, capture->capacity * sizeof(float));
    }
    memcpy(capture->samples + capture->count, interleaved, (size_t)frames * channels * sizeof(float));
    capture->count = needed;
    capture->channels = channels;
    pthread_mutex_unlock(&capture->lock);
}

static float signal_at(uint32_t instance, uint32_t channel, uint64_t n, double rate) {
    double scale = ldexp(1.0, -(int)instance);
    double frequency = channel == 0 ? 997.0 : 1499.0, amplitude = (channel == 0 ? 0.5 : 0.25) * scale;
    return (float)(amplitude * sin(2 * M_PI * frequency * (double)n / rate));
}

static const char *state_name(uint32_t state) {
    switch (state) {
    case ABR_STATE_LIVE: return "live";
    case ABR_STATE_BYPASSED: return "bypassed";
    case ABR_STATE_OFFLINE: return "offline";
    default: return "inactive";
    }
}

int main(int argc, char **argv) {
    double seconds = 3;
    const char *verify = NULL;
    uint32_t instance = 0;
    int trace = 0;
    for (int i = 1; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--seconds")) seconds = atof(argv[i + 1]);
        else if (!strcmp(argv[i], "--verify")) verify = argv[i + 1];
        else if (!strcmp(argv[i], "--instance")) instance = (uint32_t)atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--trace")) trace = atoi(argv[i + 1]);
    }
    char error[256] = "";
    AbrServer *server = abr_server_start(NULL, error, sizeof error);
    if (!server) { fprintf(stderr, "probe: %s\n", error); return 2; }
    AbrSourceInfo sources[64];
    Capture capture = {PTHREAD_MUTEX_INITIALIZER, NULL, 0, 0, 0};
    int selected = -1;
    for (double t = 0; t < seconds; t += 0.1) {
        usleep(100000);
        uint32_t count = abr_server_sources(server, sources, 64);
        // --trace 1: one line whenever an instance appears, changes state or leaves (subscribing to the first one,
        // so its audio flow is visible too).
        static char last[512] = "";
        if (trace) {
            char now[512] = "";
            for (uint32_t i = 0; i < count && i < 8; ++i) {
                char part[96];
                snprintf(part, sizeof part, "\"%s\" %s%s; ", sources[i].source_name, state_name(sources[i].state),
                         sources[i].seconds_since_audio >= 0 && sources[i].seconds_since_audio < 0.3 ? " +audio" : "");
                strncat(now, part, sizeof now - strlen(now) - 1);
            }
            if (count && !sources[0].selected) abr_server_select(server, sources[0].session_id);
            if (strcmp(now, last)) { printf("[probe] %5.1f s  %s\n", t, count ? now : "(none)"); fflush(stdout); strcpy(last, now); }
        }
        if (verify && selected < 0) {
            for (uint32_t i = 0; i < count && i < 64; ++i) {
                if (strcmp(sources[i].source_name, verify) == 0 && sources[i].format_epoch > 0) {
                    selected = (int)i;
                    abr_server_select(server, sources[i].session_id);
                    abr_server_attach(server, sources[i].format_epoch, sink, boundary, &capture, 0);
                }
            }
        }
    }
    uint32_t count = abr_server_sources(server, sources, 64);
    printf("[probe] %u instance(s)\n", count);
    for (uint32_t i = 0; i < count && i < 64; ++i) {
        AbrSourceInfo *s = &sources[i];
        if (!s->compatible) {
            printf("[probe]   (protocol %u plugin in pid %d: needs an update)\n", s->protocol_version, s->host_pid);
            continue;
        }
        printf("[probe]   \"%s\" track \"%s\" · %s %s in %s [%s] (pid %d) · %s · %.0f Hz · %u ch · epoch %u · ID %02X%02X%02X%s%s"
               " · received %llu, lost %llu, breaks %llu\n",
               s->source_name, s->track_name, s->plugin_format == ABR_FORMAT_VST3 ? "VST3" : s->plugin_format == ABR_FORMAT_AU ? "AU" : "test",
               s->plugin_version, s->host_name, s->host_bundle_id, s->host_pid, state_name(s->state), s->sample_rate, s->channels,
               s->format_epoch, s->persistent_id[0], s->persistent_id[1], s->persistent_id[2],
               (s->identity_flags & ABR_IDENTITY_COPY) ? " (copy)" : "", s->channel_id[0] ? " · channel ID set" : "",
               (unsigned long long)s->frames_received, (unsigned long long)s->frames_lost, (unsigned long long)s->discontinuities);
    }
    int result = 0;
    if (verify) {
        abr_server_detach(server);
        if (selected < 0) { printf("[probe] FAIL: \"%s\" not found\n", verify); result = 1; }
        else {
            // Find the stream position of the first delivered frame, then compare everything after it.
            double rate = sources[selected].sample_rate;
            uint32_t channels = capture.channels;
            size_t frames = channels ? capture.count / channels : 0;
            long long first = -1;
            for (uint64_t start = 0; start < 10 * (uint64_t)rate && first < 0 && frames >= 8; ++start) {
                int match = 1;
                for (size_t f = 0; f < 8 && match; ++f)
                    for (uint32_t c = 0; c < channels && match; ++c)
                        match = capture.samples[f * channels + c] == signal_at(instance, c, start + f, rate);
                if (match) first = (long long)start;
            }
            size_t wrong = 0;
            float peak[2] = {0, 0};
            for (size_t f = 0; first >= 0 && f < frames; ++f)
                for (uint32_t c = 0; c < channels; ++c) {
                    float v = capture.samples[f * channels + c];
                    if (v != signal_at(instance, c, (uint64_t)first + f, rate)) ++wrong;
                    if (fabsf(v) > peak[c]) peak[c] = fabsf(v);
                }
            printf("[probe] verify \"%s\": %zu frames, %u ch at %.0f Hz from position %lld, %zu mismatched samples, "
                   "peak L %.4f R %.4f, lost %llu\n", verify, frames, channels, rate, first, wrong, peak[0], peak[1],
                   (unsigned long long)sources[selected].frames_lost);
            result = first < 0 || wrong > 0 || frames == 0 || sources[selected].frames_lost > 0;
            printf("[probe] %s\n", result ? "FAIL" : "PASS: bit-exact, channel order and level as sent");
        }
    }
    abr_server_stop(server);
    free(capture.samples);
    return result;
}
