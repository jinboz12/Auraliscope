// Transport tests: the plugin core (BridgeCore + sender thread) against the application's receiver
// (BridgeServer), in one process over a private socket. No plugin format and no DAW is involved; the harness
// in Bridge/Tools covers the real VST3 and AU binaries.
//
// Build and run: Bridge/scripts/test-transport.sh

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

#include "BridgeCore.h"
extern "C" {
#include "BridgeDiscovery.h"
#include "BridgeServer.h"
}

using namespace std::chrono;

static int failures = 0;
#if defined(__has_feature)
#if __has_feature(thread_sanitizer) || __has_feature(address_sanitizer)
#define ABR_SLOW_BUILD 1
#endif
#endif
#ifdef ABR_SLOW_BUILD
static const int64_t kWorstProcessNs = INT64_MAX;  // instrumentation dominates; timing is measured without it
#else
static const int64_t kWorstProcessNs = 200000;
#endif
#define CHECK(condition, ...)                                                    \
    do {                                                                         \
        if (condition) { std::printf("  ok   "); std::printf(__VA_ARGS__); }      \
        else { std::printf("  FAIL "); std::printf(__VA_ARGS__); ++failures; }   \
        std::printf("\n");                                                       \
    } while (0)

// The deterministic test signal, a function of the stream position alone: L and R differ in frequency and level,
// so a swapped, duplicated or scaled channel cannot pass.
static float signal(uint32_t channel, uint64_t n, double rate) {
    const double frequency = channel == 0 ? 997.0 : 1499.0, amplitude = channel == 0 ? 0.5 : 0.25;
    return float(amplitude * std::sin(2 * M_PI * frequency * double(n) / rate));
}

struct Collector {
    struct Boundary { size_t frame; uint32_t reasons; uint64_t lost; uint32_t idleMs; };
    std::mutex lock;
    std::vector<float> samples;
    std::vector<Boundary> boundaries;
    uint32_t channels = 0;
    std::atomic<int> sleepOnceMs{0};
    static void boundary(void *context, uint32_t reasons, uint64_t lost, uint32_t idleMs) {
        auto *self = static_cast<Collector *>(context);
        std::lock_guard<std::mutex> guard(self->lock);
        self->boundaries.push_back({self->channels ? self->samples.size() / self->channels : 0, reasons, lost, idleMs});
    }
    std::vector<Boundary> marks() {
        std::lock_guard<std::mutex> guard(lock);
        return boundaries;
    }
    static void sink(void *context, const float *interleaved, uint32_t frames, uint32_t channels) {
        auto *self = static_cast<Collector *>(context);
        {
            std::lock_guard<std::mutex> guard(self->lock);
            self->channels = channels;
            self->samples.insert(self->samples.end(), interleaved, interleaved + size_t(frames) * channels);
        }
        if (int ms = self->sleepOnceMs.load()) {
            std::this_thread::sleep_for(milliseconds(ms));
            self->sleepOnceMs.store(0);
        }
    }
    size_t frames() {
        std::lock_guard<std::mutex> guard(lock);
        return channels ? samples.size() / channels : 0;
    }
};

static bool waitFor(const std::function<bool()> &condition, double seconds) {
    const auto end = steady_clock::now() + duration<double>(seconds);
    while (steady_clock::now() < end) {
        if (condition()) return true;
        std::this_thread::sleep_for(milliseconds(5));
    }
    return condition();
}

static std::vector<AbrSourceInfo> sources(AbrServer *server) {
    std::vector<AbrSourceInfo> list(64);
    list.resize(std::min<uint32_t>(64, abr_server_sources(server, list.data(), 64)));
    return list;
}

static bool findSource(AbrServer *server, const std::string &name, AbrSourceInfo &out) {
    for (const auto &info : sources(server)) if (name == info.source_name) { out = info; return true; }
    return false;
}

// Gives the calling thread the time-constraint policy Core Audio gives a device's IO thread, so timing reflects
// the code rather than ordinary-priority preemption.
static void makeRealTime(double periodSeconds) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    const double ticksPerSecond = 1e9 * timebase.denom / timebase.numer;
    thread_time_constraint_policy_data_t policy;
    policy.period = uint32_t(periodSeconds * ticksPerSecond);
    policy.computation = uint32_t(0.0005 * ticksPerSecond);
    policy.constraint = uint32_t(std::max(0.001, periodSeconds * 0.9) * ticksPerSecond);
    policy.preemptible = 1;
    thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&policy,
                      THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

// Waits until the receiver has stopped receiving (earlier audio still in flight has arrived).
static void quiesce(AbrServer *server) {
    uint64_t last = UINT64_MAX;
    for (int i = 0; i < 100; ++i) {
        uint64_t total = 0;
        for (const auto &info : sources(server)) total += info.frames_received;
        if (total == last) return;
        last = total;
        std::this_thread::sleep_for(milliseconds(100));
    }
}

