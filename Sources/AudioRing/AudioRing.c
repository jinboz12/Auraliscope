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

struct ChannelRing {
    uint32_t capacity;
    ChannelFrame *data;
    _Atomic uint64_t write_index;
    _Atomic uint64_t read_index;
    _Atomic uint64_t dropped;
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
    return ring;
}

void channel_ring_destroy(ChannelRing *ring) {
    if (!ring) return;
    free(ring->data);
    free(ring);
}

void channel_ring_clear(ChannelRing *ring) {
    if (!ring) return;
    uint64_t write = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    atomic_store_explicit(&ring->read_index, write, memory_order_release);
    atomic_store_explicit(&ring->dropped, 0, memory_order_relaxed);
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
    if (count < frames) atomic_fetch_add_explicit(&ring->dropped, frames - count, memory_order_relaxed);
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

uint64_t channel_ring_dropped(const ChannelRing *ring) {
    return ring ? atomic_load_explicit(&ring->dropped, memory_order_relaxed) : 0;
}

void audio_gather_strided(const float *restrict source, uint32_t stride, float *restrict destination, uint32_t count) {
    if (stride == 1) {
        memcpy(destination, source, (size_t)count * sizeof(float));
        return;
    }
    uint32_t i = 0;
    // Four independent loads per iteration keep the load ports busy on long strides.
    for (; i + 4 <= count; i += 4) {
        float a = source[(size_t)i * stride];
        float b = source[(size_t)(i + 1) * stride];
        float c = source[(size_t)(i + 2) * stride];
        float d = source[(size_t)(i + 3) * stride];
        destination[i] = a;
        destination[i + 1] = b;
        destination[i + 2] = c;
        destination[i + 3] = d;
    }
    for (; i < count; i++) destination[i] = source[(size_t)i * stride];
}

typedef float float4 __attribute__((ext_vector_type(4)));

// Sixteen independent lanes (count is a multiple of four): one accumulator would wait on every addition.
static inline float dot4(const float *a, const float *b, uint32_t count) {
    float4 s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    uint32_t k = 0;
    for (; k + 16 <= count; k += 16) {
        float4 x0, x1, x2, x3, y0, y1, y2, y3;
        memcpy(&x0, a + k, sizeof x0);
        memcpy(&x1, a + k + 4, sizeof x1);
        memcpy(&x2, a + k + 8, sizeof x2);
        memcpy(&x3, a + k + 12, sizeof x3);
        memcpy(&y0, b + k, sizeof y0);
        memcpy(&y1, b + k + 4, sizeof y1);
        memcpy(&y2, b + k + 8, sizeof y2);
        memcpy(&y3, b + k + 12, sizeof y3);
        s0 += x0 * y0;
        s1 += x1 * y1;
        s2 += x2 * y2;
        s3 += x3 * y3;
    }
    for (; k + 4 <= count; k += 4) {
        float4 x, y;
        memcpy(&x, a + k, sizeof x);
        memcpy(&y, b + k, sizeof y);
        s0 += x * y;
    }
    float4 sum = (s0 + s1) + (s2 + s3);
    return (sum.x + sum.y) + (sum.z + sum.w);
}

// The largest of `count` non-negative floats (0 when empty).
static inline float max4(const float *a, uint32_t count) {
    float4 best = 0;
    uint32_t k = 0;
    for (; k + 4 <= count; k += 4) {
        float4 x;
        memcpy(&x, a + k, sizeof x);
        best = __builtin_elementwise_max(best, x);
    }
    float result = fmaxf(fmaxf(best.x, best.y), fmaxf(best.z, best.w));
    for (; k < count; k++) result = fmaxf(result, a[k]);
    return result;
}

// Magnitude at fine step q (−steps ≤ q < 2 × steps, steps = factor × refinement) from a candidate's sample:
// steps outside the sample's own interval read the window one sample earlier or later.
static inline float true_peak_step(const TruePeakCandidate *candidate, const TruePeakKernel *kernel, int32_t q) {
    int32_t steps = (int32_t)(kernel->factor * kernel->refinement);
    int32_t shift = q < 0 ? -1 : q >= steps ? 1 : 0;
    const float *window = candidate->taps + 1 + shift;
    return fabsf(dot4(window, kernel->fine + (size_t)(q - shift * steps) * kernel->taps, kernel->taps));
}

// The crest near one candidate.
static float true_peak_refine(const TruePeakCandidate *candidate, const TruePeakKernel *kernel) {
    // values[k] is fine step centre + k − 2r: up to two coarse steps either side of the candidate.
    int32_t r = (int32_t)kernel->refinement;
    int32_t centre = candidate->phase * r;  // 0 ≤ phase < factor: steps −2r … (factor + 1) r are in range
    float values[4 * TRUE_PEAK_MAX_REFINEMENT + 1];
    // Start with the candidate and one fine step either side; widen only while the loudest value sits on an
    // edge, so a crest past the neighbouring coarse point (or next to a sample) still gets neighbours on both
    // sides.
    int32_t low = 2 * r - 1, high = 2 * r + 1, best = low;
    for (int32_t k = low; k <= high; k++) {
        values[k] = true_peak_step(candidate, kernel, centre + k - 2 * r);
        if (values[k] > values[best]) best = k;
    }
    while (best == low && low > 0) {
        low--;
        values[low] = true_peak_step(candidate, kernel, centre + low - 2 * r);
        if (values[low] > values[best]) best = low;
    }
    while (best == high && high < 4 * r) {
        high++;
        values[high] = true_peak_step(candidate, kernel, centre + high - 2 * r);
        if (values[high] > values[best]) best = high;
    }
    float peak = values[best];
    if (best > low && best < high) {
        // Vertex of the parabola through the loudest step and its neighbours: at 1/16 sample the grid alone
        // would still under-read a 20 kHz crest by up to 0.03 dB.
        float a = values[best - 1], c = values[best + 1];
        float curvature = a - 2 * peak + c;
        if (curvature < 0) peak -= (a - c) * (a - c) / (8 * curvature);
    }
    return peak;
}

// Offers a local maximum to the current segment's candidates; ties go to the earliest point.
static void true_peak_offer(TruePeakSegment *state, const TruePeakKernel *kernel, float value, int32_t phase,
                            int64_t time, const float *window) {
    uint32_t slot = TRUE_PEAK_CANDIDATES;
    while (slot > 0 && (value > state->best[slot - 1].value ||
                        (value == state->best[slot - 1].value && time < state->best[slot - 1].time))) slot--;
    if (slot == TRUE_PEAK_CANDIDATES) return;
    memmove(&state->best[slot + 1], &state->best[slot], (TRUE_PEAK_CANDIDATES - 1 - slot) * sizeof state->best[0]);
    TruePeakCandidate *candidate = &state->best[slot];
    candidate->value = value;
    candidate->phase = phase;
    candidate->time = time;
    memcpy(candidate->taps, window, (kernel->taps + 2) * sizeof(float));
}

// Refines the current segment's candidates into *held and starts segment `next`.
static void true_peak_close(TruePeakSegment *state, const TruePeakKernel *kernel, int64_t next, float *held) {
    const TruePeakCandidate *first = &state->best[0];
    for (uint32_t i = 0; i < TRUE_PEAK_CANDIDATES; i++) {
        const TruePeakCandidate *candidate = &state->best[i];
        // Coarse magnitudes rank crests only roughly: refine every one close enough to the loudest.
        if (candidate->value > 0 && (i == 0 || candidate->value >= first->value * kernel->runner_up)) {
            float peak = true_peak_refine(candidate, kernel);
            if (peak > *held) *held = peak;
        }
    }
    for (uint32_t i = 0; i < TRUE_PEAK_CANDIDATES; i++) state->best[i].value = 0;
    state->segment = next;
}

// Decides whether the waiting point is a local maximum, now that its right-hand neighbour is `right`.
static void true_peak_settle(TruePeakSegment *state, const TruePeakKernel *kernel, float right, float *held) {
    TruePeakCandidate *tail = &state->tail;
    if (tail->value <= 0) return;
    if (state->tail_segment != state->segment) true_peak_close(state, kernel, state->tail_segment, held);
    if (tail->value > state->before && tail->value >= right) {
        true_peak_offer(state, kernel, tail->value, tail->phase, tail->time, tail->taps);
    }
}

void true_peak_finish(TruePeakSegment *state, const TruePeakKernel *kernel, int64_t next, float *held) {
    true_peak_settle(state, kernel, 0, held);
    state->tail.value = 0;
    state->before = 0;
    true_peak_close(state, kernel, next, held);
}

// Which phase `value` came from: an interpolating one, or else the sample itself (phase 0).
static inline int32_t true_peak_phase(const float *outputs, uint32_t stride, uint32_t phases, uint32_t at, float value) {
    for (uint32_t p = 0; p < phases; p++) {
        if (fabsf(outputs[(size_t)p * stride + at]) == value) return (int32_t)p + 1;
    }
    return 0;
}

void true_peak_scan(TruePeakSegment *state, const TruePeakKernel *kernel, const float *base, const float *outputs,
                    uint32_t stride, const float *loudest, uint32_t work, int64_t start, float *held) {
    if (work == 0) return;
    uint32_t phases = kernel->factor - 1;
    int64_t length = kernel->segment_length;
    // The point waiting from the previous block has its right-hand neighbour now.
    true_peak_settle(state, kernel, loudest[0], held);
    uint32_t i = 0;
    while (i + 1 < work) {
        int64_t segment = (start + i) / length;
        uint32_t end = (uint32_t)((segment + 1) * length - start);
        if (end > work - 1) end = work - 1;
        if (segment != state->segment) true_peak_close(state, kernel, segment, held);
        for (; i < end; i++) {
            // Only a local maximum that beats the weaker candidate and reaches the runner-up fraction of the
            // loudest so far can end up refined. Both bounds only rise within a segment, and they depend on the
            // points seen, not on where the buffers split, so what they skip is the same for every split.
            float weakest = state->best[TRUE_PEAK_CANDIDATES - 1].value;
            float floor = state->best[0].value * kernel->runner_up;
            if (i > 0 && i + 4 <= end) {
                // The whole test on four points at once; loudest[i + 4] exists because end < work.
                float4 value, left, right;
                memcpy(&value, loudest + i, sizeof value);
                memcpy(&left, loudest + i - 1, sizeof left);
                memcpy(&right, loudest + i + 1, sizeof right);
                if (!__builtin_reduce_or((value > weakest) & (value >= floor) & (value > left) & (value >= right))) {
                    i += 3;
                    continue;
                }
            }
            float value = loudest[i];
            float left = i > 0 ? loudest[i - 1] : state->tail.value;
            if (value > weakest && value >= floor && value > left && value >= loudest[i + 1]) {
                int32_t phase = true_peak_phase(outputs, stride, phases, i, value);
                true_peak_offer(state, kernel, value, phase, (start + i) * kernel->factor + phase, base + i);
            }
        }
    }
    // The newest point waits for the next block (or for silence) to show whether it is a local maximum.
    uint32_t last = work - 1;
    TruePeakCandidate *tail = &state->tail;
    state->before = last > 0 ? loudest[last - 1] : state->tail.value;
    state->tail_segment = (start + last) / length;
    tail->value = loudest[last];
    if (tail->value > 0) {
        tail->phase = true_peak_phase(outputs, stride, phases, last, tail->value);
        tail->time = (start + last) * kernel->factor + tail->phase;
        memcpy(tail->taps, base + last, (kernel->taps + 2) * sizeof(float));
    }
}

typedef double double4 __attribute__((ext_vector_type(4)));

// Eight channels share each pass as two four-lane vectors: one channel alone would wait on its own recursion
// (two dependent multiply-adds per section and sample), so the independent channels fill that latency.
// Missing lanes read a constant zero and are discarded.
static void k_weight_group(const double *c, double *const *state, const float *const *inputs, uint32_t lanes,
                           uint32_t count, double *energy) {
    static const float silence = 0;
    const float *in[8];
    size_t step[8];
    double s[4][8];  // s1 shelf, s2 shelf, s1 high-pass, s2 high-pass
    for (uint32_t lane = 0; lane < 8; lane++) {
        in[lane] = lane < lanes ? inputs[lane] : &silence;
        step[lane] = lane < lanes ? 1 : 0;
        for (uint32_t k = 0; k < 4; k++) s[k][lane] = lane < lanes ? state[lane][k] : 0;
    }
    // Every recursive quantity in a named vector, so the compiler keeps them all in registers.
    double4 a0, a1, a2, a3, b0v, b1v, b2v, b3v;
    memcpy(&a0, s[0], sizeof a0); memcpy(&b0v, s[0] + 4, sizeof b0v);
    memcpy(&a1, s[1], sizeof a1); memcpy(&b1v, s[1] + 4, sizeof b1v);
    memcpy(&a2, s[2], sizeof a2); memcpy(&b2v, s[2] + 4, sizeof b2v);
    memcpy(&a3, s[3], sizeof a3); memcpy(&b3v, s[3] + 4, sizeof b3v);
    const double b0 = c[0], b1 = c[1], b2 = c[2], f1 = c[3], f2 = c[4];
    const double d0 = c[5], d1 = c[6], d2 = c[7], e1 = c[8], e2 = c[9];
    double4 sumA = 0, sumB = 0;
    const float *i0 = in[0], *i1 = in[1], *i2 = in[2], *i3 = in[3], *i4 = in[4], *i5 = in[5], *i6 = in[6], *i7 = in[7];
    const size_t t0 = step[0], t1 = step[1], t2 = step[2], t3 = step[3], t4 = step[4], t5 = step[5], t6 = step[6], t7 = step[7];
    for (uint32_t i = 0; i < count; i++) {
        double4 xa = (double4){i0[i * t0], i1[i * t1], i2[i * t2], i3[i * t3]};
        double4 xb = (double4){i4[i * t4], i5[i * t5], i6[i * t6], i7[i * t7]};
        double4 ya = b0 * xa + a0, yb = b0 * xb + b0v;
        a0 = b1 * xa - f1 * ya + a1;
        b0v = b1 * xb - f1 * yb + b1v;
        a1 = b2 * xa - f2 * ya;
        b1v = b2 * xb - f2 * yb;
        double4 za = d0 * ya + a2, zb = d0 * yb + b2v;
        a2 = d1 * ya - e1 * za + a3;
        b2v = d1 * yb - e1 * zb + b3v;
        a3 = d2 * ya - e2 * za;
        b3v = d2 * yb - e2 * zb;
        sumA += za * za;
        sumB += zb * zb;
    }
    memcpy(s[0], &a0, sizeof a0); memcpy(s[0] + 4, &b0v, sizeof b0v);
    memcpy(s[1], &a1, sizeof a1); memcpy(s[1] + 4, &b1v, sizeof b1v);
    memcpy(s[2], &a2, sizeof a2); memcpy(s[2] + 4, &b2v, sizeof b2v);
    memcpy(s[3], &a3, sizeof a3); memcpy(s[3] + 4, &b3v, sizeof b3v);
    double sums[8];
    memcpy(sums, &sumA, sizeof sumA);
    memcpy(sums + 4, &sumB, sizeof sumB);
    for (uint32_t lane = 0; lane < lanes; lane++) {
        for (uint32_t k = 0; k < 4; k++) state[lane][k] = s[k][lane];
        energy[lane] += sums[lane];
    }
}

void k_weight_energy(const double *coefficients, double *const *state, const float *const *inputs, uint32_t channels,
                     uint32_t count, double *energy) {
    for (uint32_t first = 0; first < channels; first += 8) {
        uint32_t lanes = channels - first < 8 ? channels - first : 8;
        k_weight_group(coefficients, state + first, inputs + first, lanes, count, energy + first);
    }
}

// Three groups of four lanes share each sample, so their independent recursions overlap.
void band_filter(const float *coefficients, float *state, const float *left, const float *right, float *const *outputs,
                 uint32_t lanes, uint32_t count) {
    enum { groups = BAND_LANES / 4 };
    float4 c[groups][BAND_SECTIONS][5], s[groups][BAND_SECTIONS][2];
    memcpy(c, coefficients, sizeof c);
    memcpy(s, state, sizeof s);
    for (uint32_t i = 0; i < count; i++) {
        float4 x = (float4){left[i], right[i], left[i], right[i]};
        float4 y[groups];
        #pragma clang loop unroll(full)
        for (uint32_t g = 0; g < groups; g++) {
            float4 v = x;
            #pragma clang loop unroll(full)
            for (uint32_t k = 0; k < BAND_SECTIONS; k++) {
                float4 out = c[g][k][0] * v + s[g][k][0];
                s[g][k][0] = c[g][k][1] * v - c[g][k][3] * out + s[g][k][1];
                s[g][k][1] = c[g][k][2] * v - c[g][k][4] * out;
                v = out;
            }
            y[g] = v;
        }
        for (uint32_t lane = 0; lane < lanes; lane++) outputs[lane][i] = y[lane / 4][lane % 4];
    }
    memcpy(state, s, sizeof s);
}

void packed_pair_powers(const float *real, const float *imaginary, uint32_t n, float *power_a, float *power_b) {
    uint32_t half = n / 2, k = 1;
    // Bins k … k + 3 pair with n − k − 3 … n − k, read as one vector and reversed.
    for (; k + 4 <= half; k += 4) {
        float4 rk, ik, rm, im;
        memcpy(&rk, real + k, sizeof rk);
        memcpy(&ik, imaginary + k, sizeof ik);
        memcpy(&rm, real + n - k - 3, sizeof rm);
        memcpy(&im, imaginary + n - k - 3, sizeof im);
        rm = __builtin_shufflevector(rm, rm, 3, 2, 1, 0);
        im = __builtin_shufflevector(im, im, 3, 2, 1, 0);
        float4 sr = rk + rm, dr = rk - rm, si = ik + im, di = ik - im;
        float4 a = sr * sr + di * di, b = si * si + dr * dr;
        memcpy(power_a + k, &a, sizeof a);
        memcpy(power_b + k, &b, sizeof b);
    }
    for (; k < half; k++) {
        float sr = real[k] + real[n - k], dr = real[k] - real[n - k];
        float si = imaginary[k] + imaginary[n - k], di = imaginary[k] - imaginary[n - k];
        power_a[k] = sr * sr + di * di;
        power_b[k] = si * si + dr * dr;
    }
}
