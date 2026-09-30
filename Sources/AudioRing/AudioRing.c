#include "AudioRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit atomics must be lock-free");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "32-bit atomics must be lock-free");
_Static_assert(sizeof(ChannelFrame) == CHANNEL_ROLE_COUNT * sizeof(float), "role frames must be packed");

struct AudioRing {
    uint32_t capacity;
    StereoFrame *data;
    _Atomic uint64_t write_index;
    _Atomic uint64_t read_index;
    _Atomic uint64_t dropped;
};

AudioRing *audio_ring_create(uint32_t capacity) {
    if (capacity < 2) return NULL;
    AudioRing *ring = calloc(1, sizeof(AudioRing));
    if (!ring) return NULL;
    ring->data = calloc(capacity, sizeof(StereoFrame));
    if (!ring->data) { free(ring); return NULL; }
    ring->capacity = capacity;
    atomic_init(&ring->write_index, 0);
    atomic_init(&ring->read_index, 0);
    atomic_init(&ring->dropped, 0);
    return ring;
}

void audio_ring_destroy(AudioRing *ring) {
    if (!ring) return;
    free(ring->data);
    free(ring);
}

void audio_ring_clear(AudioRing *ring) {
    if (!ring) return;
    uint64_t write = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    atomic_store_explicit(&ring->read_index, write, memory_order_release);
    atomic_store_explicit(&ring->dropped, 0, memory_order_relaxed);
}

uint32_t audio_ring_write(AudioRing *ring, const float *input, uint32_t frames, uint32_t channels) {
    if (!ring || !input || (channels != 1 && channels != 2)) return 0;
    uint64_t write = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    uint32_t available = ring->capacity - (uint32_t)(write - read);
    uint32_t count = frames < available ? frames : available;
    for (uint32_t i = 0; i < count; ++i) {
        float left = input[i * channels];
        float right = channels == 2 ? input[i * channels + 1] : left;
        ring->data[(write + i) % ring->capacity] = (StereoFrame){left, right};
    }
    atomic_store_explicit(&ring->write_index, write + count, memory_order_release);
    if (count < frames) atomic_fetch_add_explicit(&ring->dropped, frames - count, memory_order_relaxed);
    return count;
}

uint32_t audio_ring_read(AudioRing *ring, StereoFrame *destination, uint32_t max_frames) {
    if (!ring || !destination) return 0;
    uint64_t read = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    uint32_t available = (uint32_t)(write - read);
    uint32_t count = max_frames < available ? max_frames : available;
    for (uint32_t i = 0; i < count; ++i) destination[i] = ring->data[(read + i) % ring->capacity];
    atomic_store_explicit(&ring->read_index, read + count, memory_order_release);
    return count;
}

uint64_t audio_ring_dropped(const AudioRing *ring) {
    return ring ? atomic_load_explicit(&ring->dropped, memory_order_relaxed) : 0;
}

// Producer, consumer and shared slot own distinct buffers. Only the shared
// slot transfers ownership, so plain floats are never read while being written.
struct MeterExchange {
    float buffers[3][METER_SNAPSHOT_FLOATS];
    unsigned producer;
    unsigned consumer;
    _Atomic unsigned shared;
    _Atomic int mode;
    _Atomic unsigned true_peak_resets;
};

MeterExchange *meter_exchange_create(void) {
    MeterExchange *exchange = calloc(1, sizeof(MeterExchange));
    if (!exchange) return NULL;
    exchange->producer = 2;
    exchange->consumer = 0;
    atomic_init(&exchange->shared, 1);
    return exchange;
}

void meter_exchange_destroy(MeterExchange *exchange) { free(exchange); }

void meter_exchange_set_mode(MeterExchange *exchange, int mode) {
    atomic_store_explicit(&exchange->mode, mode, memory_order_relaxed);
}

int meter_exchange_mode(MeterExchange *exchange) {
    return atomic_load_explicit(&exchange->mode, memory_order_relaxed);
}

void meter_exchange_reset_true_peaks(MeterExchange *exchange) {
    atomic_fetch_add_explicit(&exchange->true_peak_resets, 1u, memory_order_relaxed);
}

unsigned meter_exchange_true_peak_resets(MeterExchange *exchange) {
    return atomic_load_explicit(&exchange->true_peak_resets, memory_order_relaxed);
}

void meter_exchange_publish(MeterExchange *exchange, const float *values) {
    memcpy(exchange->buffers[exchange->producer], values, METER_SNAPSHOT_FLOATS * sizeof(float));
    unsigned previous = atomic_exchange_explicit(&exchange->shared, exchange->producer | 4u, memory_order_acq_rel);
    exchange->producer = previous & 3u;
}