// Waits until the receiver reports the instance's current format epoch, as the app does before attaching.
static AbrSourceInfo settled(AbrServer *server, const char *name, abr::BridgeCore &core) {
    AbrSourceInfo info{};
    waitFor([&] { return findSource(server, name, info) && info.format_epoch == core.status().formatEpoch; }, 3);
    return info;
}

// Plays `core` like a host's audio thread: blocks of `block` frames at `speed` × real time.
struct FakeHost {
    abr::BridgeCore &core;
    uint32_t channels;
    double rate;
    uint32_t block;
    std::atomic<bool> running{true};
    std::atomic<uint64_t> position{0};
    std::atomic<int64_t> worstNs{0};
    std::atomic<int> idleMs{0};           // the host stops calling process for this long, once
    std::atomic<int64_t> jumpTo{-1};      // the host's timeline jumps here (the signal does not)
    bool counting = false;                // L carries the stream position itself (n / 2^24), R its negative
    int64_t timeline = 0;
    std::thread thread;
    FakeHost(abr::BridgeCore &core, uint32_t channels, double rate, uint32_t block, double speed, bool counting = false)
        : core(core), channels(channels), rate(rate), block(block), counting(counting) {
        thread = std::thread([this, speed] {
            makeRealTime(this->block / this->rate / speed);
            std::vector<std::vector<float>> buffers(this->channels, std::vector<float>(this->block));
            const float *planar[ABR_MAX_CHANNELS];
            auto next = steady_clock::now();
            const auto period = duration<double>(this->block / this->rate / speed);
            while (running.load()) {
                const uint64_t start = position.load();
                for (uint32_t c = 0; c < this->channels; ++c) {
                    for (uint32_t i = 0; i < this->block; ++i)
                        buffers[c][i] = this->counting ? (c ? -1.0f : 1.0f) * float((start + i) & 0xFFFFFF) / 16777216.0f
                                                 : signal(c, start + i, this->rate);
                    planar[c] = buffers[c].data();
                }
                if (int ms = idleMs.exchange(0)) {
                    std::this_thread::sleep_for(milliseconds(ms));
                    next = steady_clock::now();
                }
                if (int64_t to = jumpTo.exchange(-1); to >= 0) timeline = to;
                const abr::HostTransport transport{ABR_TRANSPORT_KNOWN | ABR_TRANSPORT_PLAYING | ABR_TRANSPORT_POSITION, timeline};
                timeline += this->block;
                const auto before = steady_clock::now();
                this->core.process(planar, this->channels, this->block, transport);
                const int64_t took = duration_cast<nanoseconds>(steady_clock::now() - before).count();
                if (took > worstNs.load()) worstNs.store(took);
                position.store(start + this->block);
                next += duration_cast<steady_clock::duration>(period);
                std::this_thread::sleep_until(next);
            }
        });
    }
    ~FakeHost() { stop(); }
    void stop() {
        running.store(false);
        if (thread.joinable()) thread.join();
    }
};

// Checks every collected frame against the signal, starting at stream position `first`.
static bool bitExact(Collector &collector, uint64_t first, double rate, uint32_t channels, size_t &mismatches) {
    std::lock_guard<std::mutex> guard(collector.lock);
    mismatches = 0;
    const size_t frames = collector.samples.size() / channels;
    for (size_t i = 0; i < frames; ++i)
        for (uint32_t c = 0; c < channels; ++c)
            if (collector.samples[i * channels + c] != signal(c, first + i, rate)) ++mismatches;
    return frames > 0 && mismatches == 0;
}

// The first delivered position is not reported to the sink, so recover it: find the offset whose signal matches.
static uint64_t locate(Collector &collector, double rate, uint64_t limit) {
    std::lock_guard<std::mutex> guard(collector.lock);
    const uint32_t channels = collector.channels;
    if (collector.samples.size() < size_t(8) * channels) return UINT64_MAX;
    for (uint64_t start = 0; start < limit; ++start) {
        bool match = true;
        for (size_t i = 0; i < 8 && match; ++i)
            for (uint32_t c = 0; c < channels && match; ++c)
                match = collector.samples[i * channels + c] == signal(c, start + i, rate);
        if (match) return start;
    }
    return UINT64_MAX;
}

