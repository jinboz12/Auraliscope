#include "BridgeCore.h"

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "BridgePaths.h"
#include "BridgeWire.h"

#ifndef ABR_PLUGIN_VERSION
#define ABR_PLUGIN_VERSION "0.1.0-prototype"
#endif

namespace abr {

namespace {
constexpr size_t kRingBytes = size_t(1) << 20;     // 1 MB: 2.7 s of 48 kHz stereo, 0.68 s at 192 kHz (per 2 channels)
constexpr size_t kOutBytes = size_t(1) << 19;
// Stop queuing results while this much is unsent: with the socket buffers (32 KB each way) a stalled receiver finds
// at most about ten results waiting, and fresher state replaces the rest in the mailbox.
constexpr size_t kOutHighWater = size_t(1) << 14;
constexpr uint32_t kMailboxBytes = 256u * 1024u;   // one RESULT: ~7 KB of state, up to 24 spectrogram columns and
                                                   // 256 waveform columns, and in Immersive the spatial field and
                                                   // its observations (up to ~95 KB; the largest measured, 16
                                                   // channels of noise at the finest detail, 154 KB in all)
constexpr uint32_t kChunkFrames = 2048;            // largest record; longer host blocks are split
constexpr size_t kCommandQueue = 32;
constexpr uint64_t kReconnectNs = 1000000000ull;
constexpr uint64_t kIncompatibleRetryNs = 5000000000ull;  // a receiver of another protocol version
constexpr uint64_t kStatusNs = uint64_t(ABR_STATUS_INTERVAL_MS) * 1000000ull;
// The host not calling process for longer than a block plus this (or three blocks, if longer) is a gap in the
// live stream. REAPER's anticipative processing renders up to 200 ms ahead in bursts, so the margin sits above
// that; shorter stalls are left alone.
constexpr double kIdleNs = 350e6;
constexpr uint32_t kIdleCapMs = 3600u * 1000u;
constexpr uint32_t kInterruptions = ABR_AUDIO_AFTER_IDLE | ABR_AUDIO_AFTER_BYPASS | ABR_AUDIO_AFTER_OFFLINE
    | ABR_AUDIO_AFTER_RESTART;
constexpr size_t kNameBytes = 127;

// Keeps printable UTF-8, drops control characters and cuts at a character boundary.
std::string sanitize(const std::string &name, size_t limit = kNameBytes) {
    std::string clean;
    for (unsigned char c : name) if (c >= 0x20 && c != 0x7F) clean.push_back(char(c));
    if (clean.size() > limit) {
        size_t cut = limit;
        while (cut > 0 && (static_cast<unsigned char>(clean[cut]) & 0xC0) == 0x80) --cut;
        clean.resize(cut);
    }
    size_t first = clean.find_first_not_of(' '), last = clean.find_last_not_of(' ');
    return first == std::string::npos ? std::string() : clean.substr(first, last - first + 1);
}

std::string hex(const uint8_t *bytes, size_t count) {
    static const char digits[] = "0123456789ABCDEF";
    std::string text;
    for (size_t i = 0; i < count; ++i) {
        text.push_back(digits[bytes[i] >> 4]);
        text.push_back(digits[bytes[i] & 15]);
    }
    return text;
}

bool parseHex(const std::string &text, uint8_t *bytes, size_t count) {
    if (text.size() != count * 2) return false;
    for (size_t i = 0; i < count; ++i) {
        unsigned value;
        if (std::sscanf(text.c_str() + 2 * i, "%2x", &value) != 1) return false;
        bytes[i] = uint8_t(value);
    }
    return true;
}

uint64_t nowNs() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

std::string hostBundleID() {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFStringRef identifier = bundle ? CFBundleGetIdentifier(bundle) : nullptr;
    char text[96] = "";
    if (identifier) CFStringGetCString(identifier, text, sizeof text, kCFStringEncodingUTF8);
    return text;
}

// The capture ring for `channels`: 1 MB per two channels, rounded up to a power of two, so every layout queues at
// least as many seconds as stereo does (2.7 s at 48 kHz; a 7.1.4 bus gets 8 MB, 3.6 s).
size_t ringBytes(uint32_t channels) {
    size_t bytes = kRingBytes;
    while (bytes < kRingBytes / 2 * channels) bytes <<= 1;
    return bytes;
}

ChannelLayout unpack(uint32_t channels, uint64_t roles) {
    uint8_t list[ABR_MAX_CHANNELS] = {};
    for (uint32_t c = 0; c < channels && c < ABR_MAX_CHANNELS; ++c) list[c] = uint8_t((roles >> (4 * c)) & 15);
    return ChannelLayout::speakers(list, std::min(channels, uint32_t(ABR_MAX_CHANNELS)));
}
}  // namespace

ChannelLayout ChannelLayout::mono() {
    const uint8_t roles[] = {ABR_ROLE_L};
    return speakers(roles, 1, "Mono");
}

ChannelLayout ChannelLayout::stereo() {
    const uint8_t roles[] = {ABR_ROLE_L, ABR_ROLE_R};
    return speakers(roles, 2, "Stereo");
}

ChannelLayout ChannelLayout::standard(uint32_t channels) {
    if (channels == 1) return mono();
    if (channels == 2) return stereo();
    ChannelLayout layout;
    layout.channels = std::min(channels, uint32_t(ABR_MAX_CHANNELS));
    return layout;
}

ChannelLayout ChannelLayout::speakers(const uint8_t *roles, uint32_t channels, const char *name) {
    ChannelLayout layout;
    layout.channels = std::min(channels, uint32_t(ABR_MAX_CHANNELS));
    std::memcpy(layout.roles, roles, layout.channels);
    if (name && *name) {
        std::snprintf(layout.name, sizeof layout.name, "%s", name);
    } else if (layout.channels == 1 && roles[0] == ABR_ROLE_L) {
        std::snprintf(layout.name, sizeof layout.name, "Mono");
    } else if (layout.channels == 2 && roles[0] == ABR_ROLE_L && roles[1] == ABR_ROLE_R) {
        std::snprintf(layout.name, sizeof layout.name, "Stereo");
    } else {
        // ear-level · LFE · heights, as beds are named (7.1.4).
        uint32_t ear = 0, lfe = 0, top = 0;
        for (uint32_t c = 0; c < layout.channels; ++c) {
            const uint8_t role = layout.roles[c];
            if (role == ABR_ROLE_LFE) ++lfe;
            else if (role == ABR_ROLE_LTF || role == ABR_ROLE_RTF || role >= ABR_ROLE_LTM) ++top;
            else ++ear;
        }
        if (top) std::snprintf(layout.name, sizeof layout.name, "%u.%u.%u", ear, lfe, top);
        else std::snprintf(layout.name, sizeof layout.name, "%u.%u", ear, lfe);
    }
    return layout;
}

bool ChannelLayout::valid() const {
    if (channels < 1 || channels > ABR_MAX_CHANNELS) return false;
    if (channels == 1) return roles[0] == ABR_ROLE_L;
    uint32_t seen = 0;
    for (uint32_t c = 0; c < channels; ++c) {
        if (roles[c] >= ABR_ROLE_COUNT || (seen & (1u << roles[c]))) return false;
        seen |= 1u << roles[c];
    }
    return (seen & (1u << ABR_ROLE_L)) && (seen & (1u << ABR_ROLE_R));
}

uint32_t ChannelLayout::kind() const {
    if (!valid()) return ABR_LAYOUT_UNKNOWN;
    if (channels == 1) return ABR_LAYOUT_MONO;
    if (channels == 2 && roles[0] == ABR_ROLE_L && roles[1] == ABR_ROLE_R) return ABR_LAYOUT_STEREO;
    return ABR_LAYOUT_SPEAKERS;
}

uint64_t ChannelLayout::packedRoles() const {
    uint64_t packed = 0;
    for (uint32_t c = 0; c < channels && c < ABR_MAX_CHANNELS; ++c) packed |= uint64_t(roles[c] & 15) << (4 * c);
    return packed;
}

bool ChannelLayout::operator==(const ChannelLayout &other) const {
    return channels == other.channels && std::memcmp(roles, other.roles, channels) == 0
        && std::strncmp(name, other.name, sizeof name) == 0;
}

const char *roleName(uint32_t role, const ChannelLayout &layout) {
    static const char *const names[ABR_ROLE_COUNT] = {"L", "R", "C", "LFE", "Ls", "Rs", "Ltf", "Rtf", "Lrs", "Rrs",
                                                      "Lw", "Rw", "Ltm", "Rtm", "Ltr", "Rtr"};
    if (role >= ABR_ROLE_COUNT) return "?";
    bool rears = false;
    for (uint32_t c = 0; c < layout.channels; ++c) rears = rears || layout.roles[c] == ABR_ROLE_LRS;
    if (rears && role == ABR_ROLE_LS) return "Lss";
    if (rears && role == ABR_ROLE_RS) return "Rss";
    return names[role];
}

BridgeCore::BridgeCore(uint32_t pluginFormat)
    : format_(pluginFormat), ring_(new RecordRing(kRingBytes)),
      analysisScratch_(new float[size_t(kChunkFrames) * ABR_MAX_CHANNELS]),
      mailbox_(new uint8_t[kMailboxBytes]), out_(new uint8_t[kOutBytes]) {
    arc4random_buf(sessionId_, sizeof sessionId_);
    // A fresh random identity cannot collide; claiming it lets a later copy recognise it.
    do { arc4random_buf(persistentId_, sizeof persistentId_); } while (!claimIdentity(this, persistentId_));
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    ticksToNs_ = double(timebase.numer) / double(timebase.denom);
    commands_.reserve(kCommandQueue);
    acks_.reserve(kCommandQueue);
    registerAnalysis(this);
    registerCore(this);
}

BridgeCore::~BridgeCore() {
    unregisterCore(this);      // after this the sender thread never touches this instance again
    unregisterAnalysis(this);  // … nor the analysis thread
    disconnect();
    releaseAnalysis();
    releaseIdentity(this);
}

void BridgeCore::configure(double sampleRate, const ChannelLayout &layout, uint32_t maxBlockFrames) {
    growRing(layout.channels);
    std::lock_guard<std::mutex> lock(configLock_);
    uint32_t epoch = uint32_t(formatWord_.load(std::memory_order_relaxed) >> 32);
    // Only a different format needs a new epoch (the analysis is rebuilt for one); reactivating with the same
    // format keeps the analysis and marks the break instead (see setActive).
    if (epoch == 0 || sampleRate != sampleRate_ || layout != layout_) epoch = epoch == 0xFFFFFFFFu ? 1 : epoch + 1;
    sampleRate_ = sampleRate;
    layout_ = layout;
    maxBlockFrames_ = maxBlockFrames;
    rtSampleRate_.store(sampleRate, std::memory_order_relaxed);
    // The roles before the word that publishes the epoch: a block of the new epoch never carries the old roles.
    rtRoles_.store(layout.packedRoles(), std::memory_order_relaxed);
    formatWord_.store((uint64_t(epoch) << 32) | layout.channels, std::memory_order_release);
}

// More channels need a larger ring (ringBytes). It is replaced only here: the host does not process while it
// configures, and the analysis thread is held between passes, so neither touches either ring meanwhile; the
// sender and UI threads read the fill level under `configLock_`. Audio still queued belongs to the format being
// replaced, whose generation ends here anyway. Without memory for a larger ring the smaller one stays (the analysis
// then drops more under load, and says so).
void BridgeCore::growRing(uint32_t channels) {
    const size_t bytes = ringBytes(channels);
    if (bytes <= ring_->capacity()) return;
    std::unique_ptr<RecordRing> larger;
    try {
        larger = std::make_unique<RecordRing>(bytes);
    } catch (...) {
        return;
    }
    withAnalysisHeld([&] {
        std::lock_guard<std::mutex> lock(configLock_);
        ring_.swap(larger);
    });
}

void BridgeCore::setActive(bool active) {
    if (active) {
        std::lock_guard<std::mutex> lock(configLock_);
        if (everActive_) breaks_.fetch_or(ABR_AUDIO_AFTER_RESTART, std::memory_order_relaxed);
        everActive_ = true;
    }
    active_.store(active, std::memory_order_release);
}

void BridgeCore::setOffline(bool offline) {
    if (offline && !offline_.load(std::memory_order_relaxed))
        breaks_.fetch_or(ABR_AUDIO_AFTER_OFFLINE, std::memory_order_relaxed);
    offline_.store(offline, std::memory_order_release);
}

void BridgeCore::setBypassed(bool bypassed) noexcept {
    // Some hosts (AU) stop calling process while bypassed, so the break is recorded here, not observed there.
    if (bypassed && !bypassed_.load(std::memory_order_relaxed))
        breaks_.fetch_or(ABR_AUDIO_AFTER_BYPASS, std::memory_order_relaxed);
    bypassed_.store(bypassed, std::memory_order_relaxed);
}

uint32_t BridgeCore::effectiveState() const noexcept {
    if (!active_.load(std::memory_order_acquire) || (formatWord_.load(std::memory_order_acquire) >> 32) == 0)
        return ABR_STATE_INACTIVE;
    if (offline_.load(std::memory_order_acquire)) return ABR_STATE_OFFLINE;
    if (bypassed_.load(std::memory_order_relaxed)) return ABR_STATE_BYPASSED;
    return ABR_STATE_LIVE;
}

void BridgeCore::process(const float *const *input, uint32_t channels, uint32_t frames,
                         const HostTransport &transport) noexcept {
    // mach_absolute_time reads the commpage: no system call.
    const uint64_t ticks = mach_absolute_time();
    const uint64_t callNs = uint64_t(double(ticks) * ticksToNs_);
    lastCallNs_.store(callNs, std::memory_order_relaxed);
    transportFlags_.store(transport.flags & (ABR_TRANSPORT_KNOWN | ABR_TRANSPORT_PLAYING), std::memory_order_relaxed);

    // A timeline jump while playing (locate, loop) is metadata: what reaches the insert stays one signal.
    const uint32_t both = transport.flags & lastTransport_.flags;
    // One sample of slack: hosts that report a floating-point position round it either way.
    const int64_t drift = transport.position - (lastTransport_.position + int64_t(lastFrames_));
    const bool jumped = (both & ABR_TRANSPORT_PLAYING) && (both & ABR_TRANSPORT_POSITION) && (drift > 1 || drift < -1);
    if (jumped) transportJumps_.fetch_add(1, std::memory_order_relaxed);

    // The host did not call for longer than the last block lasted plus a margin: the audio of that time never
    // reached the insert, so the next live block does not continue the one before.
    uint32_t idleMs = 0;
    if (lastCallTicks_ != 0) {
        const double rate = rtSampleRate_.load(std::memory_order_relaxed);
        const double since = double(ticks - lastCallTicks_) * ticksToNs_;
        const double block = rate > 0 ? double(lastFrames_) * 1e9 / rate : 0;
        if (since > block + std::max(kIdleNs, 3 * block))
            idleMs = uint32_t(std::min<double>(kIdleCapMs, (since - block) / 1e6));
    }
    lastCallTicks_ = ticks;
    lastFrames_ = frames;
    lastTransport_ = transport;
    if (idleMs) breaks_.fetch_or(ABR_AUDIO_AFTER_IDLE, std::memory_order_relaxed);

    if (effectiveState() != ABR_STATE_LIVE) {
        // Bypassed, offline and inactive audio is not part of the live stream: the position stands still, nothing
        // is analysed, and `breaks_` says why the next live block does not follow the last one.
        if (idleMs) idleMs_ = std::min(kIdleCapMs, idleMs_ + idleMs);
        return;
    }
    const uint32_t breaks = breaks_.exchange(0, std::memory_order_relaxed);
    if (breaks & kInterruptions) interruptions_.fetch_add(1, std::memory_order_relaxed);
    reasons_ |= breaks;
    idleMs_ = std::min(kIdleCapMs, idleMs_ + idleMs);
    lastLiveNs_.store(callNs, std::memory_order_relaxed);

    const uint64_t word = formatWord_.load(std::memory_order_acquire);
    const uint32_t epoch = uint32_t(word >> 32);
    const uint64_t roles = rtRoles_.load(std::memory_order_relaxed);
    bool usable = input && channels >= 1 && channels <= ABR_MAX_CHANNELS && channels == uint32_t(word);
    for (uint32_t channel = 0; usable && channel < channels; ++channel) usable = input[channel] != nullptr;
    if (usable) {
        const double rate = rtSampleRate_.load(std::memory_order_relaxed);
        for (uint32_t offset = 0; offset < frames;) {
            const uint32_t count = std::min(kChunkFrames, frames - offset);
            uint32_t flags = transport.flags & (ABR_TRANSPORT_KNOWN | ABR_TRANSPORT_PLAYING);
            if (reasons_) flags |= ABR_AUDIO_DISCONTINUITY | reasons_;
            if (jumped && offset == 0) flags |= ABR_AUDIO_TRANSPORT_JUMP;
            const CaptureRecord header{epoch, count, channels, flags, (reasons_ & ABR_AUDIO_AFTER_IDLE) ? idleMs_ : 0u, 0,
                                       position_ + offset, rate, roles};
            if (ring_->write(header, input, offset)) {
                reasons_ = 0;
                idleMs_ = 0;
            } else {
                // The analysis thread is behind by more than the ring holds: this block is lost to the analysis
                // (the audio itself passes, untouched). The next record's position shows how much.
                framesDropped_.fetch_add(count, std::memory_order_relaxed);
                reasons_ |= ABR_AUDIO_AFTER_DROP;
            }
            offset += count;
        }
    } else {
        reasons_ |= ABR_AUDIO_AFTER_DROP;  // not analysable (unexpected channel layout): the analysis sees a gap
    }
    position_ += frames;
    framesProcessed_.store(position_, std::memory_order_relaxed);
}

std::string BridgeCore::sourceName() const {
    std::lock_guard<std::mutex> lock(configLock_);
    return sourceName_;
}

void BridgeCore::setSourceName(const std::string &name) {
    std::lock_guard<std::mutex> lock(configLock_);
    sourceName_ = sanitize(name);
    settingsSerial_.fetch_add(1, std::memory_order_relaxed);
}

void BridgeCore::setTrackName(const std::string &name) {
    std::lock_guard<std::mutex> lock(configLock_);
    const std::string clean = sanitize(name);
    if (clean == trackName_) return;
    trackName_ = clean;
    settingsSerial_.fetch_add(1, std::memory_order_relaxed);
}

void BridgeCore::setChannelID(const std::string &id) {
    std::lock_guard<std::mutex> lock(configLock_);
    const std::string clean = sanitize(id, 63);
    if (clean == channelID_) return;
    channelID_ = clean;
    settingsSerial_.fetch_add(1, std::memory_order_relaxed);
}

std::string BridgeCore::displayName() const {
    std::lock_guard<std::mutex> lock(configLock_);
    if (!sourceName_.empty()) return sourceName_;
    if (!trackName_.empty()) return trackName_;
    return "Auraliscope Bridge " + hex(persistentId_, 3);
}

CoreStatus BridgeCore::status() const {
    CoreStatus status;
    status.connected = connected_.load(std::memory_order_relaxed);
    status.focusPending = focusRequested_.load(std::memory_order_relaxed);
    status.subscribed = status.connected && subscription_.load(std::memory_order_relaxed) != 0;
    status.receiverTooOld = receiverTooOld_.load(std::memory_order_relaxed);
    status.receiverTooNew = receiverTooNew_.load(std::memory_order_relaxed);
    status.state = effectiveState();
    status.framesProcessed = framesProcessed_.load(std::memory_order_relaxed);
    status.framesDropped = framesDropped_.load(std::memory_order_relaxed);
    status.resultsSent = resultsSent_.load(std::memory_order_relaxed);
    status.interruptions = interruptions_.load(std::memory_order_relaxed);
    status.transportJumps = transportJumps_.load(std::memory_order_relaxed);
    status.transportFlags = transportFlags_.load(std::memory_order_relaxed);
    const uint64_t last = lastCallNs_.load(std::memory_order_relaxed);
    status.secondsSinceProcess = last ? double(nowNs() - std::min(last, nowNs())) / 1e9 : -1;
    status.measurement = measurement_.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(summaryLock_);
        status.hasAnalysis = hasSummary_;
        status.analysis = summary_;
    }
    std::lock_guard<std::mutex> lock(configLock_);
    status.sampleRate = sampleRate_;
    status.channels = layout_.channels;
    status.layout = layout_;
    status.maxBlockFrames = maxBlockFrames_;
    status.formatEpoch = uint32_t(formatWord_.load(std::memory_order_relaxed) >> 32);
    const double bytesPerSecond = std::max(1.0, sampleRate_) * std::max(1u, layout_.channels) * sizeof(float);
    status.backlogMs = uint32_t(double(ring_->usedBytes()) / bytesPerSecond * 1000);
    status.sourceName = sourceName_;
    status.trackName = trackName_;
    status.instanceTag = hex(persistentId_, 3);
    status.identityFlags = identityFlags_;
    if (identityFlags_ & ABR_IDENTITY_COPY) status.copiedFromTag = hex(restoredId_, 3);
    return status;
}

