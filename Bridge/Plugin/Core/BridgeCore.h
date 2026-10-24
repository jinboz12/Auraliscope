#pragma once

// Everything Auraliscope Bridge does that does not depend on the plugin format. The VST3 and AU wrappers own one
// `BridgeCore` per plugin instance and forward the host's calls to it:
//
//   configure / setActive / setOffline   host (non-real-time) threads, while the host is not processing
//   setBypassed                          any thread, the audio thread included
//   process                              the host's audio thread: copies into a preallocated ring, nothing else
//   status / names / state / commands    UI and host threads
//
// Each instance analyses its own audio. Two threads per process (shared by every instance of the same binary) do
// the rest, never the audio thread:
//   the analysis thread (BridgeAnalysisHub.cpp) drains each instance's ring into its analyser (the shared analysis
//     core, Sources/AnalysisCore) and prepares the newest result for sending;
//   the sender thread (BridgeSender.cpp) talks to Auraliscope Labs: identity, status, results, commands.
// The analysis runs whether or not Labs is open and whether or not the plugin window is.

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "BridgeAnalysis.h"
#include "BridgeProtocol.h"
#include "RecordRing.h"

namespace abr {

// An insert's channels: how many, and each one's speaker role (ABR_ROLE_*, in the bus's channel order), with the
// layout's name. Mono is [L], stereo [L R]; an immersive bus has up to ABR_MAX_CHANNELS distinct roles.
struct ChannelLayout {
    uint32_t channels = 0;
    uint8_t roles[ABR_MAX_CHANNELS] = {};
    char name[16] = {};

    static ChannelLayout mono();
    static ChannelLayout stereo();
    // Mono for 1 channel, stereo for 2; anything else has no roles (and is not analysed).
    static ChannelLayout standard(uint32_t channels);
    // From a role list; `name` is the layout's (e.g. "7.1.4"), or derived from the roles when empty.
    static ChannelLayout speakers(const uint8_t *roles, uint32_t channels, const char *name = "");
    // The analysable layouts: [L], or up to ABR_MAX_CHANNELS distinct roles including L and R.
    bool valid() const;
    // ABR_LAYOUT_MONO, _STEREO or _SPEAKERS (ABR_LAYOUT_UNKNOWN when not valid).
    uint32_t kind() const;
    // Four bits per channel, channel 0 lowest: carried with every captured block.
    uint64_t packedRoles() const;
    bool operator==(const ChannelLayout &other) const;
    bool operator!=(const ChannelLayout &other) const { return !(*this == other); }
};

// A role's short name as Auraliscope shows it within `layout` (the surrounds are Lss/Rss beside rear surrounds).
const char *roleName(uint32_t role, const ChannelLayout &layout);

// What the host said about its transport for one block (all optional).
struct HostTransport {
    uint32_t flags = 0;          // ABR_TRANSPORT_KNOWN, ABR_TRANSPORT_PLAYING, ABR_TRANSPORT_POSITION
    int64_t position = 0;        // timeline sample of the block's first frame, with ABR_TRANSPORT_POSITION
};

struct CoreStatus {
    bool connected = false;       // a socket to Auraliscope is open and it accepted this plugin's protocol
    bool focusPending = false;    // "Show in Auraliscope" was clicked and not yet delivered
    bool subscribed = false;      // Auraliscope asked for this instance's results
    bool receiverTooOld = false;  // the Auraliscope that answered speaks an older protocol
    bool receiverTooNew = false;  // … a newer one: this plugin needs an update
    uint32_t state = ABR_STATE_INACTIVE;
    double sampleRate = 0;
    uint32_t channels = 0;
    ChannelLayout layout;
    uint32_t formatEpoch = 0;
    uint32_t maxBlockFrames = 0;
    uint64_t framesProcessed = 0;
    uint64_t framesDropped = 0;   // live frames the analysis queue could not take
    uint64_t resultsSent = 0;
    uint32_t interruptions = 0;
    uint32_t transportJumps = 0;
    uint32_t transportFlags = 0;
    double secondsSinceProcess = -1;  // since the host last called process (< 0: never)
    uint32_t identityFlags = 0;   // ABR_IDENTITY_*
    std::string sourceName;       // set by the user in the plugin window ("" when none)
    std::string trackName;        // reported by the host ("" when none)
    std::string instanceTag;      // short form of the persistent ID, to tell inserts apart
    std::string copiedFromTag;    // with ABR_IDENTITY_COPY: short form of the identity the saved state carried
    // The instance's own measurement.
    uint32_t measurement = ABR_MEASUREMENT_NONE;
    bool hasAnalysis = false;     // an analyser exists and has published at least once
    AbrAnalysisSummary analysis{};
    uint32_t backlogMs = 0;       // audio waiting for the analysis thread
};

class BridgeCore {
public:
    explicit BridgeCore(uint32_t pluginFormat);
    ~BridgeCore();
    BridgeCore(const BridgeCore &) = delete;
    BridgeCore &operator=(const BridgeCore &) = delete;

