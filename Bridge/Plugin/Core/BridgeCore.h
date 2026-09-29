#pragma once

// Everything Auraliscope Bridge does that does not depend on the plugin format. The VST3 and AU wrappers own one
// `BridgeCore` per plugin instance and forward the host's calls to it:
//
//   configure / setActive / setOffline   host (non-real-time) threads, while the host is not processing
//   setBypassed                          any thread, the audio thread included
//   process                              the host's audio thread: copies into a preallocated ring, nothing else
//   status / names / state               UI and host threads
//
// Communication with Auraliscope runs on one sender thread per process (shared by every instance of the same
// binary), which drains each instance's ring into its own socket.

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

#include "BridgeProtocol.h"
#include "RecordRing.h"

namespace abr {

struct CoreStatus {
    bool connected = false;       // a socket to Auraliscope is open
    bool focusPending = false;    // "Show in Auraliscope" was clicked and not yet delivered
    bool subscribed = false;      // Auraliscope asked for this instance's audio
    uint32_t state = ABR_STATE_INACTIVE;
    double sampleRate = 0;
    uint32_t channels = 0;
    uint32_t formatEpoch = 0;
    uint32_t maxBlockFrames = 0;
    uint64_t framesProcessed = 0;
    uint64_t framesSent = 0;
    uint64_t framesDropped = 0;
    uint32_t transportFlags = 0;
    std::string sourceName;       // set by the user in the plugin window ("" when none)
    std::string trackName;        // reported by the host ("" when none)
    std::string instanceTag;      // short form of the persistent ID, to tell copies apart
};

class BridgeCore {
public:
    explicit BridgeCore(uint32_t pluginFormat);
    ~BridgeCore();
    BridgeCore(const BridgeCore &) = delete;
    BridgeCore &operator=(const BridgeCore &) = delete;

    // Host threads, while not processing. Every call that changes the format starts a new format epoch.
    void configure(double sampleRate, uint32_t channels, uint32_t maxBlockFrames);
    void setActive(bool active);
    void setOffline(bool offline);
    // Any thread.
    void setBypassed(bool bypassed) noexcept { bypassed_.store(bypassed, std::memory_order_relaxed); }
    bool bypassed() const noexcept { return bypassed_.load(std::memory_order_relaxed); }

    // Audio thread. `input` holds `channels` planar buffers of `frames` samples. Never blocks, never allocates.
    void process(const float *const *input, uint32_t channels, uint32_t frames, uint32_t transportFlags) noexcept;

    // UI and host threads.
    std::string sourceName() const;
    void setSourceName(const std::string &name);
    void setTrackName(const std::string &name);
    std::string displayName() const;   // source name, else track name, else "Auraliscope Bridge <tag>"
    CoreStatus status() const;
    // UI thread: asks Auraliscope to make this instance its active source, now or as soon as it connects.
    void requestFocus() noexcept;
    std::string saveState() const;
    bool restoreState(const std::string &state);

    // Sender thread only (see BridgeSender.cpp).
    void service(uint64_t nowNs);
    void disconnect();

private:
    uint32_t effectiveState() const noexcept;
    void queue(uint16_t type, const void *payload, uint32_t length);
    void queueStatus(uint64_t nowNs);
    bool readControl();
    bool flush();
    void drainRing();

    const uint32_t format_;
    uint8_t sessionId_[16];

    // Configuration, written by host threads under `configLock_`; the audio thread only reads the atomics.
    mutable std::mutex configLock_;
    uint8_t persistentId_[16];
    std::string sourceName_, trackName_;
    double sampleRate_ = 0;
    uint32_t channels_ = 0;
    uint32_t maxBlockFrames_ = 0;
    std::atomic<uint32_t> epoch_{0};
    std::atomic<uint32_t> rtChannels_{0};
    std::atomic<bool> active_{false};
    std::atomic<bool> offline_{false};
    std::atomic<bool> bypassed_{false};
    std::atomic<uint32_t> settingsSerial_{0};   // bumped on name changes so STATUS goes out at once
    std::atomic<bool> identityChanged_{false};  // a restored project ID must reach Auraliscope in a new HELLO
    std::atomic<bool> focusRequested_{false};   // "Show in Auraliscope", sent once connected

    // Audio thread state.
    RecordRing ring_;
    uint64_t position_ = 0;
    bool pendingDiscontinuity_ = true;
    uint32_t lastRtState_ = ABR_STATE_INACTIVE;
    std::atomic<uint64_t> framesProcessed_{0};
    std::atomic<uint64_t> framesDropped_{0};
    std::atomic<uint32_t> transportFlags_{0};

    // Sender thread state (the atomics are also read by the UI).
    std::atomic<bool> transmit_{false};
    std::atomic<bool> connected_{false};
    std::atomic<uint64_t> framesSent_{0};
    int fd_ = -1;
    uint64_t lastAttemptNs_ = 0;
    uint64_t lastStatusNs_ = 0;
    uint32_t lastStatusState_ = 0xFFFFFFFF, lastStatusEpoch_ = 0, lastSettingsSerial_ = 0, lastStatusFlags_ = 0;
    uint32_t sendSequence_ = 0;
    uint32_t sentFormatEpoch_ = 0;
    bool senderDiscontinuity_ = false;
    std::unique_ptr<uint8_t[]> out_;
    size_t outUsed_ = 0, outSent_ = 0;
    uint8_t in_[256];
    size_t inUsed_ = 0;
    std::unique_ptr<float[]> scratch_;
};

// The process-wide sender thread. Instances register on construction and unregister on destruction; the thread
// runs while at least one instance exists, so unloading the plugin binary never leaves a thread behind.
void registerCore(BridgeCore *core);
void unregisterCore(BridgeCore *core);

}  // namespace abr
