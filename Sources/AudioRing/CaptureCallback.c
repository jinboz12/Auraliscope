#include "CaptureCallback.h"
#include <stdatomic.h>
#include <stdlib.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit atomics must be lock-free");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "32-bit atomics must be lock-free");

struct CaptureHealth {
    _Atomic uint64_t delivered_frames;
    _Atomic uint64_t delivered_slices;
    _Atomic uint64_t failed_slices;
    _Atomic uint64_t run_slices;
    _Atomic uint64_t run_lost_frames;
    _Atomic uint32_t run_failures;
    _Atomic int32_t last_status;
    _Atomic uint32_t largest_slice;
};

CaptureHealth *capture_health_create(void) {
    CaptureHealth *health = calloc(1, sizeof(CaptureHealth));
    capture_health_reset(health);
    return health;
}

void capture_health_destroy(CaptureHealth *health) { free(health); }

void capture_health_reset(CaptureHealth *health) {
    if (!health) return;
    atomic_store_explicit(&health->delivered_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&health->delivered_slices, 0, memory_order_relaxed);
    atomic_store_explicit(&health->failed_slices, 0, memory_order_relaxed);
    atomic_store_explicit(&health->run_slices, 0, memory_order_relaxed);
    atomic_store_explicit(&health->run_lost_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&health->run_failures, 0, memory_order_relaxed);
    atomic_store_explicit(&health->last_status, 0, memory_order_relaxed);
    atomic_store_explicit(&health->largest_slice, 0, memory_order_relaxed);
}

void capture_health_read(const CaptureHealth *health, CaptureHealthReading *reading) {
    *reading = (CaptureHealthReading){0};
    if (!health) return;
    CaptureHealth *record = (CaptureHealth *)health;
    reading->delivered_frames = atomic_load_explicit(&record->delivered_frames, memory_order_relaxed);
    reading->delivered_slices = atomic_load_explicit(&record->delivered_slices, memory_order_relaxed);
    reading->failed_slices = atomic_load_explicit(&record->failed_slices, memory_order_relaxed);
    reading->run_slices = atomic_load_explicit(&record->run_slices, memory_order_relaxed);
    reading->run_lost_frames = atomic_load_explicit(&record->run_lost_frames, memory_order_relaxed);
    reading->run_failures = atomic_load_explicit(&record->run_failures, memory_order_relaxed);
    reading->last_status = atomic_load_explicit(&record->last_status, memory_order_relaxed);
    reading->largest_slice = atomic_load_explicit(&record->largest_slice, memory_order_relaxed);
}

// The IO thread is the record's only writer: plain relaxed loads and stores, no read-modify-write.
static inline void health_add(_Atomic uint64_t *field, uint64_t amount) {
    atomic_store_explicit(field, atomic_load_explicit(field, memory_order_relaxed) + amount, memory_order_relaxed);
}

static inline void health_size(CaptureHealth *health, uint32_t frames) {
    if (frames > atomic_load_explicit(&health->largest_slice, memory_order_relaxed)) {
        atomic_store_explicit(&health->largest_slice, frames, memory_order_relaxed);
    }
}

// A callback that wrote every one of its `frames`: any failing run is over.
static inline void health_delivered(CaptureHealth *_Nullable health, uint32_t frames) {
    if (!health) return;
    health_size(health, frames);
    health_add(&health->delivered_frames, frames);
    health_add(&health->delivered_slices, 1);
    atomic_store_explicit(&health->run_slices, 0, memory_order_relaxed);
    atomic_store_explicit(&health->run_lost_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&health->run_failures, 0, memory_order_relaxed);
}

// A callback given `frames` that lost `lost` of them, for `failure`; `status` is the device's refusal, or noErr.
static inline void health_failed(CaptureHealth *_Nullable health, uint32_t frames, uint64_t lost, uint32_t failure,
                                 OSStatus status) {
    if (!health) return;
    health_size(health, frames);
    health_add(&health->failed_slices, 1);
    health_add(&health->run_slices, 1);
    health_add(&health->run_lost_frames, lost);
    uint32_t failures = atomic_load_explicit(&health->run_failures, memory_order_relaxed);
    atomic_store_explicit(&health->run_failures, failures | failure, memory_order_relaxed);
    if (status != noErr) atomic_store_explicit(&health->last_status, status, memory_order_relaxed);
}

