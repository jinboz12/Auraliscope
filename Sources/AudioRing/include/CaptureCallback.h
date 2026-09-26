#ifndef CAPTURE_CALLBACK_H
#define CAPTURE_CALLBACK_H

#include <AudioToolbox/AudioToolbox.h>
#include "AudioRing.h"

// Everything the AUHAL input callback touches. Swift fills it before AudioOutputUnitStart and frees it only
// after the unit is disposed, so the IO thread never sees it change. The callback is C, not Swift: Core Audio's
// IO thread must not take locks, allocate, or run ARC and exclusivity checks.
typedef struct {
    AudioUnit _Nullable unit;
    ChannelRing *_Nullable ring;
    float *_Nullable storage;        // max_frames × channels interleaved Float32
    uint32_t max_frames;
    uint32_t channels;       // channels the unit delivers (only the routed device inputs)
    int32_t source_for_role[CHANNEL_ROLE_COUNT];  // index into those channels, or −1
} CaptureContext;

OSStatus capture_input_proc(void *_Nonnull context, AudioUnitRenderActionFlags *_Nonnull flags,
                            const AudioTimeStamp *_Nonnull timestamp, UInt32 bus, UInt32 frames,
                            AudioBufferList *_Nullable unused);

#endif
