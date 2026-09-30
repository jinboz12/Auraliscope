#include "BridgeCore.h"

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "BridgePaths.h"

#ifndef ABR_PLUGIN_VERSION
#define ABR_PLUGIN_VERSION "0.1.0-prototype"
#endif

namespace abr {

namespace {
constexpr size_t kRingBytes = size_t(1) << 19;     // 512 KB: 1.3 s of 48 kHz stereo, 0.34 s at 192 kHz
constexpr size_t kOutBytes = size_t(1) << 19;
constexpr size_t kOutHighWater = size_t(1) << 16;  // stop taking from the ring while this much is unsent
constexpr uint32_t kChunkFrames = 2048;            // largest record; longer host blocks are split
constexpr double kLatencyCap = 0.15;               // queued audio older than this is dropped, oldest first
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

void copyName(char *destination, const std::string &source, size_t size) {
    std::snprintf(destination, size, "%s", source.c_str());
}

uint64_t nowNs() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

std::string hostBundleID() {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFStringRef identifier = bundle ? CFBundleGetIdentifier(bundle) : nullptr;
    char text[96] = "";
    if (identifier) CFStringGetCString(identifier, text, sizeof text, kCFStringEncodingUTF8);
    return text;
}
}  // namespace

BridgeCore::BridgeCore(uint32_t pluginFormat)
    : format_(pluginFormat), ring_(kRingBytes), out_(new uint8_t[kOutBytes]),
      scratch_(new float[size_t(kChunkFrames) * ABR_MAX_CHANNELS]) {
    arc4random_buf(sessionId_, sizeof sessionId_);
    // A fresh random identity cannot collide; claiming it lets a later copy recognise it.
    do { arc4random_buf(persistentId_, sizeof persistentId_); } while (!claimIdentity(this, persistentId_));
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    ticksToNs_ = double(timebase.numer) / double(timebase.denom);
    registerCore(this);
}

BridgeCore::~BridgeCore() {
    unregisterCore(this);  // after this the sender thread never touches this instance again
    disconnect();
    releaseIdentity(this);
}

void BridgeCore::configure(double sampleRate, uint32_t channels, uint32_t maxBlockFrames) {
    std::lock_guard<std::mutex> lock(configLock_);
    uint32_t epoch = uint32_t(formatWord_.load(std::memory_order_relaxed) >> 32);
    // Only a different format needs a new epoch (Auraliscope rebuilds its analysis for one); reactivating with the
    // same format keeps the analysis and marks the break instead (see setActive).
    if (epoch == 0 || sampleRate != sampleRate_ || channels != channels_) epoch = epoch == 0xFFFFFFFFu ? 1 : epoch + 1;
    sampleRate_ = sampleRate;
    channels_ = channels;
    maxBlockFrames_ = maxBlockFrames;
    rtSampleRate_.store(sampleRate, std::memory_order_relaxed);
    formatWord_.store((uint64_t(epoch) << 32) | channels, std::memory_order_release);
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
    lastCallNs_.store(uint64_t(double(ticks) * ticksToNs_), std::memory_order_relaxed);
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
        // Bypassed, offline and inactive audio is not part of the live stream: the position stands still, and
        // `breaks_` says why the next live block does not follow the last one.
        if (idleMs) idleMs_ = std::min(kIdleCapMs, idleMs_ + idleMs);
        return;
    }
    const uint32_t breaks = breaks_.exchange(0, std::memory_order_relaxed);
    if (breaks & kInterruptions) interruptions_.fetch_add(1, std::memory_order_relaxed);
    const uint32_t token = subscription_.load(std::memory_order_acquire);
    if (token != lastToken_) {
        // A new subscription starts clean: what happened before it belongs to no stream the receiver sees.
        lastToken_ = token;
        reasons_ = ABR_AUDIO_STREAM_START;
        idleMs_ = 0;
    } else {
        reasons_ |= breaks;
        idleMs_ = std::min(kIdleCapMs, idleMs_ + idleMs);
    }