    // Host threads, while not processing. A sample-rate or channel-layout change starts a new format epoch (and a
    // new analysis generation); reactivating with the same format keeps the analysis and marks a break instead.
    void configure(double sampleRate, const ChannelLayout &layout, uint32_t maxBlockFrames);
    // Mono or stereo.
    void configure(double sampleRate, uint32_t channels, uint32_t maxBlockFrames) {
        configure(sampleRate, ChannelLayout::standard(channels), maxBlockFrames);
    }
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
    // UI thread: the plugin window's own controls (ABR_COMMAND_*); carried out by the analysis thread.
    void requestCommand(uint32_t command);
    std::string saveState() const;
    // Restores the name and the identity. When another live instance of this plugin in this process already
    // uses the saved identity (a duplicated track, pasted settings, a second copy of a project), this instance
    // keeps an identity of its own and reports itself as a copy; `identityReassigned` is then set so the wrapper
    // can tell the host its state changed.
    bool restoreState(const std::string &state, bool *identityReassigned = nullptr);

    // Analysis thread only (BridgeAnalysisHub.cpp). Analyses at most `maxSeconds` of queued audio; returns the
    // frames analysed.
    uint32_t analyse(uint64_t nowNs, double maxSeconds);
    // Sender thread only (BridgeSender.cpp).
    void service(uint64_t nowNs);
    void disconnect();
    // Analysis thread, when the instance goes: frees the analyser.
    void releaseAnalysis();

private:
    struct Command {
        uint32_t id;            // 0: from the plugin window, not acknowledged over the socket
        uint32_t code;
        uint32_t generation;    // expected, 0: any
    };
    struct Ack {
        uint32_t id, code, outcome, generation, measurement;
    };
    struct SpatialAck {
        uint32_t revision, outcome, generation;
        uint64_t hash, frames;
    };

    uint32_t effectiveState() const noexcept;
    void growRing(uint32_t channels);
    void queue(uint16_t type, const void *payload, uint32_t length);
    void queueHello();
    void queueStatus(uint64_t nowNs);
    bool readControl();
    void handleCommand(const uint8_t *payload, uint32_t length);
    bool flush();
    void sendResult();
    void sendAcks();
    void runCommands();
    void runSpatial();
    void applySpatial(const uint8_t *bytes, uint32_t length);
    bool startGeneration(double sampleRate, uint32_t channels, uint64_t roles, uint32_t epoch);

    const uint32_t format_;
    uint8_t sessionId_[16];