OSStatus capture_input_proc(void *_Nonnull context, AudioUnitRenderActionFlags *_Nonnull flags,
                            const AudioTimeStamp *_Nonnull timestamp, UInt32 bus, UInt32 frames,
                            AudioBufferList *_Nullable unused) {
    (void)bus;
    (void)unused;
    CaptureContext *capture = context;
    if (frames > capture->max_frames) {
        // Too long for the storage: nothing is written, so these frames are a break in the audio.
        channel_ring_lose(capture->ring, frames);
        health_failed(capture->health, frames, frames, CAPTURE_FAILURE_OVERSIZE, noErr);
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    AudioBufferList buffers;
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0].mNumberChannels = capture->channels;
    buffers.mBuffers[0].mDataByteSize = frames * capture->channels * (UInt32)sizeof(float);
    buffers.mBuffers[0].mData = capture->storage;
    OSStatus status = AudioUnitRender(capture->unit, flags, timestamp, 1, frames, &buffers);
    if (status == noErr) {
        channel_ring_write(capture->ring, capture->storage, frames, capture->channels, capture->source_for_role);
        health_delivered(capture->health, frames);
    } else {
        // Refused (during a device rate change, for one): a break, counted.
        channel_ring_lose(capture->ring, frames);
        health_failed(capture->health, frames, frames, CAPTURE_FAILURE_REFUSED, status);
    }
    return status;
}

OSStatus capture_tap_io_proc(AudioObjectID device, const AudioTimeStamp *_Nonnull now,
                             const AudioBufferList *_Nonnull input, const AudioTimeStamp *_Nonnull input_time,
                             AudioBufferList *_Nonnull output, const AudioTimeStamp *_Nonnull output_time,
                             void *_Nullable context) {
    (void)device;
    (void)now;
    (void)input_time;
    (void)output;
    (void)output_time;
    CaptureContext *capture = context;
    if (!capture || capture->channels == 0 || input->mNumberBuffers == 0) return noErr;
    const AudioBuffer *first = &input->mBuffers[0];
    // A tap is one interleaved Float32 stream: it goes to the ring as it is.
    if (input->mNumberBuffers == 1 && first->mData && first->mNumberChannels == capture->channels) {
        uint32_t frames = first->mDataByteSize / (capture->channels * (uint32_t)sizeof(float));
        channel_ring_write(capture->ring, first->mData, frames, capture->channels, capture->source_for_role);
        if (frames > 0) health_delivered(capture->health, frames);
        return noErr;
    }
    // Otherwise (several streams, or more channels than are kept) interleave into storage; a stream without data
    // reads as silence.
    if (!capture->storage) return noErr;
    uint32_t frames = 0;
    for (uint32_t index = 0; index < input->mNumberBuffers; index++) {
        const AudioBuffer *buffer = &input->mBuffers[index];
        if (buffer->mData && buffer->mNumberChannels > 0) {
            frames = buffer->mDataByteSize / (buffer->mNumberChannels * (uint32_t)sizeof(float));
            break;
        }
    }
    // Frames beyond the storage are cut off, after the frames kept: a break, marked at the next write.
    uint32_t given = frames;
    uint32_t lost = frames > capture->max_frames ? frames - capture->max_frames : 0;
    if (frames > capture->max_frames) frames = capture->max_frames;
    if (lost > 0) health_failed(capture->health, given, lost, CAPTURE_FAILURE_TRUNCATED, noErr);
    else if (frames > 0) health_delivered(capture->health, frames);
    if (frames == 0) {
        channel_ring_lose(capture->ring, lost);
        return noErr;
    }
    uint32_t base = 0;
    for (uint32_t index = 0; index < input->mNumberBuffers && base < capture->channels; index++) {
        const AudioBuffer *buffer = &input->mBuffers[index];
        uint32_t width = buffer->mNumberChannels;
        uint32_t kept = width < capture->channels - base ? width : capture->channels - base;
        const float *samples = buffer->mData;
        uint32_t available = width > 0 && samples ? buffer->mDataByteSize / (width * (uint32_t)sizeof(float)) : 0;
        for (uint32_t frame = 0; frame < frames; frame++) {
            float *destination = capture->storage + (size_t)frame * capture->channels + base;
            for (uint32_t channel = 0; channel < kept; channel++) {
                destination[channel] = frame < available ? samples[(size_t)frame * width + channel] : 0;
            }
        }
        base += width;
    }
    for (uint32_t frame = 0; frame < frames && base < capture->channels; frame++) {
        float *destination = capture->storage + (size_t)frame * capture->channels + base;
        for (uint32_t channel = 0; channel < capture->channels - base; channel++) destination[channel] = 0;
    }
    channel_ring_write(capture->ring, capture->storage, frames, capture->channels, capture->source_for_role);
    channel_ring_lose(capture->ring, lost);
    return noErr;
}