    const uint64_t word = formatWord_.load(std::memory_order_acquire);
    const uint32_t epoch = uint32_t(word >> 32);
    bool usable = input && channels >= 1 && channels <= ABR_MAX_CHANNELS && channels == uint32_t(word);
    for (uint32_t channel = 0; usable && channel < channels; ++channel) usable = input[channel] != nullptr;
    if (token != 0 && usable) {
        for (uint32_t offset = 0; offset < frames;) {
            const uint32_t count = std::min(kChunkFrames, frames - offset);
            uint32_t flags = transport.flags & (ABR_TRANSPORT_KNOWN | ABR_TRANSPORT_PLAYING | ABR_TRANSPORT_POSITION);
            if (reasons_) flags |= ABR_AUDIO_DISCONTINUITY | reasons_;
            if (jumped && offset == 0) flags |= ABR_AUDIO_TRANSPORT_JUMP;
            const AbrAudio header{token, epoch, position_ + offset, count, channels, flags,
                                  (reasons_ & ABR_AUDIO_AFTER_IDLE) ? idleMs_ : 0u,
                                  (flags & ABR_TRANSPORT_POSITION) ? transport.position + offset : 0};
            if (ring_.write(header, input, offset)) {
                reasons_ = 0;
                idleMs_ = 0;
            } else {
                framesDropped_.fetch_add(count, std::memory_order_relaxed);
                reasons_ |= ABR_AUDIO_AFTER_DROP;
            }
            offset += count;
        }
    } else if (token != 0) {
        reasons_ |= ABR_AUDIO_AFTER_DROP;  // subscribed, but this block could not be sent: the receiver sees the gap
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
    status.framesSent = framesSent_.load(std::memory_order_relaxed);
    status.framesDropped = framesDropped_.load(std::memory_order_relaxed);
    status.interruptions = interruptions_.load(std::memory_order_relaxed);
    status.transportJumps = transportJumps_.load(std::memory_order_relaxed);
    status.transportFlags = transportFlags_.load(std::memory_order_relaxed);
    const uint64_t last = lastCallNs_.load(std::memory_order_relaxed);
    status.secondsSinceProcess = last ? double(nowNs() - std::min(last, nowNs())) / 1e9 : -1;
    std::lock_guard<std::mutex> lock(configLock_);
    status.sampleRate = sampleRate_;
    status.channels = channels_;
    status.maxBlockFrames = maxBlockFrames_;
    status.formatEpoch = uint32_t(formatWord_.load(std::memory_order_relaxed) >> 32);
    status.sourceName = sourceName_;
    status.trackName = trackName_;
    status.instanceTag = hex(persistentId_, 3);
    status.identityFlags = identityFlags_;
    if (identityFlags_ & ABR_IDENTITY_COPY) status.copiedFromTag = hex(restoredId_, 3);
    return status;
}

void BridgeCore::requestFocus() noexcept { focusRequested_.store(true, std::memory_order_release); }

// Plain text, so a project file stays readable and later versions can add keys:
//   AuraliscopeBridge 1 / id=<32 hex digits> / name=<UTF-8>
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

// ---- Sender thread -------------------------------------------------------------------------------------------

void BridgeCore::queue(uint16_t type, const void *payload, uint32_t length) {
    if (outUsed_ + sizeof(AbrHeader) + length > kOutBytes) {
        // Only audio can fill the buffer (see drainRing), so a control message never finds it full in practice.
        return;
    }
    AbrHeader header{ABR_MAGIC, type, 0, length, sendSequence_++};
    std::memcpy(out_.get() + outUsed_, &header, sizeof header);
    if (length) std::memcpy(out_.get() + outUsed_ + sizeof header, payload, length);
    outUsed_ += sizeof header + length;
}

void BridgeCore::queueStatus(uint64_t nowNs) {
    AbrStatus status{};
    status.state = effectiveState();
    const uint32_t serial = settingsSerial_.load(std::memory_order_relaxed);
    status.flags = transportFlags_.load(std::memory_order_relaxed)
        | (subscription_.load(std::memory_order_relaxed) ? uint32_t(ABR_STATUS_SUBSCRIBED) : 0u);
    status.frames_processed = framesProcessed_.load(std::memory_order_relaxed);
    status.frames_dropped = framesDropped_.load(std::memory_order_relaxed);
    status.interruptions = interruptions_.load(std::memory_order_relaxed);
    status.transport_jumps = transportJumps_.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(configLock_);
        status.format_epoch = uint32_t(formatWord_.load(std::memory_order_relaxed) >> 32);
        status.sample_rate = sampleRate_;
        status.channels = channels_;
        status.layout = channels_ == 1 ? ABR_LAYOUT_MONO : channels_ == 2 ? ABR_LAYOUT_STEREO : ABR_LAYOUT_UNKNOWN;
        status.max_block_frames = maxBlockFrames_;
        copyName(status.source_name, sourceName_.empty() ? trackName_ : sourceName_, sizeof status.source_name);
        copyName(status.track_name, trackName_, sizeof status.track_name);
        copyName(status.channel_id, channelID_, sizeof status.channel_id);
    }
    const bool changed = status.state != lastStatusState_ || status.format_epoch != lastStatusEpoch_
        || serial != lastSettingsSerial_ || status.flags != lastStatusFlags_;
    if (!changed && nowNs - lastStatusNs_ < kStatusNs) return;
    lastStatusState_ = status.state;
    lastStatusEpoch_ = status.format_epoch;
    lastSettingsSerial_ = serial;
    lastStatusFlags_ = status.flags;
    lastStatusNs_ = nowNs;
    queue(ABR_MSG_STATUS, &status, sizeof status);
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
            if (header.type == ABR_MSG_WELCOME && header.length >= sizeof(AbrWelcome)) {
                AbrWelcome welcome;
                std::memcpy(&welcome, payload, sizeof welcome);
                receiverTooOld_.store(welcome.protocol_version < ABR_PROTOCOL_VERSION, std::memory_order_relaxed);
                receiverTooNew_.store(welcome.protocol_version > ABR_PROTOCOL_VERSION, std::memory_order_relaxed);
                if (welcome.protocol_version != ABR_PROTOCOL_VERSION) return false;
                welcomed_ = true;
                connected_.store(true, std::memory_order_relaxed);
            } else if (!welcomed_) {
                return false;  // nothing but WELCOME may come first
            } else if (header.type == ABR_MSG_SUBSCRIBE && header.length >= sizeof(AbrSubscribe)) {
                AbrSubscribe subscribe;
                std::memcpy(&subscribe, payload, sizeof subscribe);
                if (subscribe.subscription != 0) {
                    senderReasons_ = 0;  // a new stream: nothing of it lost yet
                    senderIdleMs_ = 0;
                    subscription_.store(subscribe.subscription, std::memory_order_release);
                }
            } else if (header.type == ABR_MSG_UNSUBSCRIBE) {
                subscription_.store(0, std::memory_order_release);
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

// Moves queued records to the socket. Drop policy when Auraliscope cannot keep up: queued audio older than
// kLatencyCap is discarded oldest first, so what does arrive is recent; if the sender thread itself stalls long
// enough for the ring to fill, the audio thread drops the newest blocks instead of waiting. Either way the next
// transmitted block carries ABR_AUDIO_AFTER_DROP and its position shows exactly how much was lost.
// Records of another subscription or format epoch are discarded unsent: they belong to no stream the receiver
// is waiting for.
void BridgeCore::drainRing() {
    double rate;
    uint32_t channels, epoch;
    {
        std::lock_guard<std::mutex> lock(configLock_);
        rate = sampleRate_;
        channels = channels_;
        epoch = uint32_t(formatWord_.load(std::memory_order_relaxed) >> 32);
    }
    const uint32_t token = subscription_.load(std::memory_order_acquire);
    const size_t latencyBytes = size_t(std::max(1.0, rate) * std::max(1u, channels) * sizeof(float) * kLatencyCap);
    const bool sending = fd_ >= 0 && welcomed_ && token != 0;
    AbrAudio header;
    while (ring_.peek(header)) {
        const bool stale = !sending || header.subscription != token || header.format_epoch != epoch
            || header.channels != channels;
        const bool late = ring_.usedBytes() > latencyBytes + RecordRing::recordBytes(header.frames, header.channels);
        if (stale || late) {
            ring_.pop(nullptr);
            if (late && !stale) {
                framesDropped_.fetch_add(header.frames, std::memory_order_relaxed);
                // The break this record announced (idle, bypass…) still happened: the next record sent says so.
                senderReasons_ |= ABR_AUDIO_AFTER_DROP | (header.flags & ABR_AUDIO_REASONS);
                if (header.flags & ABR_AUDIO_AFTER_IDLE) senderIdleMs_ = std::min(kIdleCapMs, senderIdleMs_ + header.idle_ms);
            }
            continue;
        }
        const size_t bytes = size_t(header.frames) * header.channels * sizeof(float);
        if (outUsed_ - outSent_ > kOutHighWater || outUsed_ + 2 * sizeof(AbrHeader) + sizeof(AbrFormat) + sizeof header + bytes > kOutBytes) {
            if (outSent_ == 0) break;  // the socket is backed up: leave the rest queued (and capped) for later
            std::memmove(out_.get(), out_.get() + outSent_, outUsed_ - outSent_);
            outUsed_ -= outSent_;
            outSent_ = 0;
            continue;
        }
        if (sentFormatEpoch_ != header.format_epoch) {
            AbrFormat format{header.format_epoch, channels, rate,
                             channels == 1 ? uint32_t(ABR_LAYOUT_MONO) : uint32_t(ABR_LAYOUT_STEREO),
                             ABR_SAMPLE_FLOAT32_INTERLEAVED};
            queue(ABR_MSG_FORMAT, &format, sizeof format);
            sentFormatEpoch_ = header.format_epoch;
        }
        ring_.pop(scratch_.get());
        if (senderReasons_) header.flags |= ABR_AUDIO_DISCONTINUITY | senderReasons_;
        if (senderReasons_ & ABR_AUDIO_AFTER_IDLE) header.idle_ms = std::min(kIdleCapMs, header.idle_ms + senderIdleMs_);
        senderReasons_ = 0;
        senderIdleMs_ = 0;
        AbrHeader message{ABR_MAGIC, ABR_MSG_AUDIO, 0, uint32_t(sizeof header + bytes), sendSequence_++};
        std::memcpy(out_.get() + outUsed_, &message, sizeof message);
        std::memcpy(out_.get() + outUsed_ + sizeof message, &header, sizeof header);
        std::memcpy(out_.get() + outUsed_ + sizeof message + sizeof header, scratch_.get(), bytes);
        outUsed_ += sizeof message + sizeof header + bytes;
        framesSent_.fetch_add(header.frames, std::memory_order_relaxed);
    }
}

void BridgeCore::disconnect() {
    if (fd_ >= 0) close(fd_);
    fd_ = -1;
    welcomed_ = false;
    subscription_.store(0, std::memory_order_release);
    connected_.store(false, std::memory_order_relaxed);
    outUsed_ = outSent_ = inUsed_ = 0;
    sentFormatEpoch_ = 0;
    lastStatusState_ = 0xFFFFFFFF;
}

void BridgeCore::service(uint64_t nowNs) {
    if (identityChanged_.exchange(false, std::memory_order_acq_rel) && fd_ >= 0) {
        disconnect();
        lastAttemptNs_ = 0;  // reconnect now, announcing the new identity
    }
    if (fd_ < 0) {
        drainRing();  // discards whatever was queued before the connection went away
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
        // A small kernel buffer keeps the drop policy in charge: a large one would quietly queue seconds of audio
        // ahead of a stalled receiver. 128 KB is 0.34 s of 48 kHz stereo, 85 ms at 192 kHz.
        int on = 1, buffer = 128 * 1024;
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
        AbrHello hello{};
        hello.protocol_version = ABR_PROTOCOL_VERSION;
        hello.plugin_format = format_;
        std::memcpy(hello.session_id, sessionId_, 16);
        {
            std::lock_guard<std::mutex> lock(configLock_);
            std::memcpy(hello.persistent_id, persistentId_, 16);
            std::memcpy(hello.restored_id, restoredId_, 16);
            hello.identity_flags = identityFlags_;
        }
        hello.host_pid = getpid();
        std::snprintf(hello.host_name, sizeof hello.host_name, "%s", getprogname());
        static const std::string bundle = hostBundleID();
        std::snprintf(hello.host_bundle_id, sizeof hello.host_bundle_id, "%s", bundle.c_str());
        std::snprintf(hello.plugin_version, sizeof hello.plugin_version, "%s", ABR_PLUGIN_VERSION);
        queue(ABR_MSG_HELLO, &hello, sizeof hello);
    }
    if (!readControl()) { disconnect(); return; }
    queueStatus(nowNs);
    if (welcomed_ && focusRequested_.exchange(false, std::memory_order_acq_rel)) queue(ABR_MSG_FOCUS, nullptr, 0);
    drainRing();
    if (!flush()) disconnect();
}

}  // namespace abr
