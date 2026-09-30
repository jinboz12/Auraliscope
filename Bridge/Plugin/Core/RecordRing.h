#pragma once

// Single-producer, single-consumer ring of audio records between the host's audio thread (producer) and the
// Bridge analysis thread (consumer). Each record is a `CaptureRecord` header followed by its interleaved samples.
// The memory is allocated once, before any audio callback, and never resized. The producer never waits: when a
// record does not fit, `write` returns false and the caller counts the block as dropped.

#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>

#include "BridgeProtocol.h"

namespace abr {

// One block of live audio as the audio thread captured it. Private to the plugin: it never leaves the process.
struct CaptureRecord {
    uint32_t formatEpoch;
    uint32_t frames;
    uint32_t channels;
    uint32_t flags;              // ABR_AUDIO_* break reasons (with ABR_AUDIO_DISCONTINUITY), ABR_TRANSPORT_*
    uint32_t idleMs;             // with ABR_AUDIO_AFTER_IDLE: how long the host did not process
    uint32_t reserved;
    uint64_t position;           // stream position of the first frame (live frames processed in this session)
    double sampleRate;           // of this record's format epoch
};
static_assert(sizeof(CaptureRecord) % 4 == 0, "records keep samples 4-byte aligned");

class RecordRing {
public:
    // `capacity` must be a power of two and a multiple of 4.
    explicit RecordRing(size_t capacity) : capacity_(capacity), mask_(capacity - 1), data_(new uint8_t[capacity]()) {}

    RecordRing(const RecordRing &) = delete;
    RecordRing &operator=(const RecordRing &) = delete;

    static constexpr size_t recordBytes(uint32_t frames, uint32_t channels) {
        return sizeof(CaptureRecord) + size_t(frames) * channels * sizeof(float);
    }

    // Audio thread. Interleaves `channels` planar buffers straight into the ring: no allocation, no lock, no
    // system call. Returns false (and writes nothing) when the record does not fit.
    bool write(const CaptureRecord &header, const float *const *planar, uint32_t offset) noexcept {
        const size_t need = recordBytes(header.frames, header.channels);
        const uint64_t w = write_.load(std::memory_order_relaxed);
        const uint64_t r = read_.load(std::memory_order_acquire);
        if (need > capacity_ - size_t(w - r)) return false;
        copyIn(w, &header, sizeof header);
        uint64_t at = w + sizeof header;
        for (uint32_t frame = 0; frame < header.frames; ++frame) {
            for (uint32_t channel = 0; channel < header.channels; ++channel) {
                const float sample = planar[channel][offset + frame];
                std::memcpy(data_.get() + (at & mask_), &sample, sizeof sample);  // 4-byte aligned, never split
                at += sizeof(float);
            }
        }
        write_.store(w + need, std::memory_order_release);
        return true;
    }

    // Sender thread. Reads the next record's header without consuming it.
    bool peek(CaptureRecord &header) const noexcept {
        const uint64_t r = read_.load(std::memory_order_relaxed);
        const uint64_t w = write_.load(std::memory_order_acquire);
        if (w - r < sizeof header) return false;
        copyOut(r, &header, sizeof header);
        return true;
    }

    // Sender thread. Copies the next record's samples to `samples` (when non-null) and consumes it.
    void pop(float *samples) noexcept {
        CaptureRecord header;
        if (!peek(header)) return;
        const uint64_t r = read_.load(std::memory_order_relaxed);
        const size_t bytes = size_t(header.frames) * header.channels * sizeof(float);
        if (samples) copyOut(r + sizeof header, samples, bytes);
        read_.store(r + sizeof header + bytes, std::memory_order_release);
    }

    size_t usedBytes() const noexcept {
        return size_t(write_.load(std::memory_order_acquire) - read_.load(std::memory_order_relaxed));
    }
    size_t capacity() const noexcept { return capacity_; }

private:
    void copyIn(uint64_t at, const void *source, size_t bytes) noexcept {
        const size_t start = size_t(at & mask_);
        const size_t first = bytes < capacity_ - start ? bytes : capacity_ - start;
        std::memcpy(data_.get() + start, source, first);
        std::memcpy(data_.get(), static_cast<const uint8_t *>(source) + first, bytes - first);
    }
    void copyOut(uint64_t at, void *destination, size_t bytes) const noexcept {
        const size_t start = size_t(at & mask_);
        const size_t first = bytes < capacity_ - start ? bytes : capacity_ - start;
        std::memcpy(destination, data_.get() + start, first);
        std::memcpy(static_cast<uint8_t *>(destination) + first, data_.get(), bytes - first);
    }

    const size_t capacity_;
    const size_t mask_;
    std::unique_ptr<uint8_t[]> data_;
    alignas(64) std::atomic<uint64_t> write_{0};
    alignas(64) std::atomic<uint64_t> read_{0};
};

}  // namespace abr
