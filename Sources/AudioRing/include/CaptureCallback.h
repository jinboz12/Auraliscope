#ifndef CAPTURE_CALLBACK_H
#define CAPTURE_CALLBACK_H

#include <AudioToolbox/AudioToolbox.h>
#include "AudioRing.h"

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
