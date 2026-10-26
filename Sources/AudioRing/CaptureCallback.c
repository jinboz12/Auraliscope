#include "CaptureCallback.h"

OSStatus capture_input_proc(void *_Nonnull context, AudioUnitRenderActionFlags *_Nonnull flags,
                            const AudioTimeStamp *_Nonnull timestamp, UInt32 bus, UInt32 frames,
                            AudioBufferList *_Nullable unused) {
    (void)bus;
    (void)unused;
    CaptureContext *capture = context;
    if (frames > capture->max_frames) {
        // Too long for the storage: nothing is written, so these frames are a break in the audio.
        channel_ring_lose(capture->ring, frames);
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    AudioBufferList buffers;
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0].mNumberChannels = capture->channels;
    buffers.mBuffers[0].mDataByteSize = frames * capture->channels * (UInt32)sizeof(float);
    buffers.mBuffers[0].mData = capture->storage;
    OSStatus status = AudioUnitRender(capture->unit, flags, timestamp, 1, frames, &buffers);
    if (status == noErr) channel_ring_write(capture->ring, capture->storage, frames, capture->channels, capture->source_for_role);
    else channel_ring_lose(capture->ring, frames);  // refused (during a device rate change, for one): a break, counted
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
    uint32_t lost = frames > capture->max_frames ? frames - capture->max_frames : 0;
    if (frames > capture->max_frames) frames = capture->max_frames;
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
