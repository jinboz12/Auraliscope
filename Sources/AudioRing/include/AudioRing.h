#ifndef AUDIO_RING_H
#define AUDIO_RING_H

#include <stdint.h>

typedef struct AudioRing AudioRing;

typedef struct {
    float left;
    float right;
} StereoFrame;

AudioRing *audio_ring_create(uint32_t capacity);
void audio_ring_destroy(AudioRing *ring);
void audio_ring_clear(AudioRing *ring);
uint32_t audio_ring_write(AudioRing *ring, const float *interleaved, uint32_t frames, uint32_t channels);
uint32_t audio_ring_read(AudioRing *ring, StereoFrame *destination, uint32_t max_frames);
uint64_t audio_ring_dropped(const AudioRing *ring);

typedef struct ChannelRing ChannelRing;
// One frame of every speaker role, up to 9.1.6. Role indices 0–7 keep their 5.1.2 meaning so saved
// routing stays valid; 8–15 extend the layout (rear surrounds, wides, top middle, top rear).
#define CHANNEL_ROLE_COUNT 16
typedef struct {
    float left, right, center, lfe, leftSurround, rightSurround, leftTopFront, rightTopFront;
    float leftRearSurround, rightRearSurround, leftWide, rightWide;
    float leftTopMiddle, rightTopMiddle, leftTopRear, rightTopRear;
} ChannelFrame;

ChannelRing *channel_ring_create(uint32_t capacity);
void channel_ring_destroy(ChannelRing *ring);
void channel_ring_clear(ChannelRing *ring);
uint32_t channel_ring_write(ChannelRing *ring, const float *interleaved, uint32_t frames,
                            uint32_t input_channels, const int32_t *source_for_role);
uint32_t channel_ring_read(ChannelRing *ring, ChannelFrame *destination, uint32_t max_frames);
uint64_t channel_ring_dropped(const ChannelRing *ring);

typedef struct MeterExchange MeterExchange;
// 64 spectrum bins, 16 peaks, 16 RMS, 16 true peaks, 16 held peaks, 16 held true peaks, 12 scalars (3 LUFS,
// loudness range, frame sequence, stream identity, dominant peak (2), detected format, waveform serial,
// L/R correlation, spectrogram serial), 512 spectrogram rows, 9 band groups (5 bands, 3, overall) ×
// (correlation, width, balance, level), 5 stereo bands × 128 (L, R) stereometer points, 16 roles × 5 band mean squares, then 64 waveform
// columns × 16 roles × (min, max).
#define METER_SNAPSHOT_FLOATS 4124
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
