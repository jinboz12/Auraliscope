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

// What the host said about its transport for one block (all optional).
struct HostTransport {
    uint32_t flags = 0;          // ABR_TRANSPORT_KNOWN, ABR_TRANSPORT_PLAYING, ABR_TRANSPORT_POSITION
    int64_t position = 0;        // timeline sample of the block's first frame, with ABR_TRANSPORT_POSITION
};

struct CoreStatus {
    bool connected = false;       // a socket to Auraliscope is open and it accepted this plugin's protocol
    bool focusPending = false;    // "Show in Auraliscope" was clicked and not yet delivered
    bool subscribed = false;      // Auraliscope asked for this instance's audio
    bool receiverTooOld = false;  // the Auraliscope that answered speaks an older protocol
    bool receiverTooNew = false;  // … a newer one: this plugin needs an update
    uint32_t state = ABR_STATE_INACTIVE;
    double sampleRate = 0;
    uint32_t channels = 0;
    uint32_t formatEpoch = 0;
    uint32_t maxBlockFrames = 0;
    uint64_t framesProcessed = 0;
    uint64_t framesSent = 0;
    uint64_t framesDropped = 0;
    uint32_t interruptions = 0;
    uint32_t transportJumps = 0;
    uint32_t transportFlags = 0;
    double secondsSinceProcess = -1;  // since the host last called process (< 0: never)
    uint32_t identityFlags = 0;   // ABR_IDENTITY_*
    std::string sourceName;       // set by the user in the plugin window ("" when none)
    std::string trackName;        // reported by the host ("" when none)
    std::string instanceTag;      // short form of the persistent ID, to tell inserts apart
    std::string copiedFromTag;    // with ABR_IDENTITY_COPY: short form of the identity the saved state carried
};

class BridgeCore {
public:
    explicit BridgeCore(uint32_t pluginFormat);
    ~BridgeCore();
    BridgeCore(const BridgeCore &) = delete;
    BridgeCore &operator=(const BridgeCore &) = delete;

    // Host threads, while not processing. A sample-rate or channel change starts a new format epoch;
    // reactivating with the same format keeps the epoch and marks the next block as a restart.
    void configure(double sampleRate, uint32_t channels, uint32_t maxBlockFrames);
    void setActive(bool active);
    void setOffline(bool offline);
    // Any thread.
    void setBypassed(bool bypassed) noexcept;
    bool bypassed() const noexcept { return bypassed_.load(std::memory_order_relaxed); }

    // Audio thread. `input` holds `channels` planar buffers of `frames` samples. Never blocks, never allocates,
    // never makes a system call: atomics, a clock read from the commpage, and copies into a preallocated ring.
    void process(const float *const *input, uint32_t channels, uint32_t frames, const HostTransport &transport) noexcept;

    // UI and host threads.
    std::string sourceName() const;
    void setSourceName(const std::string &name);
    void setTrackName(const std::string &name);
    void setChannelID(const std::string &id);   // the host's unique channel ID ("" when none)
    std::string displayName() const;   // source name, else track name, else "Auraliscope Bridge <tag>"
    CoreStatus status() const;
    // UI thread: asks Auraliscope to make this instance its active source, now or as soon as it connects.
    void requestFocus() noexcept;
    std::string saveState() const;
    // Restores the name and the identity. When another live instance of this plugin in this process already
    // uses the saved identity (a duplicated track, pasted settings, a second copy of a project), this instance
    // keeps an identity of its own and reports itself as a copy; `identityReassigned` is then set so the wrapper
    // can tell the host its state changed.
    bool restoreState(const std::string &state, bool *identityReassigned = nullptr);

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
    uint8_t restoredId_[16] = {};
    uint32_t identityFlags_ = 0;
    std::string sourceName_, trackName_, channelID_;
    double sampleRate_ = 0;
    uint32_t channels_ = 0;
    uint32_t maxBlockFrames_ = 0;
    bool everActive_ = false;
    // Epoch (high 32 bits) and channel count (low 32) in one word, so the audio thread never pairs an epoch with
    // another epoch's channel count.
    std::atomic<uint64_t> formatWord_{0};
    std::atomic<double> rtSampleRate_{0};
    std::atomic<bool> active_{false};
    std::atomic<bool> offline_{false};
    std::atomic<bool> bypassed_{false};
    std::atomic<uint32_t> breaks_{0};           // ABR_AUDIO_AFTER_* set by control threads for the next live block
    std::atomic<uint32_t> settingsSerial_{0};   // bumped on name changes so STATUS goes out at once
    std::atomic<bool> identityChanged_{false};  // a new identity must reach Auraliscope in a new HELLO
    std::atomic<bool> focusRequested_{false};   // "Show in Auraliscope", sent once connected

    // Audio thread state.
    RecordRing ring_;
    uint64_t position_ = 0;
    uint32_t reasons_ = ABR_AUDIO_STREAM_START;  // pending for the next transmitted block
    uint32_t idleMs_ = 0;
    uint32_t lastToken_ = 0;
    uint64_t lastCallTicks_ = 0;
    uint32_t lastFrames_ = 0;
    HostTransport lastTransport_{};
    double ticksToNs_ = 1;
    std::atomic<uint64_t> lastCallNs_{0};
    std::atomic<uint64_t> framesProcessed_{0};
    std::atomic<uint64_t> framesDropped_{0};
    std::atomic<uint32_t> transportFlags_{0};
    std::atomic<uint32_t> interruptions_{0};
    std::atomic<uint32_t> transportJumps_{0};

    // Sender thread state (the atomics are also read by the UI).
    std::atomic<uint32_t> subscription_{0};     // 0: not transmitting
    std::atomic<bool> connected_{false};
    std::atomic<bool> receiverTooOld_{false};
    std::atomic<bool> receiverTooNew_{false};
    std::atomic<uint64_t> framesSent_{0};
    int fd_ = -1;
    bool welcomed_ = false;
    uint64_t lastAttemptNs_ = 0;
    uint64_t lastStatusNs_ = 0;
    uint32_t lastStatusState_ = 0xFFFFFFFF, lastStatusEpoch_ = 0, lastSettingsSerial_ = 0, lastStatusFlags_ = 0;
    uint32_t sendSequence_ = 0;
    uint32_t sentFormatEpoch_ = 0;
    uint32_t senderReasons_ = 0;
    uint32_t senderIdleMs_ = 0;  // with ABR_AUDIO_AFTER_IDLE in senderReasons_: carried from a discarded record
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

// Identities claimed by live instances of this binary in this process (see BridgeCore::restoreState).
// `claimIdentity` returns false, and changes nothing, when another instance holds `id`.
bool claimIdentity(const BridgeCore *core, const uint8_t id[16]);
void releaseIdentity(const BridgeCore *core);

// For tests: whether the sender thread is running.
bool senderRunning();

}  // namespace abr
