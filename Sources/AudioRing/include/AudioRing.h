#ifndef AUDIO_RING_H
#define AUDIO_RING_H

#include <stdint.h>

// Frame types and the DSP kernels the analysis uses live in the shared analysis core.
#include "AnalysisKernels.h"

typedef struct AudioRing AudioRing;


AudioRing *audio_ring_create(uint32_t capacity);
void audio_ring_destroy(AudioRing *ring);
void audio_ring_clear(AudioRing *ring);
uint32_t audio_ring_write(AudioRing *ring, const float *interleaved, uint32_t frames, uint32_t channels);
uint32_t audio_ring_read(AudioRing *ring, StereoFrame *destination, uint32_t max_frames);
uint64_t audio_ring_dropped(const AudioRing *ring);

typedef struct ChannelRing ChannelRing;

ChannelRing *channel_ring_create(uint32_t capacity);
void channel_ring_destroy(ChannelRing *ring);
void channel_ring_clear(ChannelRing *ring);
uint32_t channel_ring_write(ChannelRing *ring, const float *interleaved, uint32_t frames,
                            uint32_t input_channels, const int32_t *source_for_role);
uint32_t channel_ring_read(ChannelRing *ring, ChannelFrame *destination, uint32_t max_frames);
uint64_t channel_ring_dropped(const ChannelRing *ring);
// A break in the audio: the frames after it do not continue the frames before it. The producer marks one where
// it happens (channel_ring_mark, before writing the frames after it); the ring marks one itself where it had to
// drop frames because it was full (CHANNEL_RING_OVERFLOW). `reasons` is the producer's own set of bits.
#define CHANNEL_RING_OVERFLOW (1u << 31)
typedef struct {
    uint32_t reasons;
    uint32_t idle_ms;       // how long the source did not deliver, when the producer knows
    uint64_t lost_frames;   // frames missing at the break, when known
} ChannelRingMark;
// Producer only; no allocation, no lock. Marks beyond a small queue merge into one (the consumer is stalled).
void channel_ring_mark(ChannelRing *ring, uint32_t reasons, uint64_t lost_frames, uint32_t idle_ms);
// Consumer: as channel_ring_read, but stops at the next break. When the read position has reached one, returns 0
// with *has_mark set and the break in *mark; reading again continues after it.
uint32_t channel_ring_read_marked(ChannelRing *ring, ChannelFrame *destination, uint32_t max_frames,
                                  ChannelRingMark *mark, int *has_mark);

// A ring plus the routing that maps a source's interleaved channels onto roles, for producers that deliver
// through a callback (the DAW Bridge receiver): `channel_ring_sink_write` has the signature of such a callback,
// with a `ChannelRingSink *` as its context. It runs on the producer's thread and is its only writer.
typedef struct {
    ChannelRing *ring;
    int32_t source_for_role[CHANNEL_ROLE_COUNT];
} ChannelRingSink;
void channel_ring_sink_write(void *context, const float *interleaved, uint32_t frames, uint32_t channels);
// The matching break callback: marks the ring (channel_ring_mark).
void channel_ring_sink_boundary(void *context, uint32_t reasons, uint64_t lost_frames, uint32_t idle_ms);

typedef struct MeterExchange MeterExchange;
// 64 spectrum bins, 16 peaks, 16 RMS, 16 true peaks, 16 held peaks, 16 held true peaks, 12 scalars (3 LUFS,
// loudness range, frame sequence, stream identity, dominant peak (2), detected format, waveform serial,
// L/R correlation, spectrogram serial), 512 spectrogram rows, 9 band groups (5 bands, 3, overall) ×
// (correlation, width, balance, level), 5 stereo bands × 128 (L, R) stereometer points, 16 roles × 5 band mean squares, 64 waveform
// columns × 16 roles × (min, max), then the analysis' continuity: breaks since it started, and seconds of audio
// known to be missing at them.
#define METER_SNAPSHOT_FLOATS 4126
MeterExchange *meter_exchange_create(void);
void meter_exchange_destroy(MeterExchange *exchange);
void meter_exchange_publish(MeterExchange *exchange, const float *values);
int meter_exchange_read(MeterExchange *exchange, float *values);
// A small setting the UI hands to the DSP queue without a lock (1 = spatial spectrum).
void meter_exchange_set_mode(MeterExchange *exchange, int mode);
int meter_exchange_mode(MeterExchange *exchange);
// Counts requests from the UI to clear the held true peaks; the DSP queue compares it with the last count it saw.
void meter_exchange_reset_true_peaks(MeterExchange *exchange);
unsigned meter_exchange_true_peak_resets(MeterExchange *exchange);

#endif