    // Configuration, written by host threads under `configLock_`; the audio thread only reads the atomics.
    mutable std::mutex configLock_;
    uint8_t persistentId_[16];
    uint8_t restoredId_[16] = {};
    uint32_t identityFlags_ = 0;
    std::string sourceName_, trackName_, channelID_;
    double sampleRate_ = 0;
    ChannelLayout layout_;
    uint32_t maxBlockFrames_ = 0;
    bool everActive_ = false;
    // Epoch (high 32 bits) and channel count (low 32) in one word, so the audio thread never pairs an epoch with
    // another epoch's channel count.
    std::atomic<uint64_t> formatWord_{0};
    std::atomic<double> rtSampleRate_{0};
    std::atomic<uint64_t> rtRoles_{0};          // ChannelLayout::packedRoles of the configured layout
    std::atomic<bool> active_{false};
    std::atomic<bool> offline_{false};
    std::atomic<bool> bypassed_{false};
    std::atomic<uint32_t> breaks_{0};           // ABR_AUDIO_AFTER_* set by control threads for the next live block
    std::atomic<uint32_t> settingsSerial_{0};   // bumped on name changes so STATUS goes out at once
    std::atomic<bool> identityChanged_{false};  // a new identity must reach Auraliscope in a new HELLO
    std::atomic<bool> focusRequested_{false};   // "Show in Auraliscope", sent once connected

    // Audio thread state. The ring grows with the channel count (configure, while the host is not processing and
    // the analysis thread is held off it); the sender and UI threads read its fill level under `configLock_`.
    std::unique_ptr<RecordRing> ring_;
    uint64_t position_ = 0;
    uint32_t reasons_ = ABR_AUDIO_STREAM_START;  // pending for the next captured block
    uint32_t idleMs_ = 0;
    uint64_t lastCallTicks_ = 0;
    uint32_t lastFrames_ = 0;
    HostTransport lastTransport_{};
    double ticksToNs_ = 1;
    std::atomic<uint64_t> lastCallNs_{0};
    std::atomic<uint64_t> lastLiveNs_{0};
    std::atomic<uint64_t> framesProcessed_{0};
    std::atomic<uint64_t> framesDropped_{0};
    std::atomic<uint32_t> transportFlags_{0};
    std::atomic<uint32_t> interruptions_{0};
    std::atomic<uint32_t> transportJumps_{0};

    // Analysis thread state. The analyser is created and destroyed on the analysis thread only.
    AbrAnalyzer *analyzer_ = nullptr;
    uint32_t analyzerEpoch_ = 0;
    uint32_t analyzerChannels_ = 0;
    uint64_t analyzerRoles_ = 0;
    double analyzerRate_ = 0;
    bool freshGeneration_ = false;  // no audio analysed yet in this generation: nothing to break from
    bool forceResult_ = false;      // state changed without a tick (command, new generation): send it anyway
    uint32_t encodedSubscription_ = 0;
    uint32_t generationCounter_ = 0;
    uint64_t expectedPosition_ = 0;
    uint64_t publishedTicks_ = 0;
    std::unique_ptr<float[]> analysisScratch_;
    std::atomic<uint32_t> generation_{0};
    std::atomic<uint32_t> measurement_{ABR_MEASUREMENT_NONE};
    std::atomic<bool> pausedWanted_{false};
    std::atomic<bool> pausedByDisplay_{false};  // paused by a COMMAND over the connection (not the plugin window)
    std::atomic<uint32_t> lastBreakReasons_{0};
    std::atomic<uint64_t> framesAnalysed_{0};