void BridgeCore::requestFocus() noexcept { focusRequested_.store(true, std::memory_order_release); }

void BridgeCore::requestCommand(uint32_t command) {
    std::lock_guard<std::mutex> lock(commandLock_);
    if (commands_.size() < kCommandQueue) commands_.push_back({0, command, 0});
}

// Plain text, so a project file stays readable and later versions can add keys:
//   AuraliscopeBridge 1 / id=<32 hex digits> / name=<UTF-8>
// Live measurements are not saved: a reopened project starts a new measurement (see ARCHITECTURE.md).
std::string BridgeCore::saveState() const {
    std::lock_guard<std::mutex> lock(configLock_);
    return "AuraliscopeBridge 1\nid=" + hex(persistentId_, 16) + "\nname=" + sourceName_ + "\n";
}

bool BridgeCore::restoreState(const std::string &state, bool *identityReassigned) {
    if (identityReassigned) *identityReassigned = false;
    if (state.rfind("AuraliscopeBridge ", 0) != 0) return false;
    uint8_t id[16];
    bool haveID = false;
    std::string name;
    size_t start = state.find('\n');
    while (start != std::string::npos && start + 1 < state.size()) {
        const size_t end = state.find('\n', start + 1);
        const std::string line = state.substr(start + 1, end == std::string::npos ? std::string::npos : end - start - 1);
        if (line.rfind("id=", 0) == 0) haveID = parseHex(line.substr(3), id, sizeof id);
        else if (line.rfind("name=", 0) == 0) name = line.substr(5);
        start = end;
    }
    std::lock_guard<std::mutex> lock(configLock_);
    if (haveID && std::memcmp(persistentId_, id, sizeof id) != 0) {
        if (claimIdentity(this, id)) {
            // The same insert as when the state was saved (project reopened, undo, a plugin reloaded in place).
            std::memcpy(persistentId_, id, sizeof id);
            std::memset(restoredId_, 0, sizeof restoredId_);
            identityFlags_ = ABR_IDENTITY_RESTORED;
        } else {
            // Another live instance is that insert: this one is a copy of it and keeps its own identity, which the
            // host saves with the project from now on.
            std::memcpy(restoredId_, id, sizeof id);
            identityFlags_ = ABR_IDENTITY_COPY;
            if (identityReassigned) *identityReassigned = true;
        }
        identityChanged_.store(true, std::memory_order_release);
    } else if (haveID && !(identityFlags_ & ABR_IDENTITY_RESTORED)) {
        identityFlags_ = ABR_IDENTITY_RESTORED;
        identityChanged_.store(true, std::memory_order_release);
    }
    sourceName_ = sanitize(name);
    settingsSerial_.fetch_add(1, std::memory_order_relaxed);
    return true;
}