int meter_exchange_read(MeterExchange *exchange, float *values) {
    if (!(atomic_load_explicit(&exchange->shared, memory_order_acquire) & 4u)) return 0;
    unsigned previous = atomic_exchange_explicit(&exchange->shared, exchange->consumer, memory_order_acq_rel);
    exchange->consumer = previous & 3u;
    memcpy(values, exchange->buffers[exchange->consumer], METER_SNAPSHOT_FLOATS * sizeof(float));
    return 1;
}

#define CHANNEL_RING_MARKS 32
typedef struct {
    uint64_t position;      // write index of the first frame after the break
    ChannelRingMark mark;
} PositionedMark;

struct ChannelRing {
    uint32_t capacity;
    ChannelFrame *data;
    _Atomic uint64_t write_index;
    _Atomic uint64_t read_index;
    _Atomic uint64_t dropped;
    // Breaks, in write order: the producer appends at mark_write, the consumer takes at mark_read.
    PositionedMark marks[CHANNEL_RING_MARKS];
    _Atomic uint64_t mark_write;
    _Atomic uint64_t mark_read;
    _Atomic uint32_t mark_overflow;   // reasons of marks that found the queue full, reported at the read position
    uint64_t overflow_frames;         // producer: frames the ring dropped since its last write, marked at the next
};

ChannelRing *channel_ring_create(uint32_t capacity) {
    if (capacity < 2) return NULL;
    ChannelRing *ring = calloc(1, sizeof(ChannelRing));
    if (!ring) return NULL;
    ring->data = calloc(capacity, sizeof(ChannelFrame));
    if (!ring->data) { free(ring); return NULL; }
    ring->capacity = capacity;
    atomic_init(&ring->write_index, 0);
    atomic_init(&ring->read_index, 0);
    atomic_init(&ring->dropped, 0);
    atomic_init(&ring->mark_write, 0);
    atomic_init(&ring->mark_read, 0);
    atomic_init(&ring->mark_overflow, 0);
    return ring;
}

void channel_ring_destroy(ChannelRing *ring) {
    if (!ring) return;
    free(ring->data);
    free(ring);
}

// With no producer running: nothing is left to read, and no break is pending.
void channel_ring_clear(ChannelRing *ring) {
    if (!ring) return;
    uint64_t write = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    atomic_store_explicit(&ring->read_index, write, memory_order_release);
    atomic_store_explicit(&ring->dropped, 0, memory_order_relaxed);
    uint64_t marks = atomic_load_explicit(&ring->mark_write, memory_order_acquire);
    atomic_store_explicit(&ring->mark_read, marks, memory_order_release);
    atomic_store_explicit(&ring->mark_overflow, 0, memory_order_relaxed);
    ring->overflow_frames = 0;
}

void channel_ring_mark(ChannelRing *ring, uint32_t reasons, uint64_t lost_frames, uint32_t idle_ms) {
    if (!ring || reasons == 0) return;
    uint64_t marks = atomic_load_explicit(&ring->mark_write, memory_order_relaxed);
    uint64_t taken = atomic_load_explicit(&ring->mark_read, memory_order_acquire);
    if (marks - taken >= CHANNEL_RING_MARKS) {
        // The consumer has not read for a long time; it learns of a break at wherever it reads next.
        atomic_fetch_or_explicit(&ring->mark_overflow, reasons, memory_order_relaxed);
        return;
    }
    PositionedMark *slot = &ring->marks[marks % CHANNEL_RING_MARKS];
    slot->position = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    slot->mark = (ChannelRingMark){reasons, idle_ms, lost_frames};
    // Published before the frames after it (their write_index store is also a release), so a consumer that sees
    // those frames sees the mark.
    atomic_store_explicit(&ring->mark_write, marks + 1, memory_order_release);
}

