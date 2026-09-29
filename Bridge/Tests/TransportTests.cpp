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
#include <unistd.h>
#include <vector>

#include "BridgeCore.h"
extern "C" {
#include "BridgeDiscovery.h"
#include "BridgeServer.h"
}

using namespace std::chrono;

static int failures = 0;
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
    std::mutex lock;
    std::vector<float> samples;
    uint32_t channels = 0;
    std::atomic<int> sleepOnceMs{0};
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
    std::thread thread;
    FakeHost(abr::BridgeCore &core, uint32_t channels, double rate, uint32_t block, double speed)
        : core(core), channels(channels), rate(rate), block(block) {
        thread = std::thread([this, speed] {
            makeRealTime(this->block / this->rate / speed);
            std::vector<std::vector<float>> buffers(this->channels, std::vector<float>(this->block));
            const float *planar[ABR_MAX_CHANNELS];
            auto next = steady_clock::now();
            const auto period = duration<double>(this->block / this->rate / speed);
            while (running.load()) {
                const uint64_t start = position.load();
                for (uint32_t c = 0; c < this->channels; ++c) {
                    for (uint32_t i = 0; i < this->block; ++i) buffers[c][i] = signal(c, start + i, this->rate);
                    planar[c] = buffers[c].data();
                }
                const auto before = steady_clock::now();
                this->core.process(planar, this->channels, this->block, ABR_TRANSPORT_KNOWN | ABR_TRANSPORT_PLAYING);
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
    char folder[] = "/tmp/abr-test-XXXXXX", path[256];
    if (!mkdtemp(folder)) return 1;
    std::snprintf(path, sizeof path, "%s/bridge.sock", folder);
    setenv("AURALISCOPE_BRIDGE_SOCKET", path, 1);
    char error[256] = "";
    AbrServer *server = abr_server_start(nullptr, error, sizeof error);
    if (!server) { std::printf("server failed: %s\n", error); return 1; }

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
        abr_server_attach(server, a.format_epoch, Collector::sink, &collector);
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
        CHECK(host.worstNs.load() < 200000, "worst process() call %.1f µs", host.worstNs.load() / 1000.0);
    }

    std::printf("Mono stream, bit-exact\n");
    {
        Collector monoCollector;
        findSource(server, "Vocal", b);
        abr_server_select(server, b.session_id);
        abr_server_attach(server, b.format_epoch, Collector::sink, &monoCollector);
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
        abr_server_attach(server, a.format_epoch, Collector::sink, &slow);
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
        CHECK(host.worstNs.load() < 200000, "audio thread never waits: worst process() %.1f µs across a 1 s receiver stall",
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
        abr_server_attach(server, oldEpoch, Collector::sink, &collector96);
        FakeHost host(*stereo, 1, 96000, 256, 1.0);
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.format_epoch != oldEpoch && a.frames_discarded > 0; }, 3),
              "new epoch %u reported (96 kHz, %u ch); its audio is held back while attached to epoch %u",
              a.format_epoch, a.channels, oldEpoch);
        CHECK(collector96.frames() == 0, "no audio of the new format reached the old configuration");
        abr_server_attach(server, a.format_epoch, Collector::sink, &collector96);  // what the app does after reconfiguring
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
        abr_server_attach(server, a.format_epoch, Collector::sink, &collectorB);
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
        CHECK(a.state == ABR_STATE_LIVE && a.discontinuities > gapsBefore, "resuming is live and marked as a discontinuity");
        stereo->setOffline(true);
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.state == ABR_STATE_OFFLINE; }, 2),
              "offline render reported as OFFLINE");
        std::this_thread::sleep_for(milliseconds(100));
        const size_t atOffline = collectorB.frames();
        std::this_thread::sleep_for(milliseconds(300));
        CHECK(collectorB.frames() == atOffline, "offline-rendered audio is not sent as a live stream");
        stereo->setOffline(false);
        host.stop();
        abr_server_detach(server);
    }

    std::printf("Project state\n");
    {
        const std::string saved = stereo->saveState();
        abr::BridgeCore restored(ABR_FORMAT_TEST);
        CHECK(restored.restoreState(saved) && restored.sourceName() == "Stereo bus"
                  && restored.status().instanceTag == stereo->status().instanceTag,
              "name and persistent ID survive save and restore");
        restored.configure(48000, 2, 512);
        restored.setActive(true);
        AbrSourceInfo copy{};
        CHECK(waitFor([&] {
                  int count = 0;
                  for (const auto &info : sources(server)) if (std::string(info.source_name) == "Stereo bus") { ++count; copy = info; }
                  return count == 2;
              }, 3),
              "a restored copy connects as a separate live instance");
        findSource(server, "Stereo bus", a);
        CHECK(std::memcmp(copy.persistent_id, a.persistent_id, 16) == 0 && std::memcmp(copy.session_id, a.session_id, 16) != 0,
              "…with the same persistent ID and its own session ID");
        CHECK(!restored.restoreState("garbage"), "unknown state is rejected");
    }

    std::printf("Receiver restart\n");
    {
        FakeHost host(*stereo, 2, 48000, 128, 1.0);
        std::this_thread::sleep_for(milliseconds(200));
        abr_server_stop(server);
        CHECK(waitFor([&] { return !stereo->status().connected; }, 2), "plugin notices Auraliscope is gone");
        const uint64_t before = host.position.load();
        std::this_thread::sleep_for(milliseconds(500));
        CHECK(host.position.load() > before + 20000 && host.worstNs.load() < 200000,
              "processing continues while disconnected (worst %.1f µs)", host.worstNs.load() / 1000.0);
        server = abr_server_start(nullptr, error, sizeof error);
        CHECK(server != nullptr, "receiver restarts on the same path");
        CHECK(waitFor([&] { return findSource(server, "Stereo bus", a) && stereo->status().connected; }, 3),
              "plugin reconnects within the retry interval");
        Collector again;
        abr_server_select(server, a.session_id);
        abr_server_attach(server, a.format_epoch, Collector::sink, &again);
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
    abr_server_stop(server);
    rmdir(folder);
    std::printf(failures ? "\n%d check(s) FAILED\n" : "\nAll transport checks passed\n", failures);
    return failures ? 1 : 0;
}
