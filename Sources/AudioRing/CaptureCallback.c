#include "CaptureCallback.h"

OSStatus capture_input_proc(void *_Nonnull context, AudioUnitRenderActionFlags *_Nonnull flags,
                            const AudioTimeStamp *_Nonnull timestamp, UInt32 bus, UInt32 frames,
                            AudioBufferList *_Nullable unused) {
    (void)bus;
    (void)unused;
    CaptureContext *capture = context;
    if (frames > capture->max_frames) return kAudioUnitErr_TooManyFramesToProcess;
    AudioBufferList buffers;
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0].mNumberChannels = capture->channels;
    buffers.mBuffers[0].mDataByteSize = frames * capture->channels * (UInt32)sizeof(float);
    buffers.mBuffers[0].mData = capture->storage;
    OSStatus status = AudioUnitRender(capture->unit, flags, timestamp, 1, frames, &buffers);
    if (status == noErr) channel_ring_write(capture->ring, capture->storage, frames, capture->channels, capture->source_for_role);
    return status;
}