// Runs on the Core Audio IO thread: no allocation, no locks, one modulo per call. Only routed roles are
// copied; the rest of each frame is zeroed so unrouted roles always read as silence.
uint32_t channel_ring_write(ChannelRing *ring, const float *input, uint32_t frames,
                            uint32_t channels, const int32_t *map) {
    if (!ring || !input || !map || channels == 0) return 0;
    uint64_t write = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    uint32_t available = ring->capacity - (uint32_t)(write - read);
    uint32_t count = frames < available ? frames : available;
    if (count > 0 && ring->overflow_frames > 0) {
        // Frames were dropped after the last ones written: these do not continue them.
        channel_ring_mark(ring, CHANNEL_RING_OVERFLOW, ring->overflow_frames, 0);
        ring->overflow_frames = 0;
    }
    uint32_t roles[CHANNEL_ROLE_COUNT], sources[CHANNEL_ROLE_COUNT], routed = 0;
    for (uint32_t role = 0; role < CHANNEL_ROLE_COUNT; ++role) {
        int32_t channel = map[role];
        if (channel >= 0 && (uint32_t)channel < channels) {
            roles[routed] = role;
            sources[routed] = (uint32_t)channel;
            ++routed;
        }
    }
    uint32_t slot = (uint32_t)(write % ring->capacity);
    for (uint32_t frame = 0; frame < count; ++frame) {
        float *destination = (float *)&ring->data[slot];
        const float *source = input + (size_t)frame * channels;
        memset(destination, 0, sizeof(ChannelFrame));
        for (uint32_t i = 0; i < routed; ++i) {
            // A malformed driver/plugin sample must not poison the recursive meters indefinitely.
            // Preserve finite overs above full scale: only NaN and infinity become digital silence.
            float sample = source[sources[i]];
            destination[roles[i]] = isfinite(sample) ? sample : 0;
        }
        if (++slot == ring->capacity) slot = 0;
    }
    atomic_store_explicit(&ring->write_index, write + count, memory_order_release);
    if (count < frames) {
        atomic_fetch_add_explicit(&ring->dropped, frames - count, memory_order_relaxed);
        ring->overflow_frames += frames - count;
    }
    return count;
}

uint32_t channel_ring_read(ChannelRing *ring, ChannelFrame *destination, uint32_t max_frames) {
    if (!ring || !destination) return 0;
    uint64_t read = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    uint32_t available = (uint32_t)(write - read);
    uint32_t count = max_frames < available ? max_frames : available;
    // At most two contiguous runs: to the end of the ring, then from its start.
    uint32_t slot = (uint32_t)(read % ring->capacity);
    uint32_t first = ring->capacity - slot < count ? ring->capacity - slot : count;
    memcpy(destination, ring->data + slot, (size_t)first * sizeof(ChannelFrame));
    memcpy(destination + first, ring->data, (size_t)(count - first) * sizeof(ChannelFrame));
    atomic_store_explicit(&ring->read_index, read + count, memory_order_release);
    return count;
}

uint32_t channel_ring_read_marked(ChannelRing *ring, ChannelFrame *destination, uint32_t max_frames,
                                  ChannelRingMark *mark, int *has_mark) {
    *has_mark = 0;
    if (!ring || !destination) return 0;
    uint64_t read = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    // write_index before mark_write: every mark ahead of a visible frame is then visible too.
    uint64_t write = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    uint32_t merged = atomic_exchange_explicit(&ring->mark_overflow, 0, memory_order_relaxed);
    if (merged) {
        *mark = (ChannelRingMark){merged, 0, 0};
        *has_mark = 1;
        return 0;
    }
    uint64_t marks = atomic_load_explicit(&ring->mark_write, memory_order_acquire);
    uint64_t taken = atomic_load_explicit(&ring->mark_read, memory_order_relaxed);
    uint64_t limit = write;
    if (taken < marks) {
        const PositionedMark *next = &ring->marks[taken % CHANNEL_RING_MARKS];
        if (next->position <= read) {
            *mark = next->mark;
            *has_mark = 1;
            atomic_store_explicit(&ring->mark_read, taken + 1, memory_order_release);
            return 0;
        }
        if (next->position < limit) limit = next->position;
    }
    uint32_t available = (uint32_t)(limit - read);
    uint32_t count = max_frames < available ? max_frames : available;
    uint32_t slot = (uint32_t)(read % ring->capacity);
    uint32_t first = ring->capacity - slot < count ? ring->capacity - slot : count;
    memcpy(destination, ring->data + slot, (size_t)first * sizeof(ChannelFrame));
    memcpy(destination + first, ring->data, (size_t)(count - first) * sizeof(ChannelFrame));
    atomic_store_explicit(&ring->read_index, read + count, memory_order_release);
    return count;
}

uint64_t channel_ring_dropped(const ChannelRing *ring) {
    return ring ? atomic_load_explicit(&ring->dropped, memory_order_relaxed) : 0;
}

void channel_ring_sink_write(void *context, const float *interleaved, uint32_t frames, uint32_t channels) {
    ChannelRingSink *sink = context;
    if (sink) channel_ring_write(sink->ring, interleaved, frames, channels, sink->source_for_role);
}

void channel_ring_sink_boundary(void *context, uint32_t reasons, uint64_t lost_frames, uint32_t idle_ms) {
    ChannelRingSink *sink = context;
    if (sink) channel_ring_mark(sink->ring, reasons, lost_frames, idle_ms);
}
