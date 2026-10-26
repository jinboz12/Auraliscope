#ifndef CAPTURE_CALLBACK_H
#define CAPTURE_CALLBACK_H

#include <AudioToolbox/AudioToolbox.h>
#include "AudioRing.h"

// What the IO callback saw since its capture last opened: the health of the capture, as opposed to its audio. The IO
// thread alone writes it, with relaxed atomics (a few stores per callback: no lock, allocation or signal); the main
// thread reads it at the readout rate to tell a capture that keeps failing from a passing glitch. Each field is read
// on its own, so a reading taken while IO runs may straddle one callback.
typedef struct CaptureHealth CaptureHealth;
// Why a callback lost frames.
#define CAPTURE_FAILURE_REFUSED (1u << 0)     // the device refused the slice (AudioUnitRender's status)
#define CAPTURE_FAILURE_OVERSIZE (1u << 1)    // a slice longer than the storage: nothing written
#define CAPTURE_FAILURE_TRUNCATED (1u << 2)   // an output-tap delivery longer than the storage: its tail cut off
typedef struct {
    uint64_t delivered_frames;    // frames written by callbacks that lost none
    uint64_t delivered_slices;    // callbacks that wrote every frame they had
    uint64_t failed_slices;       // callbacks that lost frames
    uint64_t run_slices;          // consecutive callbacks that lost frames, up to the newest (0 after a whole one)
    uint64_t run_lost_frames;     // frames those callbacks lost
    uint32_t run_failures;        // CAPTURE_FAILURE_* bits seen in that run
    int32_t last_status;          // the newest refusal's OSStatus (0 before any)
    uint32_t largest_slice;       // the longest slice or delivery the callback was given
} CaptureHealthReading;
CaptureHealth *_Nullable capture_health_create(void);
void capture_health_destroy(CaptureHealth *_Nullable health);
// With no IO running: nothing seen yet.
void capture_health_reset(CaptureHealth *_Nullable health);
void capture_health_read(const CaptureHealth *_Nullable health, CaptureHealthReading *_Nonnull reading);

// Everything the input callbacks touch. Swift fills it before IO starts and frees it only after the unit is
// disposed or the IOProc destroyed, so the IO thread never sees it change. The callbacks are C, not Swift: Core
// Audio's IO thread must not take locks, allocate, or run ARC and exclusivity checks.
typedef struct {
    AudioUnit _Nullable unit;        // the AUHAL of an input source; NULL for an output tap
    ChannelRing *_Nullable ring;
    float *_Nullable storage;        // max_frames × channels interleaved Float32
    uint32_t max_frames;
    uint32_t channels;       // channels delivered: the routed device inputs, or every channel of a tap
    int32_t source_for_role[CHANNEL_ROLE_COUNT];  // index into those channels, or −1
    CaptureHealth *_Nullable health;  // what the callbacks saw; may be NULL
} CaptureContext;

OSStatus capture_input_proc(void *_Nonnull context, AudioUnitRenderActionFlags *_Nonnull flags,
                            const AudioTimeStamp *_Nonnull timestamp, UInt32 bus, UInt32 frames,
                            AudioBufferList *_Nullable unused);

// An output tap's private aggregate device, read by a plain device IOProc. Through the AUHAL input element macOS
// would treat the tap as microphone use (a microphone permission check and the orange indicator).
OSStatus capture_tap_io_proc(AudioObjectID device, const AudioTimeStamp *_Nonnull now,
                             const AudioBufferList *_Nonnull input, const AudioTimeStamp *_Nonnull input_time,
                             AudioBufferList *_Nonnull output, const AudioTimeStamp *_Nonnull output_time,
                             void *_Nullable context);

#endif