    // Shared between threads, each under its own lock (never taken by the audio thread).
    mutable std::mutex summaryLock_;
    AbrAnalysisSummary summary_{};
    bool hasSummary_ = false;
    std::mutex commandLock_;
    std::vector<Command> commands_;              // reserved up front; bounded
    std::vector<Ack> acks_;
    // The newest RESULT, encoded by the analysis thread for the sender: replaced while unsent, so a slow receiver
    // gets the latest state, and the columns (and the observation frame) it has not had are carried again until one
    // is sent.
    std::mutex mailboxLock_;
    std::unique_ptr<uint8_t[]> mailbox_;
    uint32_t mailboxBytes_ = 0;
    uint32_t mailboxSubscription_ = 0;
    uint32_t mailboxGeneration_ = 0;
    uint64_t mailboxSpectrogram_ = 0, mailboxWaveform_ = 0, mailboxObservations_ = 0;
    // Columns delivered to the current subscription (serials of `sentGeneration_`), and the observation frame it holds
    // (0: none), under `mailboxLock_`.
    uint32_t sentSubscription_ = 0, sentGeneration_ = 0;
    uint64_t sentSpectrogram_ = 0, sentWaveform_ = 0, sentObservations_ = 0;
    // The display's spatial geometry (SPATIAL_CONFIG): kept by the sender thread as it arrives, applied by the analysis
    // thread at its next pass and to every later generation, its outcome acknowledged by the sender; a disconnection
    // asks for the standard layout again. Under `spatialLock_` (the applied copy: analysis thread only).
    std::mutex spatialLock_;
    uint8_t spatialPending_[ABR_SPATIAL_CONFIG_MAX];
    uint32_t spatialPendingBytes_ = 0;
    bool spatialPendingReset_ = false;
    SpatialAck spatialAcks_[4];
    uint32_t spatialAckCount_ = 0;
    uint8_t spatialApplied_[ABR_SPATIAL_CONFIG_MAX];
    uint32_t spatialAppliedBytes_ = 0;

    // Sender thread state (the atomics are also read by other threads).
    std::atomic<uint32_t> subscription_{0};     // 0: not sending results
    std::atomic<uint32_t> spectrogramMode_{0};  // the subscriber's waterfall analysis (ABR_SUBSCRIBE_SPECTROGRAM)
    std::atomic<uint32_t> spectrumChannels_{0}; // what its spectrum sums (ABR_SUBSCRIBE_SPECTRUM)
    std::atomic<uint32_t> spatialCoherence_{0}; // its spatial field's coherence threshold, ‰ (ABR_SUBSCRIBE_COHERENCE)
    std::atomic<bool> connected_{false};
    // The display keeps a RESULT's observations until one carries new ones (WELCOME, ABR_DISPLAY_KEEPS_OBSERVATIONS):
    // each frame is sent to it once. Otherwise (a display of build 98) every result carries them.
    std::atomic<bool> displayKeepsObservations_{false};
    std::atomic<bool> receiverTooOld_{false};
    std::atomic<bool> receiverTooNew_{false};
    std::atomic<uint64_t> resultsSent_{0};
    int fd_ = -1;
    bool welcomed_ = false;
    uint64_t lastAttemptNs_ = 0;
    uint64_t lastStatusNs_ = 0;
    uint32_t lastStatusState_ = 0xFFFFFFFF, lastStatusEpoch_ = 0, lastSettingsSerial_ = 0, lastStatusFlags_ = 0;
    uint32_t lastStatusGeneration_ = 0, lastStatusMeasurement_ = 0;
    uint32_t sendSequence_ = 0;
    std::unique_ptr<uint8_t[]> out_;
    size_t outUsed_ = 0, outSent_ = 0;
    uint8_t in_[1024];
    size_t inUsed_ = 0;
};

// The process-wide threads. Instances register on construction and unregister on destruction; the threads run
// while at least one instance exists, so unloading the plugin binary never leaves a thread behind.
void registerCore(BridgeCore *core);
void unregisterCore(BridgeCore *core);
void registerAnalysis(BridgeCore *core);
void unregisterAnalysis(BridgeCore *core);
// Runs `work` while the analysis thread is between passes (it waits for a pass in progress): no instance is being
// analysed meanwhile. Not from the analysis thread.
void withAnalysisHeld(const std::function<void()> &work);

// Identities claimed by live instances of this binary in this process (see BridgeCore::restoreState).
// `claimIdentity` returns false, and changes nothing, when another instance holds `id`.
bool claimIdentity(const BridgeCore *core, const uint8_t id[16]);
void releaseIdentity(const BridgeCore *core);

// For tests: whether the sender thread is running, and the analysis thread.
bool senderRunning();
bool analysisRunning();
// Nanoseconds the analysis thread has spent working since it started (for load measurements).
uint64_t analysisBusyNs();
// Tests only: stops (true) or restarts the analysis thread's work, as if it were starved of CPU.
void holdAnalysisForTesting(bool held);

}  // namespace abr