int main() {
    // The fake peers below write to sockets the plugin may already have closed; the plugin and the receiver set
    // SO_NOSIGPIPE on their own.
    signal(SIGPIPE, SIG_IGN);
    char folder[] = "/tmp/abr-test-XXXXXX", path[256];
    if (!mkdtemp(folder)) return 1;
    std::snprintf(path, sizeof path, "%s/bridge.sock", folder);
    setenv("AURALISCOPE_BRIDGE_SOCKET", path, 1);
    char error[256] = "";
    AbrServer *server = abr_server_start(nullptr, error, sizeof error);
    if (!server) { std::printf("server failed: %s\n", error); return 1; }

    std::printf("Concurrent creation and destruction\n");
    {
        // Hosts create and destroy instances on several threads at once (project loading, undo, previews). The
        // sender thread must start and stop cleanly however those interleave: a watchdog fails the run instead of
        // hanging it if they ever deadlock.
        std::atomic<bool> done{false};
        std::thread watchdog([&] {
            for (int i = 0; i < 600 && !done.load(); ++i) std::this_thread::sleep_for(milliseconds(100));
            if (!done.load()) {
                std::printf("  FAIL concurrent creation and destruction deadlocked (60 s)\n");
                std::fflush(stdout);
                _exit(1);
            }
        });
        std::atomic<int> created{0};
        std::vector<std::thread> threads;
        const auto started = steady_clock::now();
        for (int t = 0; t < 8; ++t) {
            threads.emplace_back([&, t] {
                float silence[256] = {};
                const float *planar[2] = {silence, silence};
                for (int i = 0; i < 200; ++i) {
                    auto core = std::make_unique<abr::BridgeCore>(ABR_FORMAT_TEST);
                    ++created;
                    if ((i + t) % 3 == 0) {
                        core->configure(48000, 2, 128);
                        core->setActive(true);
                        core->process(planar, 2, 128, abr::HostTransport{});
                    }
                    if ((i + t) % 7 == 0) std::this_thread::sleep_for(microseconds(150 + 90 * t));
                }
            });
        }
        for (auto &thread : threads) thread.join();
        done = true;
        watchdog.join();
        CHECK(true, "%d instances created and destroyed on 8 threads in %.1f s, no deadlock", created.load(),
              duration<double>(steady_clock::now() - started).count());
        CHECK(!abr::senderRunning(), "the sender thread stops when the last instance goes");
        CHECK(waitFor([&] { return sources(server).empty(); }, 3), "every one of them left the receiver's list");
    }

    std::printf("Discovery and metadata\n");
    auto stereo = std::make_unique<abr::BridgeCore>(ABR_FORMAT_TEST);
    stereo->setSourceName("Stereo bus");
    stereo->configure(48000, 2, 512);
    stereo->setActive(true);
    auto mono = std::make_unique<abr::BridgeCore>(ABR_FORMAT_TEST);
    mono->setTrackName("Vocal");
    mono->configure(44100, 1, 256);
    mono->setActive(true);
    AbrSourceInfo a{}, b{};
    CHECK(waitFor([&] { return findSource(server, "Stereo bus", a) && findSource(server, "Vocal", b); }, 3),
          "both instances discovered by name (named source, and track-name fallback)");
    CHECK(a.sample_rate == 48000 && a.channels == 2 && a.layout == ABR_LAYOUT_STEREO && a.state == ABR_STATE_LIVE,
          "stereo metadata: %.0f Hz, %u ch, layout %u, state %u", a.sample_rate, a.channels, a.layout, a.state);
    CHECK(b.sample_rate == 44100 && b.channels == 1 && b.layout == ABR_LAYOUT_MONO, "mono metadata: %.0f Hz, %u ch",
          b.sample_rate, b.channels);
    CHECK(std::memcmp(a.session_id, b.session_id, 16) != 0 && std::memcmp(a.persistent_id, b.persistent_id, 16) != 0,
          "instances have distinct session and persistent IDs");
    CHECK(a.protocol_version == ABR_PROTOCOL_VERSION && a.host_pid == getpid(), "protocol version and host pid");

    std::printf("One-click focus\n");
    {
        const uint32_t before = a.focus_requests;
        stereo->requestFocus();
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.focus_requests == before + 1; }, 2)
                  && !stereo->status().focusPending,
              "\"Show in Auraliscope\" reaches the receiver once (%u request)", a.focus_requests);
    }

    std::printf("Stereo stream, bit-exact\n");
    Collector collector;
    {
        FakeHost host(*stereo, 2, 48000, 128, 1.0);
        FakeHost other(*mono, 1, 44100, 64, 1.0);
        std::this_thread::sleep_for(milliseconds(200));
        CHECK(stereo->status().framesSent == 0, "nothing is sent before Auraliscope subscribes");
        abr_server_select(server, a.session_id);
        abr_server_attach(server, a.format_epoch, Collector::sink, Collector::boundary, &collector, 0);
        waitFor([&] { return collector.frames() >= 96000; }, 5);
        host.stop();
        other.stop();
        abr_server_detach(server);
        const uint64_t first = locate(collector, 48000, host.position.load());
        size_t mismatches = 0;
        CHECK(first != UINT64_MAX && bitExact(collector, first, 48000, 2, mismatches),
              "%zu frames match the signal exactly, L/R order preserved (first position %llu, %zu mismatches)",
              collector.frames(), (unsigned long long)first, mismatches);
        findSource(server, "Stereo bus", a);
        CHECK(a.frames_lost == 0 && a.frames_discarded == 0, "no loss at real time (lost %llu, discarded %llu)",
              (unsigned long long)a.frames_lost, (unsigned long long)a.frames_discarded);
        findSource(server, "Vocal", b);
        CHECK(b.frames_received == 0, "the unselected instance sent no audio (%llu frames)", (unsigned long long)b.frames_received);
        CHECK(host.worstNs.load() < kWorstProcessNs, "worst process() call %.1f µs", host.worstNs.load() / 1000.0);
    }

    std::printf("Mono stream, bit-exact\n");
    {
        Collector monoCollector;
        findSource(server, "Vocal", b);
        abr_server_select(server, b.session_id);
        abr_server_attach(server, b.format_epoch, Collector::sink, Collector::boundary, &monoCollector, 0);
        FakeHost host(*mono, 1, 44100, 64, 1.0);
        waitFor([&] { return monoCollector.frames() >= 44100; }, 5);
        host.stop();
        abr_server_detach(server);
        const uint64_t first = locate(monoCollector, 44100, host.position.load());
        size_t mismatches = 0;
        CHECK(first != UINT64_MAX && bitExact(monoCollector, first, 44100, 1, mismatches) && monoCollector.channels == 1,
              "%zu mono frames exact (%zu mismatches)", monoCollector.frames(), mismatches);
    }

    std::printf("Slow receiver\n");
    {
        // Auraliscope stalls for one second (a hiccup on its receiving thread), then recovers.
        Collector slow;
        a = settled(server, "Stereo bus", *stereo);
        const uint64_t lostBefore = a.frames_lost, gapsBefore = a.discontinuities;
        const uint64_t droppedBefore = stereo->status().framesDropped;
        abr_server_select(server, a.session_id);
        abr_server_attach(server, a.format_epoch, Collector::sink, Collector::boundary, &slow, 0);
        FakeHost host(*stereo, 2, 48000, 32, 1.0);
        waitFor([&] { return slow.frames() > 4800; }, 3);
        slow.sleepOnceMs = 1000;
        waitFor([&] { return slow.sleepOnceMs.load() == 0; }, 3);
        const size_t afterStall = slow.frames();
        std::this_thread::sleep_for(milliseconds(1000));
        const size_t recovered = slow.frames() - afterStall;
        host.stop();
        quiesce(server);
        abr_server_detach(server);
        findSource(server, "Stereo bus", a);
        const uint64_t dropped = stereo->status().framesDropped - droppedBefore, lost = a.frames_lost - lostBefore;
        CHECK(host.worstNs.load() < kWorstProcessNs, "audio thread never waits: worst process() %.1f µs across a 1 s receiver stall",
              host.worstNs.load() / 1000.0);
        CHECK(dropped > 0 && lost > 0 && a.discontinuities > gapsBefore,
              "the stall costs audio, and the receiver sees exactly where: plugin dropped %llu, receiver counted %llu lost in %llu gap(s)",
              (unsigned long long)dropped, (unsigned long long)lost, (unsigned long long)(a.discontinuities - gapsBefore));
        CHECK(lost <= dropped + 48000 / 10, "receiver's loss matches the plugin's drops (within the socket backlog)");
        CHECK(recovered > 40000, "delivery recovers to real time after the stall (%zu frames in the next second)", recovered);
    }

    std::printf("Format change\n");
    {
        quiesce(server);
        a = settled(server, "Stereo bus", *stereo);
        const uint32_t oldEpoch = a.format_epoch;
        stereo->setActive(false);
        stereo->configure(96000, 1, 1024);
        stereo->setActive(true);
        Collector collector96;
        abr_server_select(server, a.session_id);
        abr_server_attach(server, oldEpoch, Collector::sink, Collector::boundary, &collector96, 0);
        FakeHost host(*stereo, 1, 96000, 256, 1.0);
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.format_epoch != oldEpoch && a.frames_discarded > 0; }, 3),
              "new epoch %u reported (96 kHz, %u ch); its audio is held back while attached to epoch %u",
              a.format_epoch, a.channels, oldEpoch);
        CHECK(collector96.frames() == 0, "no audio of the new format reached the old configuration");
        abr_server_attach(server, a.format_epoch, Collector::sink, Collector::boundary, &collector96, 0);  // what the app does after reconfiguring
        waitFor([&] { return collector96.frames() >= 48000; }, 3);
        host.stop();
        abr_server_detach(server);
        size_t mismatches = 0;
        const uint64_t first = locate(collector96, 96000, host.position.load());
        CHECK(a.sample_rate == 96000 && a.channels == 1 && first != UINT64_MAX
                  && bitExact(collector96, first, 96000, 1, mismatches),
              "after re-attaching, the 96 kHz mono stream is exact");
        stereo->setActive(false);
        stereo->configure(48000, 2, 512);
        stereo->setActive(true);
    }

    std::printf("Bypass and offline render\n");
    {
        a = settled(server, "Stereo bus", *stereo);
        Collector collectorB;
        abr_server_select(server, a.session_id);
        abr_server_attach(server, a.format_epoch, Collector::sink, Collector::boundary, &collectorB, 0);
        FakeHost host(*stereo, 2, 48000, 128, 1.0);
        waitFor([&] { return collectorB.frames() > 4800; }, 3);
        stereo->setBypassed(true);
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.state == ABR_STATE_BYPASSED; }, 2), "bypass reported");
        std::this_thread::sleep_for(milliseconds(100));
        const size_t atBypass = collectorB.frames();
        const uint64_t processedAtBypass = stereo->status().framesProcessed;
        std::this_thread::sleep_for(milliseconds(300));
        CHECK(collectorB.frames() == atBypass && stereo->status().framesProcessed == processedAtBypass,
              "while bypassed nothing is sent and the stream position stands still");
        const uint64_t gapsBefore = a.discontinuities;
        stereo->setBypassed(false);
        waitFor([&] { return collectorB.frames() > atBypass + 4800; }, 2);
        findSource(server, "Stereo bus", a);
        CHECK(a.state == ABR_STATE_LIVE && a.discontinuities > gapsBefore && (a.last_reasons & ABR_AUDIO_AFTER_BYPASS),
              "resuming is live and reported as a break after bypass (reasons 0x%x)", a.last_reasons);
        {
            const auto marks = collectorB.marks();
            CHECK(!marks.empty() && marks.back().frame == atBypass && (marks.back().reasons & ABR_AUDIO_AFTER_BYPASS),
                  "the break reaches the sink exactly between the last frame before bypass and the first after (frame %zu)",
                  marks.empty() ? size_t(0) : marks.back().frame);
        }
        stereo->setOffline(true);
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.state == ABR_STATE_OFFLINE; }, 2),
              "offline render reported as OFFLINE");
        std::this_thread::sleep_for(milliseconds(100));
        const size_t atOffline = collectorB.frames();
        std::this_thread::sleep_for(milliseconds(300));
        CHECK(collectorB.frames() == atOffline, "offline-rendered audio is not sent as a live stream");
        stereo->setOffline(false);
        waitFor([&] { return collectorB.frames() > atOffline + 4800; }, 2);
        {
            const auto marks = collectorB.marks();
            CHECK(!marks.empty() && marks.back().frame == atOffline && (marks.back().reasons & ABR_AUDIO_AFTER_OFFLINE),
                  "live audio after an offline render is reported as a break after offline (reasons 0x%x)",
                  marks.empty() ? 0u : marks.back().reasons);
        }
        host.stop();
        abr_server_detach(server);
    }

    std::printf("Project state and identity\n");
    {
        const std::string saved = stereo->saveState();
        const std::string original = stereo->status().instanceTag;
        {
            // A duplicated track: the host creates an instance and gives it the original's state while the
            // original is still there.
            abr::BridgeCore copy(ABR_FORMAT_TEST);
            bool reassigned = false;
            CHECK(copy.restoreState(saved, &reassigned) && copy.sourceName() == "Stereo bus",
                  "a copy restores the name");
            const abr::CoreStatus status = copy.status();
            CHECK(reassigned && (status.identityFlags & ABR_IDENTITY_COPY) && status.instanceTag != original
                      && status.copiedFromTag == original,
                  "…but keeps an identity of its own (%s), reported as a copy of %s", status.instanceTag.c_str(),
                  status.copiedFromTag.c_str());
            copy.configure(48000, 2, 512);
            copy.setActive(true);
            AbrSourceInfo listed{};
            CHECK(waitFor([&] {
                      int count = 0;
                      for (const auto &info : sources(server))
                          if (std::string(info.source_name) == "Stereo bus" && (info.identity_flags & ABR_IDENTITY_COPY)) { ++count; listed = info; }
                      return count == 1;
                  }, 3),
                  "the copy connects as a separate live instance, flagged as a copy");
            findSource(server, "Stereo bus", a);
            CHECK(std::memcmp(listed.persistent_id, a.persistent_id, 16) != 0 && std::memcmp(listed.restored_id, a.persistent_id, 16) == 0
                      && std::memcmp(listed.session_id, a.session_id, 16) != 0,
                  "…with its own persistent and session IDs, naming the original's identity");
            const std::string copySaved = copy.saveState();
            CHECK(copySaved.find(status.instanceTag) != std::string::npos && copySaved.find(original) == std::string::npos,
                  "the copy saves its own identity, so the project keeps the two apart after reopening");
            bool again = true;
            copy.restoreState(copySaved, &again);
            CHECK(!again && copy.status().instanceTag == status.instanceTag, "restoring its own state again changes nothing (undo)");
            CHECK(!copy.restoreState("garbage"), "unknown state is rejected");
        }
        {
            // The project reopened: the original insert is gone and a new instance restores its state.
            auto donor = std::make_unique<abr::BridgeCore>(ABR_FORMAT_TEST);
            donor->setSourceName("Donor");
            const std::string donorState = donor->saveState();
            const std::string donorTag = donor->status().instanceTag;
            donor.reset();
            abr::BridgeCore reopened(ABR_FORMAT_TEST);
            bool reassigned = true;
            reopened.restoreState(donorState, &reassigned);
            const abr::CoreStatus status = reopened.status();
            CHECK(!reassigned && status.instanceTag == donorTag && (status.identityFlags & ABR_IDENTITY_RESTORED)
                      && !(status.identityFlags & ABR_IDENTITY_COPY),
                  "with the original gone, a restored instance takes over its identity (%s)", status.instanceTag.c_str());
            abr::BridgeCore second(ABR_FORMAT_TEST);
            second.restoreState(donorState, &reassigned);
            CHECK(reassigned && second.status().instanceTag != donorTag,
                  "a second instance restored from the same state (a project saved with duplicates) becomes a copy");
        }
    }

    std::printf("Reactivation, suspension and timeline\n");
    {
        a = settled(server, "Stereo bus", *stereo);
        const uint32_t epoch = a.format_epoch;
        Collector collectorR;
        abr_server_select(server, a.session_id);
        abr_server_attach(server, a.format_epoch, Collector::sink, Collector::boundary, &collectorR, 0);
        FakeHost host(*stereo, 2, 48000, 128, 1.0);
        waitFor([&] { return collectorR.frames() > 4800; }, 3);
        CHECK(collectorR.marks().empty(), "no break reported for the first block after a fresh attach");
        // The host deactivates and reactivates with the same format (a buffer-size change, a plugin reset).
        stereo->setActive(false);
        stereo->configure(48000, 2, 1024);
        stereo->setActive(true);
        waitFor([&] { return !collectorR.marks().empty(); }, 2);
        findSource(server, "Stereo bus", a);
        auto marks = collectorR.marks();
        CHECK(a.format_epoch == epoch && !marks.empty() && (marks.back().reasons & ABR_AUDIO_AFTER_RESTART),
              "reactivating with the same format keeps epoch %u and reports a restart (reasons 0x%x)", a.format_epoch,
              marks.empty() ? 0u : marks.back().reasons);
        // A short stall is not a break; a long one is.
        size_t before = marks.size();
        host.idleMs = 120;
        std::this_thread::sleep_for(milliseconds(400));
        CHECK(collectorR.marks().size() == before, "a 120 ms pause in processing is not reported");
        host.idleMs = 1000;
        CHECK(waitFor([&] { return collectorR.marks().size() > before; }, 3), "a 1 s pause in processing is reported");
        marks = collectorR.marks();
        CHECK((marks.back().reasons & ABR_AUDIO_AFTER_IDLE) && marks.back().idleMs >= 900 && marks.back().idleMs <= 1300,
              "…as the host being idle for %u ms", marks.back().idleMs);
        // A locate or loop while playing is metadata only.
        before = marks.size();
        const uint32_t jumps = stereo->status().transportJumps;
        host.jumpTo = 480000;
        std::this_thread::sleep_for(milliseconds(300));
        findSource(server, "Stereo bus", a);
        CHECK(stereo->status().transportJumps == jumps + 1 && collectorR.marks().size() == before,
              "a timeline jump is counted (%u) and is not a break in the signal", stereo->status().transportJumps);
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.transport_jumps == jumps + 1; }, 2),
              "…and reaches the receiver in the status");
        CHECK(host.worstNs.load() < kWorstProcessNs, "worst process() %.1f µs", host.worstNs.load() / 1000.0);
        host.stop();
        abr_server_detach(server);
    }

    std::printf("Stale audio after a quick re-selection\n");
    {
        // A slow receiver lets audio pile up in the plugin and the socket; then the selection moves away and
        // straight back (A → none → A). Nothing queued before the move may be delivered afterwards.
        quiesce(server);
        a = settled(server, "Stereo bus", *stereo);
        Collector first, second;
        abr_server_select(server, a.session_id);
        abr_server_attach(server, a.format_epoch, Collector::sink, Collector::boundary, &first, 0);
        const uint64_t base = stereo->status().framesProcessed;  // the fake host counts from 0, the plugin from here
        FakeHost host(*stereo, 2, 48000, 128, 1.0, true);
        waitFor([&] { return first.frames() > 4800; }, 3);
        first.sleepOnceMs = 250;  // the receiver thread stalls inside the sink: a backlog builds up
        std::this_thread::sleep_for(milliseconds(150));
        const uint64_t staleBefore = a.frames_stale;
        abr_server_select(server, nullptr);  // waits for the stalled sink to return: the switch happens then
        abr_server_select(server, a.session_id);
        const uint64_t positionAtSwitch = stereo->status().framesProcessed - base;
        abr_server_attach(server, a.format_epoch, Collector::sink, Collector::boundary, &second, 0);
        waitFor([&] { return second.frames() > 9600; }, 3);
        host.stop();
        quiesce(server);
        abr_server_detach(server);
        findSource(server, "Stereo bus", a);
        // Every sample says where it came from.
        uint64_t start = UINT64_MAX, backwards = 0, previous = 0;
        {
            std::lock_guard<std::mutex> guard(second.lock);
            for (size_t i = 0; i + 1 < second.samples.size(); i += 2) {
                const uint64_t position = uint64_t(double(second.samples[i]) * 16777216.0);
                if (i == 0) start = position;
                else if (position <= previous) ++backwards;
                previous = position;
            }
        }
        CHECK(start != UINT64_MAX && start >= positionAtSwitch,
              "the new subscription starts at or after the switch (position %llu, switch at %llu: %+.3f s)",
              (unsigned long long)start, (unsigned long long)positionAtSwitch,
              (double(start) - double(positionAtSwitch)) / 48000.0);
        CHECK(backwards == 0, "…and never goes back in time (%llu backward steps)", (unsigned long long)backwards);
        if (start < positionAtSwitch) {
            const auto marks = second.marks();
            std::printf("  info first delivered block: %zu marks, first at frame %zu reasons 0x%x; stale %llu\n", marks.size(),
                        marks.empty() ? size_t(0) : marks[0].frame, marks.empty() ? 0u : marks[0].reasons,
                        (unsigned long long)(a.frames_stale - staleBefore));
        }
        // How much was still in flight depends on who wins the sink lock after the stall; either way none of it
        // reached the new subscription (checked above).
        std::printf("  info %llu frames of the earlier subscription arrived after the switch and were discarded\n",
                    (unsigned long long)(a.frames_stale - staleBefore));
    }

    std::printf("Reconnection of the same insert\n");
    {
        a = settled(server, "Stereo bus", *stereo);
        Collector collectorC;
        abr_server_select(server, a.session_id);
        abr_server_attach(server, a.format_epoch, Collector::sink, Collector::boundary, &collectorC, 0);
        FakeHost host(*stereo, 2, 48000, 128, 1.0);
        waitFor([&] { return collectorC.frames() > 4800; }, 3);
        const uint32_t serial = a.connection_serial;
        // Restoring its own state for the first time makes the plugin announce itself again: it reconnects with
        // the same session, as after a dropped connection.
        stereo->restoreState(stereo->saveState());
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.connection_serial != serial; }, 3),
              "the plugin reconnects under the same session (connection %u → %u)", serial, a.connection_serial);
        const size_t atReconnect = collectorC.frames();
        CHECK(waitFor([&] { return collectorC.frames() > atReconnect + 9600; }, 3),
              "delivery continues into the same attachment without re-attaching");
        const auto marks = collectorC.marks();
        CHECK(!marks.empty() && (marks.back().reasons & ABR_AUDIO_STREAM_START),
              "…reported as a break (reasons 0x%x, %llu frames missing)", marks.empty() ? 0u : marks.back().reasons,
              marks.empty() ? 0ull : (unsigned long long)marks.back().lost);
        host.stop();
        abr_server_detach(server);
        // A deliberate continuation (resume after the user paused) reports nothing at its start.
        Collector resumed;
        abr_server_select(server, nullptr);
        abr_server_select(server, a.session_id);
        abr_server_attach(server, a.format_epoch, Collector::sink, Collector::boundary, &resumed, 0);
        FakeHost later(*stereo, 2, 48000, 128, 1.0);
        waitFor([&] { return resumed.frames() > 4800; }, 3);
        later.stop();
        abr_server_detach(server);
        CHECK(resumed.marks().empty(), "a resumed subscription attached without mark_start reports no break at its start");
    }

    std::printf("Receiver restart\n");
    {
        FakeHost host(*stereo, 2, 48000, 128, 1.0);
        std::this_thread::sleep_for(milliseconds(200));
        abr_server_stop(server);
        CHECK(waitFor([&] { return !stereo->status().connected; }, 2), "plugin notices Auraliscope is gone");
        const uint64_t before = host.position.load();
        std::this_thread::sleep_for(milliseconds(500));
        CHECK(host.position.load() > before + 20000 && host.worstNs.load() < kWorstProcessNs,
              "processing continues while disconnected (worst %.1f µs)", host.worstNs.load() / 1000.0);
        server = abr_server_start(nullptr, error, sizeof error);
        CHECK(server != nullptr, "receiver restarts on the same path");
        CHECK(waitFor([&] { return findSource(server, "Stereo bus", a) && stereo->status().connected; }, 3),
              "plugin reconnects within the retry interval");
        Collector again;
        abr_server_select(server, a.session_id);
        abr_server_attach(server, a.format_epoch, Collector::sink, Collector::boundary, &again, 0);
        CHECK(waitFor([&] { return again.frames() > 24000; }, 3), "audio resumes after reconnection");
        host.stop();
        abr_server_detach(server);
    }

    std::printf("Removal\n");
    {
        findSource(server, "Vocal", b);
        mono.reset();
        CHECK(waitFor([&] { AbrSourceInfo x; return !findSource(server, "Vocal", x); }, 2),
              "a destroyed instance disappears from the list at once");
    }

    std::printf("Protocol versions\n");
    {
        // An Auraliscope Bridge of protocol version 1 (1.3dev build 1) connecting to this receiver.
        const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        std::snprintf(address.sun_path, sizeof address.sun_path, "%s", path);
        const bool connected = connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof address) == 0;
        uint8_t hello[sizeof(AbrHeader) + 144] = {};
        const AbrHeader header{ABR_MAGIC, ABR_MSG_HELLO, 0, 144, 0};
        const uint32_t words[2] = {1, ABR_FORMAT_VST3};
        std::memcpy(hello, &header, sizeof header);
        std::memcpy(hello + sizeof header, words, sizeof words);
        send(fd, hello, sizeof hello, 0);
        AbrSourceInfo old{};
        CHECK(connected && waitFor([&] {
                  for (const auto &info : sources(server))
                      if (info.protocol_version == 1 && !info.compatible) { old = info; return true; }
                  return false;
              }, 2),
              "a version 1 plugin is listed as incompatible (protocol %u, format %u)", old.protocol_version, old.plugin_format);
        pollfd waiting{fd, POLLIN, 0};
        CHECK(poll(&waiting, 1, 300) == 0, "…and hears nothing back, so it stays connected instead of reconnecting every second");
        close(fd);
        CHECK(waitFor([&] {
                  for (const auto &info : sources(server)) if (!info.compatible) return false;
                  return true;
              }, 2),
              "…and leaves the list when it disconnects");

        // This plugin meeting a receiver of version 1 (Auraliscope Labs 1.3dev build 1).
        char oldPath[256];
        std::snprintf(oldPath, sizeof oldPath, "%s/old.sock", folder);
        const int listener = socket(AF_UNIX, SOCK_STREAM, 0);
        sockaddr_un oldAddress{};
        oldAddress.sun_family = AF_UNIX;
        std::snprintf(oldAddress.sun_path, sizeof oldAddress.sun_path, "%s", oldPath);
        bind(listener, reinterpret_cast<sockaddr *>(&oldAddress), sizeof oldAddress);
        listen(listener, 4);
        std::atomic<int> accepted{0};
        std::atomic<bool> serving{true};
        std::thread oldReceiver([&] {
            while (serving.load()) {
                pollfd ready{listener, POLLIN, 0};
                if (poll(&ready, 1, 50) <= 0) continue;
                const int client = accept(listener, nullptr, nullptr);
                if (client < 0) continue;
                ++accepted;
                uint8_t buffer[4096];
                recv(client, buffer, sizeof buffer, 0);
                uint8_t welcome[sizeof(AbrHeader) + sizeof(AbrWelcome)];
                const AbrHeader reply{ABR_MAGIC, ABR_MSG_WELCOME, 0, sizeof(AbrWelcome), 0};
                const AbrWelcome version{1, 0};
                std::memcpy(welcome, &reply, sizeof reply);
                std::memcpy(welcome + sizeof reply, &version, sizeof version);
                send(client, welcome, sizeof welcome, 0);
                close(client);  // as a version 1 receiver does with a plugin of another version
            }
        });
        // Every other instance is connected, so the sender thread reads the path only for the new one.
        setenv("AURALISCOPE_BRIDGE_SOCKET", oldPath, 1);
        auto newer = std::make_unique<abr::BridgeCore>(ABR_FORMAT_TEST);
        CHECK(waitFor([&] { return newer->status().receiverTooOld; }, 3) && !newer->status().connected,
              "the plugin recognises an older receiver and does not count it as connected");
        const int attempts = accepted.load();
        std::this_thread::sleep_for(milliseconds(3000));
        CHECK(accepted.load() == attempts, "…and does not retry every second (%d attempt(s) in 3 s)", accepted.load() - attempts);
        newer.reset();
        setenv("AURALISCOPE_BRIDGE_SOCKET", path, 1);
        serving = false;
        oldReceiver.join();
        close(listener);
        unlink(oldPath);
    }

    std::printf("Network discovery (DNS-SD, this Mac only)\n");
    {
        AbrAdvertiser *beacon = abr_advertise_start("Bridge test iPad", 50505, "iPadOS", "Auraliscope", "1.4", "display", "tcp", 1);
        AbrBrowser *browser = abr_browser_start();
        AbrPeer found{};
        CHECK(beacon && browser && waitFor([&] {
                  AbrPeer peers[32];
                  const uint32_t count = abr_browser_peers(browser, peers, 32);
                  for (uint32_t i = 0; i < count && i < 32; ++i)
                      if (std::string(peers[i].name) == "Bridge test iPad" && peers[i].resolved) { found = peers[i]; return true; }
                  return false;
              }, 5),
              "an advertised receiver is found and resolved: %s %s %s on %s:%u, proto %u, this Mac %d", found.app,
              found.platform, found.version, found.host, found.port, found.protocol, found.this_mac);
        CHECK(std::string(found.role) == "display" && std::string(found.transport) == "tcp" && found.protocol == ABR_PROTOCOL_VERSION,
              "TXT record carries role, transport and protocol");
        abr_advertise_stop(beacon);
        CHECK(waitFor([&] {
                  AbrPeer peers[32];
                  const uint32_t count = abr_browser_peers(browser, peers, 32);
                  for (uint32_t i = 0; i < count && i < 32; ++i) if (std::string(peers[i].name) == "Bridge test iPad") return false;
                  return true;
              }, 5),
              "a receiver that stops advertising disappears from the scan");
        abr_browser_stop(browser);
    }

    stereo.reset();
    CHECK(!abr::senderRunning(), "no thread is left once every instance is gone (the binary can be unloaded)");
    abr_server_stop(server);
    rmdir(folder);
    std::printf(failures ? "\n%d check(s) FAILED\n" : "\nAll transport checks passed\n", failures);
    return failures ? 1 : 0;
}