// ---- Analysis thread -----------------------------------------------------------------------------------------

bool BridgeCore::startGeneration(double sampleRate, uint32_t channels, uint64_t roles, uint32_t epoch) {
    const ChannelLayout layout = unpack(channels, roles);
    AbrAnalyzer *next = layout.valid()
        ? abr_analyzer_create(sampleRate, layout.channels, layout.roles, generationCounter_ + 1, epoch) : nullptr;
    if (analyzer_) abr_analyzer_destroy(analyzer_);
    analyzer_ = next;
    analyzerEpoch_ = epoch;
    analyzerChannels_ = channels;
    analyzerRoles_ = roles;
    analyzerRate_ = sampleRate;
    publishedTicks_ = 0;
    freshGeneration_ = true;
    forceResult_ = true;
    if (!next) {
        generation_.store(0, std::memory_order_relaxed);
        measurement_.store(ABR_MEASUREMENT_NONE, std::memory_order_relaxed);
        std::lock_guard<std::mutex> lock(summaryLock_);
        hasSummary_ = false;
        return false;
    }
    ++generationCounter_;
    const bool paused = pausedWanted_.load(std::memory_order_relaxed);
    abr_analyzer_set_measuring(next, paused ? 0 : 1);
    abr_analyzer_set_spectrogram_mode(next, spectrogramMode_.load(std::memory_order_relaxed));
    abr_analyzer_set_spectrum_channels(next, spectrumChannels_.load(std::memory_order_relaxed));
    abr_analyzer_set_spatial_coherence(next, spatialCoherence_.load(std::memory_order_relaxed));
    generation_.store(generationCounter_, std::memory_order_relaxed);
    // The display's geometry carries over to the new generation (a reset, a new rate or bus): applied again, and
    // acknowledged again, since a bus of other roles may not take it.
    if (spatialAppliedBytes_ > 0) applySpatial(spatialApplied_, spatialAppliedBytes_);
    measurement_.store(paused ? ABR_MEASUREMENT_PAUSED : ABR_MEASUREMENT_MEASURING, std::memory_order_relaxed);
    framesAnalysed_.store(0, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(summaryLock_);
    hasSummary_ = false;
    return true;
}

void BridgeCore::runCommands() {
    Command pending[kCommandQueue];
    size_t count;
    {
        std::lock_guard<std::mutex> lock(commandLock_);
        count = commands_.size();
        std::copy(commands_.begin(), commands_.end(), pending);
        commands_.clear();
    }
    for (size_t i = 0; i < count; ++i) {
        const Command &c = pending[i];
        uint32_t outcome = ABR_ACK_DONE;
        const uint32_t current = generation_.load(std::memory_order_relaxed);
        if (c.generation != 0 && c.generation != current) {
            outcome = ABR_ACK_STALE_GENERATION;
        } else if (c.code == ABR_COMMAND_PAUSE || c.code == ABR_COMMAND_RESUME) {
            const bool pause = c.code == ABR_COMMAND_PAUSE;
            pausedWanted_.store(pause, std::memory_order_relaxed);
            // A pause from a display lasts while that display is connected (see disconnect); one from the plugin
            // window lasts until it is resumed.
            pausedByDisplay_.store(pause && c.id != 0, std::memory_order_relaxed);
            if (analyzer_) {
                abr_analyzer_set_measuring(analyzer_, pause ? 0 : 1);
                measurement_.store(pause ? ABR_MEASUREMENT_PAUSED : ABR_MEASUREMENT_MEASURING, std::memory_order_relaxed);
            } else {
                outcome = ABR_ACK_NO_ANALYSIS;  // nothing measured yet; the request applies once audio arrives
            }
        } else if (c.code == ABR_COMMAND_RESET) {
            if (!analyzer_) {
                outcome = ABR_ACK_NO_ANALYSIS;
            } else if (!startGeneration(analyzerRate_, analyzerChannels_, analyzerRoles_, analyzerEpoch_)) {
                // The same format afresh: audio already queued belongs to it and goes to the new generation.
                outcome = ABR_ACK_NO_ANALYSIS;
            }
        } else if (c.code == ABR_COMMAND_RESET_TRUE_PEAK) {
            if (analyzer_) abr_analyzer_reset_true_peaks(analyzer_);
            else outcome = ABR_ACK_NO_ANALYSIS;
        } else {
            outcome = ABR_ACK_UNSUPPORTED;
        }
        forceResult_ = true;
        if (c.id != 0) {
            std::lock_guard<std::mutex> lock(commandLock_);
            if (acks_.size() < kCommandQueue)
                acks_.push_back({c.id, c.code, outcome, generation_.load(std::memory_order_relaxed),
                                 measurement_.load(std::memory_order_relaxed)});
        }
    }
}

// The display's spatial geometry, on the analysis thread between passes: a new configuration is applied to the
// analysis (from its next spatial transform) and acknowledged; after a disconnection the standard layout returns.
// Without an analysis yet (no audio so far) it waits, and is applied when the first generation starts.
void BridgeCore::runSpatial() {
    uint8_t bytes[ABR_SPATIAL_CONFIG_MAX];
    uint32_t length = 0;
    bool reset = false;
    {
        std::lock_guard<std::mutex> lock(spatialLock_);
        reset = spatialPendingReset_;
        spatialPendingReset_ = false;
        if (spatialPendingBytes_ > 0 && (analyzer_ || reset)) {
            length = spatialPendingBytes_;
            std::memcpy(bytes, spatialPending_, length);
            spatialPendingBytes_ = 0;
        }
    }
    if (reset) {
        spatialAppliedBytes_ = 0;
        if (analyzer_) abr_analyzer_reset_spatial(analyzer_);
        forceResult_ = true;
    }
    if (length > 0) {
        if (analyzer_) applySpatial(bytes, length);
        else {
            std::lock_guard<std::mutex> lock(spatialLock_);
            if (spatialPendingBytes_ == 0) {  // still waiting for the first generation
                std::memcpy(spatialPending_, bytes, length);
                spatialPendingBytes_ = length;
            }
        }
    }
}

void BridgeCore::applySpatial(const uint8_t *bytes, uint32_t length) {
    uint32_t revision = 0;
    uint64_t hash = 0;
    const uint32_t outcome = abr_analyzer_configure_spatial(analyzer_, bytes, length, &revision, &hash);
    if (outcome == ABR_SPATIAL_APPLIED && bytes != spatialApplied_) {
        std::memcpy(spatialApplied_, bytes, length);
        spatialAppliedBytes_ = length;
    }
    forceResult_ = true;
    std::lock_guard<std::mutex> lock(spatialLock_);
    if (spatialAckCount_ < 4)
        spatialAcks_[spatialAckCount_++] = {revision, outcome, generation_.load(std::memory_order_relaxed), hash,
                                            framesAnalysed_.load(std::memory_order_relaxed)};
}

// Drains the ring into the analyser, oldest first, at most `maxSeconds` of audio per call so one instance with a
// backlog cannot hold up the others (the hub visits every instance each pass). A record of a new format epoch
// starts a new generation; a break (a flagged record, or a position gap where the ring was full) is handed to the
// analysis between the right frames. Then the newest state goes to the mailbox for the sender.
uint32_t BridgeCore::analyse(uint64_t nowNs, double maxSeconds) {
    runCommands();
    runSpatial();
    if (analyzer_) {
        abr_analyzer_set_spectrogram_mode(analyzer_, spectrogramMode_.load(std::memory_order_relaxed));
        abr_analyzer_set_spectrum_channels(analyzer_, spectrumChannels_.load(std::memory_order_relaxed));
        abr_analyzer_set_spatial_coherence(analyzer_, spatialCoherence_.load(std::memory_order_relaxed));
    }
    const double now = double(nowNs) / 1e9;
    uint32_t analysed = 0;
    CaptureRecord header;
    RecordRing &ring = *ring_;
    while (ring.peek(header)) {
        if (analysed > 0 && double(analysed) >= header.sampleRate * maxSeconds) break;  // the rest waits a pass
        if (!analyzer_ || header.formatEpoch != analyzerEpoch_ || header.channels != analyzerChannels_
            || header.roles != analyzerRoles_) {
            if (!startGeneration(header.sampleRate, header.channels, header.roles, header.formatEpoch)) {
                ring.pop(nullptr);  // not analysable (no layout it can measure): the audio still passed untouched
                continue;
            }
        }
        ring.pop(analysisScratch_.get());
        const uint64_t lost = header.position > expectedPosition_ ? header.position - expectedPosition_ : 0;
        if (!freshGeneration_ && ((header.flags & ABR_AUDIO_DISCONTINUITY) || lost > 0)) {
            const uint32_t reasons = (header.flags & ABR_AUDIO_REASONS) | (lost ? uint32_t(ABR_AUDIO_AFTER_DROP) : 0u);
            abr_analyzer_interrupt(analyzer_, lost, header.idleMs, reasons);
            lastBreakReasons_.store(reasons, std::memory_order_relaxed);
        }
        freshGeneration_ = false;
        abr_analyzer_consume(analyzer_, analysisScratch_.get(), header.frames, header.position, now);
        expectedPosition_ = header.position + header.frames;
        analysed += header.frames;
    }
    if (!analyzer_) return analysed;
    if (analysed == 0) abr_analyzer_idle(analyzer_, now);

    const uint64_t ticks = abr_analyzer_ticks(analyzer_);
    const uint32_t subscription = subscription_.load(std::memory_order_acquire);
    const bool fresh = ticks != publishedTicks_ || forceResult_;
    if (fresh) {
        AbrAnalysisSummary summary;
        abr_analyzer_summary(analyzer_, &summary);
        framesAnalysed_.store(summary.frames_analysed, std::memory_order_relaxed);
        std::lock_guard<std::mutex> lock(summaryLock_);
        summary_ = summary;
        hasSummary_ = summary.ticks > 0;
    }
    if (subscription != 0 && (fresh || subscription != encodedSubscription_)) {
        std::lock_guard<std::mutex> lock(mailboxLock_);
        const uint32_t generation = generation_.load(std::memory_order_relaxed);
        // Columns already delivered to this subscriber, in this generation, are not sent again; nor is the observation
        // frame it holds, if it keeps them. Only a result actually sent counts (sendResult): one replaced here unsent
        // leaves the next to carry what it carried.
        const bool continuing = sentSubscription_ == subscription && sentGeneration_ == generation;
        const bool keeps = continuing && displayKeepsObservations_.load(std::memory_order_relaxed);
        uint64_t spectrogram = 0, waveform = 0, observations = 0;
        const uint32_t bytes = abr_analyzer_encode(analyzer_, mailbox_.get(), kMailboxBytes, subscription,
                                                   unpack(analyzerChannels_, analyzerRoles_).kind(), continuing ? sentSpectrogram_ : 0,
                                                   continuing ? sentWaveform_ : 0, keeps ? sentObservations_ : 0,
                                                   &spectrogram, &waveform, &observations);
        if (bytes) {
            mailboxBytes_ = bytes;
            mailboxSubscription_ = subscription;
            mailboxGeneration_ = generation;
            mailboxSpectrogram_ = spectrogram;
            mailboxWaveform_ = waveform;
            mailboxObservations_ = observations;
        }
    }
    encodedSubscription_ = subscription;
    publishedTicks_ = ticks;
    forceResult_ = false;
    return analysed;
}

void BridgeCore::releaseAnalysis() {
    if (analyzer_) abr_analyzer_destroy(analyzer_);
    analyzer_ = nullptr;
}

// ---- Sender thread -------------------------------------------------------------------------------------------

void BridgeCore::queue(uint16_t type, const void *payload, uint32_t length) {
    if (outUsed_ + sizeof(AbrHeader) + length > kOutBytes) return;  // results stop at the high-water mark first
    AbrHeader header{ABR_MAGIC, type, 0, length, sendSequence_++};
    std::memcpy(out_.get() + outUsed_, &header, sizeof header);
    if (length) std::memcpy(out_.get() + outUsed_ + sizeof header, payload, length);
    outUsed_ += sizeof header + length;
}

void BridgeCore::queueHello() {
    uint8_t payload[512];
    abr_put32(payload, ABR_PROTOCOL_VERSION);
    abr_put32(payload + 4, format_);
    AbrWriter w = abr_writer(payload + 8, sizeof payload - 8);
    abr_put_bytes(&w, ABR_HELLO_SESSION_ID, sessionId_, 16);
    {
        std::lock_guard<std::mutex> lock(configLock_);
        abr_put_bytes(&w, ABR_HELLO_PERSISTENT_ID, persistentId_, 16);
        abr_put_bytes(&w, ABR_HELLO_RESTORED_ID, restoredId_, 16);
        abr_put_u32(&w, ABR_HELLO_IDENTITY_FLAGS, identityFlags_);
    }
    abr_put_i64(&w, ABR_HELLO_HOST_PID, getpid());
    abr_put_text(&w, ABR_HELLO_HOST_NAME, getprogname(), 63);
    static const std::string bundle = hostBundleID();
    abr_put_text(&w, ABR_HELLO_HOST_BUNDLE_ID, bundle.c_str(), 95);
    abr_put_text(&w, ABR_HELLO_PLUGIN_VERSION, ABR_PLUGIN_VERSION, 31);
    abr_put_u32(&w, ABR_HELLO_SCHEMA, ABR_ANALYSIS_SCHEMA);
    abr_put_u32(&w, ABR_HELLO_CAPABILITIES, ABR_CAPABILITY_RESULTS | ABR_CAPABILITY_RESET | ABR_CAPABILITY_RESET_TRUE_PEAK
                | ABR_CAPABILITY_PAUSE | ABR_CAPABILITY_SPATIAL_CONFIG);
    if (!w.overflowed) queue(ABR_MSG_HELLO, payload, uint32_t(8 + w.used));
}

void BridgeCore::queueStatus(uint64_t nowNs) {
    const uint32_t state = effectiveState();
    const uint32_t serial = settingsSerial_.load(std::memory_order_relaxed);
    const uint32_t flags = transportFlags_.load(std::memory_order_relaxed)
        | (subscription_.load(std::memory_order_relaxed) ? uint32_t(ABR_STATUS_SUBSCRIBED) : 0u);
    const uint32_t generation = generation_.load(std::memory_order_relaxed);
    const uint32_t measurement = measurement_.load(std::memory_order_relaxed);
    const uint32_t epoch = uint32_t(formatWord_.load(std::memory_order_relaxed) >> 32);
    const bool changed = state != lastStatusState_ || epoch != lastStatusEpoch_ || serial != lastSettingsSerial_
        || flags != lastStatusFlags_ || generation != lastStatusGeneration_ || measurement != lastStatusMeasurement_;
    if (!changed && nowNs - lastStatusNs_ < kStatusNs) return;
    lastStatusState_ = state;
    lastStatusEpoch_ = epoch;
    lastSettingsSerial_ = serial;
    lastStatusFlags_ = flags;
    lastStatusGeneration_ = generation;
    lastStatusMeasurement_ = measurement;
    lastStatusNs_ = nowNs;

    uint8_t payload[1024];
    AbrWriter w = abr_writer(payload, sizeof payload);
    abr_put_u32(&w, ABR_STATUS_STATE, state);
    abr_put_u32(&w, ABR_STATUS_FLAGS, flags);
    abr_put_u64(&w, ABR_STATUS_FRAMES_PROCESSED, framesProcessed_.load(std::memory_order_relaxed));
    abr_put_u64(&w, ABR_STATUS_FRAMES_DROPPED, framesDropped_.load(std::memory_order_relaxed));
    abr_put_u32(&w, ABR_STATUS_INTERRUPTIONS, interruptions_.load(std::memory_order_relaxed));
    abr_put_u32(&w, ABR_STATUS_TRANSPORT_JUMPS, transportJumps_.load(std::memory_order_relaxed));
    abr_put_u32(&w, ABR_STATUS_GENERATION, generation);
    abr_put_u32(&w, ABR_STATUS_MEASUREMENT, measurement);
    abr_put_u64(&w, ABR_STATUS_FRAMES_ANALYSED, framesAnalysed_.load(std::memory_order_relaxed));
    abr_put_u32(&w, ABR_STATUS_LAST_BREAK, lastBreakReasons_.load(std::memory_order_relaxed));
    const uint64_t live = lastLiveNs_.load(std::memory_order_relaxed);
    abr_put_f64(&w, ABR_STATUS_SECONDS_SINCE_AUDIO, live ? double(nowNs - std::min(live, nowNs)) / 1e9 : -1.0);
    {
        std::lock_guard<std::mutex> lock(configLock_);
        abr_put_u32(&w, ABR_STATUS_FORMAT_EPOCH, epoch);
        abr_put_f64(&w, ABR_STATUS_SAMPLE_RATE, sampleRate_);
        abr_put_u32(&w, ABR_STATUS_CHANNELS, layout_.channels);
        abr_put_u32(&w, ABR_STATUS_LAYOUT, layout_.kind());
        if (layout_.valid()) abr_put_field(&w, ABR_STATUS_ROLES, ABR_KIND_U8, layout_.channels, layout_.roles);
        abr_put_text(&w, ABR_STATUS_LAYOUT_NAME, layout_.name, 15);
        abr_put_u32(&w, ABR_STATUS_MAX_BLOCK, maxBlockFrames_);
        const double bytesPerSecond = std::max(1.0, sampleRate_) * std::max(1u, layout_.channels) * sizeof(float);
        abr_put_u32(&w, ABR_STATUS_BACKLOG_MS, uint32_t(double(ring_->usedBytes()) / bytesPerSecond * 1000));
        abr_put_text(&w, ABR_STATUS_SOURCE_NAME, (sourceName_.empty() ? trackName_ : sourceName_).c_str(), kNameBytes);
        abr_put_text(&w, ABR_STATUS_TRACK_NAME, trackName_.c_str(), kNameBytes);
        abr_put_text(&w, ABR_STATUS_CHANNEL_ID, channelID_.c_str(), 63);
    }
    if (!w.overflowed) queue(ABR_MSG_STATUS, payload, uint32_t(w.used));
}

void BridgeCore::handleCommand(const uint8_t *payload, uint32_t length) {
    Command command{0, 0, 0};
    uint8_t session[16] = {};
    bool haveSession = false;
    AbrReader r = abr_reader(payload, length);
    AbrField f;
    while (abr_next_field(&r, &f)) {
        if (f.tag == ABR_COMMAND_ID) abr_field_u32(&f, &command.id);
        else if (f.tag == ABR_COMMAND_CODE) abr_field_u32(&f, &command.code);
        else if (f.tag == ABR_COMMAND_GENERATION) abr_field_u32(&f, &command.generation);
        else if (f.tag == ABR_COMMAND_SESSION_ID) haveSession = abr_field_bytes(&f, session, 16);
    }
    std::lock_guard<std::mutex> lock(commandLock_);
    if (!haveSession || std::memcmp(session, sessionId_, 16) != 0) {
        // Meant for another instance (an obsolete selection): refused here, never carried out.
        if (command.id != 0 && acks_.size() < kCommandQueue)
            acks_.push_back({command.id, command.code, ABR_ACK_WRONG_SESSION, generation_.load(std::memory_order_relaxed),
                             measurement_.load(std::memory_order_relaxed)});
        return;
    }
    if (command.id == 0) command.id = 0xFFFFFFFFu;  // a command from the socket is always acknowledged
    if (commands_.size() < kCommandQueue) commands_.push_back(command);
}

bool BridgeCore::readControl() {
    for (;;) {
        const ssize_t count = recv(fd_, in_ + inUsed_, sizeof in_ - inUsed_, MSG_DONTWAIT);
        if (count == 0) return false;
        if (count < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
        inUsed_ += size_t(count);
        size_t offset = 0;
        while (inUsed_ - offset >= sizeof(AbrHeader)) {
            AbrHeader header;
            std::memcpy(&header, in_ + offset, sizeof header);
            if (header.magic != ABR_MAGIC || header.length > sizeof in_ - sizeof header) return false;
            if (inUsed_ - offset < sizeof header + header.length) break;
            const uint8_t *payload = in_ + offset + sizeof header;
            if (header.type == ABR_MSG_WELCOME && header.length >= ABR_HELLO_MIN_BYTES) {
                const uint32_t version = abr_get32(payload);
                receiverTooOld_.store(version < ABR_PROTOCOL_VERSION, std::memory_order_relaxed);
                receiverTooNew_.store(version > ABR_PROTOCOL_VERSION, std::memory_order_relaxed);
                if (version != ABR_PROTOCOL_VERSION) return false;
                AbrReader r = abr_reader(payload + ABR_HELLO_MIN_BYTES, header.length - ABR_HELLO_MIN_BYTES);
                AbrField f;
                uint32_t capabilities = 0;
                while (abr_next_field(&r, &f)) if (f.tag == ABR_WELCOME_CAPABILITIES) abr_field_u32(&f, &capabilities);
                displayKeepsObservations_.store((capabilities & ABR_DISPLAY_KEEPS_OBSERVATIONS) != 0, std::memory_order_relaxed);
                welcomed_ = true;
                connected_.store(true, std::memory_order_relaxed);
            } else if (!welcomed_) {
                return false;  // nothing but WELCOME may come first
            } else if (header.type == ABR_MSG_SUBSCRIBE) {
                AbrReader r = abr_reader(payload, header.length);
                AbrField f;
                uint32_t subscription = 0, spectrogram = 0, spectrum = 0, coherence = 0;
                while (abr_next_field(&r, &f)) {
                    if (f.tag == ABR_SUBSCRIBE_SUBSCRIPTION) abr_field_u32(&f, &subscription);
                    if (f.tag == ABR_SUBSCRIBE_SPECTROGRAM) abr_field_u32(&f, &spectrogram);
                    if (f.tag == ABR_SUBSCRIBE_SPECTRUM) abr_field_u32(&f, &spectrum);
                    if (f.tag == ABR_SUBSCRIBE_COHERENCE) abr_field_u32(&f, &coherence);
                }
                // Repeating the current number only changes the options: the columns carry on where they were.
                if (subscription != 0) {
                    spectrogramMode_.store(spectrogram, std::memory_order_relaxed);
                    spectrumChannels_.store(spectrum == 1 ? 1u : 0u, std::memory_order_relaxed);
                    spatialCoherence_.store(coherence, std::memory_order_relaxed);
                    subscription_.store(subscription, std::memory_order_release);
                }
            } else if (header.type == ABR_MSG_UNSUBSCRIBE) {
                subscription_.store(0, std::memory_order_release);
                // Nobody is watching: the cheaper analyses.
                spectrogramMode_.store(0, std::memory_order_relaxed);
                spectrumChannels_.store(0, std::memory_order_relaxed);
                spatialCoherence_.store(0, std::memory_order_relaxed);
            } else if (header.type == ABR_MSG_COMMAND) {
                handleCommand(payload, header.length);
            } else if (header.type == ABR_MSG_SPATIAL_CONFIG && header.length > 0 && header.length <= ABR_SPATIAL_CONFIG_MAX) {
                // Kept for the analysis thread, which applies it between passes (never on the host's audio thread).
                std::lock_guard<std::mutex> lock(spatialLock_);
                std::memcpy(spatialPending_, payload, header.length);
                spatialPendingBytes_ = header.length;
            }
            offset += sizeof header + header.length;
        }
        std::memmove(in_, in_ + offset, inUsed_ - offset);
        inUsed_ -= offset;
    }
}

bool BridgeCore::flush() {
    while (outSent_ < outUsed_) {
        const ssize_t sent = send(fd_, out_.get() + outSent_, outUsed_ - outSent_, MSG_DONTWAIT);
        if (sent < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
        outSent_ += size_t(sent);
    }
    outUsed_ = outSent_ = 0;
    return true;
}

// Moves the newest encoded result to the socket, if the receiver is keeping up. When it is not, the mailbox is
// replaced by fresher state on the analysis thread, and the columns it has not had wait in the analyser (bounded:
// the oldest are dropped, and counted, when a display falls more than about 2 s behind).
void BridgeCore::sendResult() {
    if (outUsed_ - outSent_ > kOutHighWater) return;
    if (outUsed_ + sizeof(AbrHeader) + kMailboxBytes > kOutBytes) {
        if (outSent_ == 0) return;
        std::memmove(out_.get(), out_.get() + outSent_, outUsed_ - outSent_);
        outUsed_ -= outSent_;
        outSent_ = 0;
    }
    const uint32_t subscription = subscription_.load(std::memory_order_acquire);
    std::lock_guard<std::mutex> lock(mailboxLock_);
    if (mailboxBytes_ == 0) return;
    if (mailboxSubscription_ != subscription) {
        mailboxBytes_ = 0;  // encoded for a subscription that has ended
        return;
    }
    queue(ABR_MSG_RESULT, mailbox_.get(), mailboxBytes_);
    sentSubscription_ = mailboxSubscription_;
    sentGeneration_ = mailboxGeneration_;
    sentSpectrogram_ = mailboxSpectrogram_;
    sentWaveform_ = mailboxWaveform_;
    sentObservations_ = mailboxObservations_;
    mailboxBytes_ = 0;
    resultsSent_.fetch_add(1, std::memory_order_relaxed);
}

void BridgeCore::sendAcks() {
    Ack pending[kCommandQueue];
    size_t count;
    {
        std::lock_guard<std::mutex> lock(commandLock_);
        count = acks_.size();
        std::copy(acks_.begin(), acks_.end(), pending);
        acks_.clear();
    }
    SpatialAck spatial[4];
    uint32_t spatialCount;
    {
        std::lock_guard<std::mutex> lock(spatialLock_);
        spatialCount = spatialAckCount_;
        std::copy(spatialAcks_, spatialAcks_ + spatialCount, spatial);
        spatialAckCount_ = 0;
    }
    for (uint32_t i = 0; i < spatialCount; ++i) {
        uint8_t payload[128];
        AbrWriter w = abr_writer(payload, sizeof payload);
        abr_put_u32(&w, ABR_SPATIAL_ACK_REVISION, spatial[i].revision);
        abr_put_u64(&w, ABR_SPATIAL_ACK_HASH, spatial[i].hash);
        abr_put_u32(&w, ABR_SPATIAL_ACK_OUTCOME, spatial[i].outcome);
        abr_put_u32(&w, ABR_SPATIAL_ACK_GENERATION, spatial[i].generation);
        abr_put_u64(&w, ABR_SPATIAL_ACK_FRAMES, spatial[i].frames);
        abr_put_bytes(&w, ABR_SPATIAL_ACK_SESSION_ID, sessionId_, 16);
        if (!w.overflowed) queue(ABR_MSG_SPATIAL_ACK, payload, uint32_t(w.used));
    }
    for (size_t i = 0; i < count; ++i) {
        uint8_t payload[128];
        AbrWriter w = abr_writer(payload, sizeof payload);
        abr_put_u32(&w, ABR_ACK_COMMAND_ID, pending[i].id);
        abr_put_u32(&w, ABR_ACK_COMMAND_CODE, pending[i].code);
        abr_put_u32(&w, ABR_ACK_OUTCOME, pending[i].outcome);
        abr_put_u32(&w, ABR_ACK_GENERATION, pending[i].generation);
        abr_put_u32(&w, ABR_ACK_MEASUREMENT, pending[i].measurement);
        abr_put_bytes(&w, ABR_ACK_SESSION_ID, sessionId_, 16);
        if (!w.overflowed) queue(ABR_MSG_ACK, payload, uint32_t(w.used));
    }
}

void BridgeCore::disconnect() {
    // The display that paused the measurement is gone (quit, crashed, or the connection broke): the pause goes
    // with it, so a measurement is never left paused by nobody.
    if (fd_ >= 0 && pausedByDisplay_.exchange(false, std::memory_order_relaxed)) requestCommand(ABR_COMMAND_RESUME);
    if (fd_ >= 0) close(fd_);
    fd_ = -1;
    welcomed_ = false;
    {
        // The geometry was that display's: the next one (perhaps an older app) starts from the standard layout.
        std::lock_guard<std::mutex> lock(spatialLock_);
        spatialPendingBytes_ = 0;
        spatialPendingReset_ = true;
        spatialAckCount_ = 0;
    }
    {
        // What was encoded for that connection, and what it was sent, end with it: the next display starts afresh (the
        // oldest columns held, the observation frame) even if it numbers its subscription the same (a relaunched app).
        std::lock_guard<std::mutex> lock(mailboxLock_);
        mailboxBytes_ = 0;
        sentSubscription_ = 0;
    }
    subscription_.store(0, std::memory_order_release);
    connected_.store(false, std::memory_order_relaxed);
    displayKeepsObservations_.store(false, std::memory_order_relaxed);
    outUsed_ = outSent_ = inUsed_ = 0;
    lastStatusState_ = 0xFFFFFFFF;
}

void BridgeCore::service(uint64_t nowNs) {
    if (identityChanged_.exchange(false, std::memory_order_acq_rel) && fd_ >= 0) {
        disconnect();
        lastAttemptNs_ = 0;  // reconnect now, announcing the new identity
    }
    if (fd_ < 0) {
        // A pending "Show in Auraliscope" retries every 200 ms: the user may just have launched the app. A
        // receiver of another protocol version is retried slowly: it will not change until it is updated.
        const bool incompatible = receiverTooOld_.load(std::memory_order_relaxed) || receiverTooNew_.load(std::memory_order_relaxed);
        const uint64_t retry = incompatible ? kIncompatibleRetryNs
            : focusRequested_.load(std::memory_order_relaxed) ? kReconnectNs / 5 : kReconnectNs;
        if (nowNs - lastAttemptNs_ < retry && lastAttemptNs_ != 0) return;
        lastAttemptNs_ = nowNs;
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        if (abr_socket_path(address.sun_path, sizeof address.sun_path) != 0) return;
        const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return;
        // A small kernel buffer keeps the latest-state policy in charge: a large one would quietly queue old
        // results ahead of a stalled receiver.
        int on = 1, buffer = 32 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);  // a vanished receiver must not signal the DAW
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, sizeof buffer);
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        uid_t uid;
        gid_t gid;
        if (connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof address) != 0
            || getpeereid(fd, &uid, &gid) != 0 || uid != getuid()) {
            close(fd);
            return;
        }
        fd_ = fd;
        queueHello();
    }
    if (!readControl()) { disconnect(); return; }
    queueStatus(nowNs);
    if (welcomed_ && focusRequested_.exchange(false, std::memory_order_acq_rel)) queue(ABR_MSG_FOCUS, nullptr, 0);
    if (welcomed_) {
        sendAcks();
        sendResult();
    }
    if (!flush()) disconnect();
}

}  // namespace abr
