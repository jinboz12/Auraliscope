// Transport tests, protocol version 3: the plugin core (BridgeCore with its analysis and sender threads and the
// shared analysis core) against the application's receiver (BridgeServer), in one process over a private socket.
// No plugin format and no DAW is involved; the harness in Bridge/Tools covers the real VST3 and AU binaries.
//
// RESULT payloads are read here with BridgeWire.h and the tags of Bridge/PROTOCOL.md, independently of the Swift
// decoder Labs uses, so the two implementations check each other against the written specification.
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
#include "BridgeWire.h"
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

// The deterministic test signal, a function of the stream position alone: every channel differs in frequency and
// level (channel c: 0.5/(c+1) at 997 + 502c Hz), so a swapped, duplicated or scaled channel cannot pass. Stereo
// integrated loudness −7.76 LUFS; mono (L only) −9.03 LUFS; peaks −6.021 and −12.041 dBFS; a 7.1.4 bus −6.33 LUFS.
static float signal(uint32_t channel, uint64_t n, double rate) {
    const double frequency = 997.0 + 502.0 * channel, amplitude = 0.5 / (channel + 1);
    return float(amplitude * std::sin(2 * M_PI * frequency * double(n) / rate));
}

static double db(float linear) { return 20 * std::log10(std::max(1e-9, double(linear))); }

// A RESULT, read field by field (ResultProtocol.swift, schema 1).
struct Result {
    uint32_t subscription = 0, schema = 0, generation = 0, epoch = 0, channels = 0, measurement = 0, flags = 0;
    uint32_t breaks = 0, lastReasons = 0, layout = 0, roleCount = 0, spectrumChannels = 0;
    uint8_t roles[ABR_MAX_CHANNELS] = {};
    double rate = 0, missing = 0;
    uint64_t sequence = 0, tick = 0, timelineEnd = 0, framesAnalysed = 0;
    uint64_t specFirst = 0, specLatest = 0, specDropped = 0, waveFirst = 0, waveLatest = 0, waveDropped = 0;
    uint32_t specColumns = 0, waveColumns = 0;
    float peak[ABR_MAX_CHANNELS] = {}, rms[ABR_MAX_CHANNELS] = {}, heldTruePeak[ABR_MAX_CHANNELS] = {};
    float momentary = -100, shortTerm = -100, integrated = -100, range = -1, correlation = -2, dominant = 0;
    int unknownKinds = 0;
    steady_clock::time_point arrived;

    static float f32(const AbrField &f, uint32_t i = 0) {
        const uint32_t bits = abr_get32(f.value + 4 * i);
        float v;
        std::memcpy(&v, &bits, 4);
        return v;
    }
    static Result read(const uint8_t *payload, uint32_t length) {
        Result r;
        AbrReader reader = abr_reader(payload, length);
        AbrField f;
        while (abr_next_field(&reader, &f)) {
            switch (f.tag) {
            case 1: abr_field_u32(&f, &r.subscription); break;
            case 2: abr_field_u32(&f, &r.schema); break;
            case 3: abr_field_u32(&f, &r.generation); break;
            case 4: abr_field_u32(&f, &r.epoch); break;
            case 5: abr_field_f64(&f, &r.rate); break;
            case 6: abr_field_u32(&f, &r.channels); break;
            case 7: abr_field_u32(&f, &r.layout); break;
            case 18:
                if (f.kind == ABR_KIND_U8 && f.count <= ABR_MAX_CHANNELS) { std::memcpy(r.roles, f.value, f.count); r.roleCount = f.count; }
                break;
            case 52: abr_field_u32(&f, &r.spectrumChannels); break;
            case 8: abr_field_u64(&f, &r.sequence); break;
            case 9: abr_field_u64(&f, &r.tick); break;
            case 11: abr_field_u64(&f, &r.timelineEnd); break;
            case 12: abr_field_u64(&f, &r.framesAnalysed); break;
            case 13: abr_field_u32(&f, &r.measurement); break;
            case 14: abr_field_u32(&f, &r.flags); break;
            case 15: abr_field_u32(&f, &r.breaks); break;
            case 16: abr_field_f64(&f, &r.missing); break;
            case 17: abr_field_u32(&f, &r.lastReasons); break;
            case 20: for (uint32_t i = 0; i < f.count && i < ABR_MAX_CHANNELS; ++i) r.peak[i] = f32(f, i); break;
            case 21: for (uint32_t i = 0; i < f.count && i < ABR_MAX_CHANNELS; ++i) r.rms[i] = f32(f, i); break;
            case 24: for (uint32_t i = 0; i < f.count && i < ABR_MAX_CHANNELS; ++i) r.heldTruePeak[i] = f32(f, i); break;
            case 30: r.momentary = f32(f); break;
            case 31: r.shortTerm = f32(f); break;
            case 32: r.integrated = f32(f); break;
            case 33: r.range = f32(f); break;
            case 41: r.dominant = f32(f); break;
            case 43: r.correlation = f32(f); break;
            case 60: abr_field_u64(&f, &r.specFirst); break;
            case 62: r.specColumns = f.count / 512; break;
            case 63: abr_field_u64(&f, &r.specLatest); break;
            case 64: abr_field_u64(&f, &r.specDropped); break;
            case 70: abr_field_u64(&f, &r.waveFirst); break;
            case 72: r.waveColumns = r.channels ? f.count / (2 * r.channels) : 0; break;
            case 73: abr_field_u64(&f, &r.waveLatest); break;
            case 74: abr_field_u64(&f, &r.waveDropped); break;
            default: break;
            }
        }
        if (reader.malformed) ++r.unknownKinds;
        return r;
    }
};

struct Collector {
    std::mutex lock;
    std::vector<Result> results;
    std::atomic<int> sleepOnceMs{0};
    static void sink(void *context, const uint8_t *payload, uint32_t length) {
        auto *self = static_cast<Collector *>(context);
        Result r = Result::read(payload, length);
        r.arrived = steady_clock::now();
        {
            std::lock_guard<std::mutex> guard(self->lock);
            self->results.push_back(r);
        }
        if (int ms = self->sleepOnceMs.load()) {
            std::this_thread::sleep_for(milliseconds(ms));
            self->sleepOnceMs.store(0);
        }
    }
    size_t count() {
        std::lock_guard<std::mutex> guard(lock);
        return results.size();
    }
    Result last() {
        std::lock_guard<std::mutex> guard(lock);
        return results.empty() ? Result{} : results.back();
    }
    std::vector<Result> all() {
        std::lock_guard<std::mutex> guard(lock);
        return results;
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

// Plays `core` like a host's audio thread: blocks of `block` frames at `speed` × real time. Checks that the
// output (the planar buffers after process) still equals the input: the plugin passes audio through untouched.
struct FakeHost {
    abr::BridgeCore &core;
    uint32_t channels;
    double rate;
    uint32_t block;
    std::atomic<bool> running{true};
    std::atomic<uint64_t> position{0};
    std::atomic<int64_t> worstNs{0};
    std::atomic<uint64_t> altered{0};
    std::atomic<int> idleMs{0};           // the host stops calling process for this long, once
    std::atomic<int64_t> jumpTo{-1};      // the host's timeline jumps here (the signal does not)
    int64_t timeline = 0;
    std::thread thread;
    FakeHost(abr::BridgeCore &core, uint32_t channels, double rate, uint32_t block, double speed = 1.0)
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
                for (uint32_t c = 0; c < this->channels; ++c)
                    for (uint32_t i = 0; i < this->block; ++i)
                        if (buffers[c][i] != signal(c, start + i, this->rate)) altered.fetch_add(1);
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

// Every column serial of both ordered series, across results: contiguous, never repeated, never going back.
static bool columnsInOrder(const std::vector<Result> &results, uint64_t &gaps, uint64_t &repeats) {
    gaps = repeats = 0;
    uint64_t spec = 0, wave = 0;
    for (const auto &r : results) {
        for (uint32_t i = 0; i < r.specColumns; ++i) {
            const uint64_t serial = r.specFirst + i;
            if (spec && serial <= spec) ++repeats;
            else if (spec && serial > spec + 1) gaps += serial - spec - 1;
            spec = std::max(spec, serial);
        }
        for (uint32_t i = 0; i < r.waveColumns; ++i) {
            const uint64_t serial = r.waveFirst + i;
            if (wave && serial <= wave) ++repeats;
            else if (wave && serial > wave + 1) gaps += serial - wave - 1;
            wave = std::max(wave, serial);
        }
    }
    return gaps == 0 && repeats == 0;
}

static uint64_t footprint() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS ? info.phys_footprint : 0;
}

// A raw receiver speaking just enough of the protocol to test the plugin's side of it.
struct RawReceiver {
    int listener = -1;
    std::string path;
    explicit RawReceiver(const std::string &p) : path(p) {
        listener = socket(AF_UNIX, SOCK_STREAM, 0);
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        std::snprintf(address.sun_path, sizeof address.sun_path, "%s", path.c_str());
        bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof address);
        listen(listener, 4);
    }
    ~RawReceiver() { close(listener); unlink(path.c_str()); }
    static void send(int fd, uint16_t type, const void *payload, uint32_t length) {
        uint8_t message[512];
        const AbrHeader header{ABR_MAGIC, type, 0, length, 0};
        std::memcpy(message, &header, sizeof header);
        std::memcpy(message + sizeof header, payload, length);
        ::send(fd, message, sizeof header + length, 0);
    }
};

int main() {
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
        // sender and analysis threads must start and stop cleanly however those interleave: a watchdog fails the
        // run instead of hanging it if they ever deadlock.
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
                std::vector<float> tone(1024);
                for (size_t i = 0; i < tone.size(); ++i) tone[i] = signal(0, i, 48000);
                const float *planar[2] = {tone.data(), tone.data()};
                for (int i = 0; i < 200; ++i) {
                    auto core = std::make_unique<abr::BridgeCore>(ABR_FORMAT_TEST);
                    ++created;
                    if ((i + t) % 3 == 0) {
                        core->configure(48000, 2, 1024);
                        core->setActive(true);
                        for (int k = 0; k < 4; ++k) core->process(planar, 2, 1024, abr::HostTransport{});
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
        CHECK(!abr::senderRunning() && !abr::analysisRunning(), "the sender and analysis threads stop when the last instance goes");
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
    CHECK(a.protocol_version == ABR_PROTOCOL_VERSION && a.host_pid == getpid() && a.schema == ABR_ANALYSIS_SCHEMA
              && (a.capabilities & ABR_CAPABILITY_RESULTS) && (a.capabilities & ABR_CAPABILITY_PAUSE),
          "protocol %u, schema %u, capabilities 0x%x, host pid", a.protocol_version, a.schema, a.capabilities);

    std::printf("One-click focus\n");
    {
        const uint32_t before = a.focus_requests;
        stereo->requestFocus();
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.focus_requests == before + 1; }, 2)
                  && !stereo->status().focusPending,
              "\"Show in Auraliscope\" reaches the receiver once (%u request)", a.focus_requests);
    }

    std::printf("Analysis in the plugin, before anyone subscribes\n");
    Collector collector;
    {
        FakeHost host(*stereo, 2, 48000, 128);
        FakeHost other(*mono, 1, 44100, 64);
        std::this_thread::sleep_for(milliseconds(3200));
        const abr::CoreStatus s = stereo->status();
        CHECK(s.resultsSent == 0, "nothing is sent before Auraliscope Labs subscribes");
        CHECK(s.hasAnalysis && s.analysis.seconds_analysed > 2.5 && s.measurement == ABR_MEASUREMENT_MEASURING,
              "…but the insert measures its own audio: %.2f s analysed, generation %u", s.analysis.seconds_analysed,
              s.analysis.generation);
        CHECK(std::fabs(db(s.analysis.peak[0]) + 6.021) < 0.01 && std::fabs(db(s.analysis.peak[1]) + 12.041) < 0.01
                  && std::fabs(s.analysis.integrated + 7.76f) < 0.05,
              "…correctly: peaks %.3f / %.3f dBFS, integrated %.2f LUFS", db(s.analysis.peak[0]), db(s.analysis.peak[1]),
              s.analysis.integrated);
        CHECK(host.altered.load() == 0 && other.altered.load() == 0, "output equals input, sample for sample");

        std::printf("Results to a subscriber\n");
        abr_server_select(server, a.session_id);
        abr_server_attach(server, Collector::sink, &collector);
        waitFor([&] { return collector.count() >= 180; }, 6);
        host.stop();
        other.stop();
        abr_server_detach(server);
        const auto results = collector.all();
        const Result last = collector.last();
        CHECK(results.size() >= 150, "%zu results in about 3 s (60 per second of audio)", results.size());
        CHECK(last.schema == 1 && last.channels == 2 && last.rate == 48000 && last.subscription != 0 && last.unknownKinds == 0,
              "schema %u, %u ch, %.0f Hz, subscription %u", last.schema, last.channels, last.rate, last.subscription);
        CHECK(std::fabs(db(last.peak[0]) + 6.021) < 0.01 && std::fabs(db(last.peak[1]) + 12.041) < 0.01,
              "peaks %.3f / %.3f dBFS (L and R in order)", db(last.peak[0]), db(last.peak[1]));
        CHECK(std::fabs(last.integrated + 7.76f) < 0.05 && std::fabs(last.momentary + 7.76f) < 0.1 && std::fabs(last.correlation) < 0.05,
              "integrated %.2f, momentary %.2f LUFS, correlation %.3f", last.integrated, last.momentary, last.correlation);
        CHECK(std::fabs(last.dominant - 997) < 15, "dominant frequency %.1f Hz", last.dominant);
        CHECK(results.front().framesAnalysed > 48000 * 2.5,
              "the first result already covers the audio analysed before subscribing (%.2f s)",
              results.front().framesAnalysed / 48000.0);
        uint64_t gaps = 0, repeats = 0;
        CHECK(columnsInOrder(results, gaps, repeats) && last.specDropped == 0 && last.waveDropped == 0,
              "spectrogram and waveform columns arrive in order: no gap, no repeat (gaps %llu, repeats %llu)",
              (unsigned long long)gaps, (unsigned long long)repeats);
        uint64_t firstSpectrogram = UINT64_MAX;
        for (const auto &r : results) if (r.specColumns) { firstSpectrogram = r.specFirst; break; }
        CHECK(firstSpectrogram == 1 || firstSpectrogram + 63 >= results.front().specLatest,
              "a new subscriber gets the columns still held (from serial %llu of %llu): about 2 s of history",
              (unsigned long long)firstSpectrogram, (unsigned long long)results.front().specLatest);
        findSource(server, "Vocal", b);
        CHECK(b.results_received == 0, "the unselected instance sent no results (%llu)", (unsigned long long)b.results_received);
        CHECK(host.worstNs.load() < kWorstProcessNs, "worst process() call %.1f µs", host.worstNs.load() / 1000.0);
    }

    std::printf("Mono results\n");
    {
        Collector monoCollector;
        findSource(server, "Vocal", b);
        abr_server_select(server, b.session_id);
        abr_server_attach(server, Collector::sink, &monoCollector);
        FakeHost host(*mono, 1, 44100, 64);
        waitFor([&] { return monoCollector.count() >= 60; }, 5);
        host.stop();
        abr_server_detach(server);
        const Result r = monoCollector.last();
        CHECK(r.channels == 1 && r.rate == 44100 && std::fabs(db(r.peak[0]) + 6.021) < 0.01 && std::fabs(r.integrated + 9.03f) < 0.05,
              "1 ch at %.0f Hz: peak %.3f dBFS, integrated %.2f LUFS", r.rate, db(r.peak[0]), r.integrated);
    }

    std::printf("Immersive bus\n");
    {
        // A 7.1.4 bus as the VST3 wrapper configures it: L R C LFE, Ls Rs as the rear pair (Lrs Rrs) beside the side
        // pair Sl Sr (Ls Rs), then Tfl Tfr Trl Trr. Configuring it grows the ring while the analysis thread runs.
        const uint8_t roles[12] = {ABR_ROLE_L, ABR_ROLE_R, ABR_ROLE_C, ABR_ROLE_LFE, ABR_ROLE_LRS, ABR_ROLE_RRS,
                                   ABR_ROLE_LS, ABR_ROLE_RS, ABR_ROLE_LTF, ABR_ROLE_RTF, ABR_ROLE_LTR, ABR_ROLE_RTR};
        auto bus = std::make_unique<abr::BridgeCore>(ABR_FORMAT_TEST);
        bus->setSourceName("Atmos bed");
        bus->configure(48000, 2, 256);
        bus->setActive(true);
        {
            FakeHost warm(*bus, 2, 48000, 256);
            std::this_thread::sleep_for(milliseconds(400));
        }
        bus->setActive(false);
        bus->configure(48000, abr::ChannelLayout::speakers(roles, 12), 256);
        bus->setActive(true);
        AbrSourceInfo info{};
        CHECK(waitFor([&] { return findSource(server, "Atmos bed", info) && info.role_count == 12; }, 3) && info.channels == 12
                  && info.layout == ABR_LAYOUT_SPEAKERS && std::memcmp(info.roles, roles, 12) == 0
                  && std::strcmp(info.layout_name, "7.1.4") == 0,
              "STATUS: %u ch, layout %u, every channel's role, named \"%s\"", info.channels, info.layout, info.layout_name);
        Collector immersive;
        abr_server_set_spectrum(server, 1);
        abr_server_select(server, info.session_id);
        abr_server_attach(server, Collector::sink, &immersive);
        FakeHost host(*bus, 12, 48000, 256);
        waitFor([&] { return immersive.count() >= 150; }, 6);
        host.stop();
        abr_server_detach(server);
        const Result r = immersive.last();
        bool levels = r.channels == 12 && r.roleCount == 12 && r.layout == ABR_LAYOUT_SPEAKERS;
        for (uint32_t c = 0; c < 12 && levels; ++c)
            levels = r.roles[c] == roles[c] && std::fabs(db(r.peak[c]) - db(0.5f / float(c + 1))) < 0.01;
        CHECK(levels, "results: 12 channels in the bus's order, each with its role and its own level (%.3f … %.3f dBFS)",
              db(r.peak[0]), db(r.peak[11]));
        CHECK(std::fabs(r.integrated + 6.33f) < 0.05 && r.spectrumChannels == 1,
              "integrated %.2f LUFS (BS.1770 weights by role); the spectrum sums every channel, as asked", r.integrated);
        CHECK(host.altered.load() == 0 && bus->status().framesDropped == 0, "output equals input on all 12 channels; nothing unanalysed");
        CHECK(host.worstNs.load() < kWorstProcessNs, "worst process() call with 12 channels %.1f µs", host.worstNs.load() / 1000.0);
        // Back to stereo: a new generation of 2 channels, L and R.
        bus->setActive(false);
        bus->configure(48000, 2, 256);
        bus->setActive(true);
        Collector back;
        abr_server_set_spectrum(server, 0);
        abr_server_attach(server, Collector::sink, &back);
        FakeHost stereoHost(*bus, 2, 48000, 256);
        waitFor([&] { return back.count() >= 30 && back.last().channels == 2; }, 4);
        stereoHost.stop();
        abr_server_detach(server);
        abr_server_select(server, nullptr);
        const Result s2 = back.last();
        CHECK(s2.channels == 2 && s2.layout == ABR_LAYOUT_STEREO && s2.generation > r.generation && s2.spectrumChannels == 0
                  && std::fabs(db(s2.peak[1]) + 12.041) < 0.01,
              "reconfigured to stereo: generation %u, %u ch, layout %u, R %.3f dBFS", s2.generation, s2.channels, s2.layout,
              db(s2.peak[1]));
    }

    std::printf("Slow receiver\n");
    {
        // Auraliscope Labs stalls (a hiccup on its receiving thread), then recovers. The analysis does not depend on
        // it: nothing is lost from the measurement, only display updates.
        Collector slow;
        findSource(server, "Stereo bus", a);
        const uint64_t droppedBefore = stereo->status().framesDropped;
        abr_server_select(server, a.session_id);
        abr_server_attach(server, Collector::sink, &slow);
        FakeHost host(*stereo, 2, 48000, 32);
        waitFor([&] { return slow.count() > 30; }, 3);
        slow.sleepOnceMs = 3000;
        waitFor([&] { return slow.sleepOnceMs.load() == 0; }, 5);
        const size_t afterStall = slow.count();
        std::this_thread::sleep_for(milliseconds(1000));
        const auto results = slow.all();
        const uint64_t processed = stereo->status().framesProcessed;
        host.stop();
        abr_server_detach(server);
        CHECK(host.worstNs.load() < kWorstProcessNs, "audio thread never waits: worst process() %.1f µs across a 3 s stall",
              host.worstNs.load() / 1000.0);
        CHECK(stereo->status().framesDropped == droppedBefore, "the measurement lost nothing to the stall (0 frames unanalysed)");
        const Result recovered = results.back();
        CHECK(results.size() - afterStall > 40, "results recover to the display rate (%zu in the next second)",
              results.size() - afterStall);
        // Results already in the socket buffers when the stall began arrive in one burst after it; the display keeps
        // only the newest state, so they are superseded before the next frame. Their number is bounded by the
        // buffers, not by the length of the stall.
        size_t staleCount = 0;
        double spreadMs = 0;
        for (size_t i = afterStall; i < results.size(); ++i) {
            if (results[i].timelineEnd + 48000 / 2 >= results.back().timelineEnd - 48000) break;
            ++staleCount;
            spreadMs = duration<double, std::milli>(results[i].arrived - results[afterStall].arrived).count();
        }
        CHECK(staleCount <= 16 && spreadMs < 50,
              "results queued before the stall are few and arrive at once (%zu within %.1f ms), then state is current",
              staleCount, spreadMs);
        CHECK(processed - recovered.timelineEnd < 48000 * 0.1, "the newest result is %.0f ms behind the audio",
              (processed - recovered.timelineEnd) / 48.0);
        uint64_t gaps = 0, repeats = 0;
        columnsInOrder(results, gaps, repeats);
        uint64_t reported = 0;
        for (const auto &r : results) reported += r.specDropped + r.waveDropped;
        CHECK(repeats == 0 && gaps > 0 && reported == gaps,
              "a stall longer than the column queues loses columns visibly: %llu missing, each reported by the plugin (%llu)",
              (unsigned long long)gaps, (unsigned long long)reported);
    }

    std::printf("Analysis falling behind\n");
    {
        // The analysis thread is starved for 3.5 s (longer than an instance's queue, 2.7 s at 48 kHz stereo). The
        // audio thread drops the newest audio from the analysis — never from the output — and the analysis marks a
        // break with the time missing.
        Collector behind;
        findSource(server, "Stereo bus", a);
        abr_server_select(server, a.session_id);
        abr_server_attach(server, Collector::sink, &behind);
        FakeHost host(*stereo, 2, 48000, 128);
        waitFor([&] { return behind.count() > 30; }, 3);
        const Result before = behind.last();
        const uint64_t droppedBefore = stereo->status().framesDropped;
        abr::holdAnalysisForTesting(true);
        std::this_thread::sleep_for(milliseconds(3500));
        abr::holdAnalysisForTesting(false);
        waitFor([&] { return behind.last().breaks > before.breaks; }, 3);
        std::this_thread::sleep_for(milliseconds(300));
        host.stop();
        abr_server_detach(server);
        const Result after = behind.last();
        const uint64_t dropped = stereo->status().framesDropped - droppedBefore;
        CHECK(dropped > 0 && host.worstNs.load() < kWorstProcessNs && host.altered.load() == 0,
              "the queue overflowed: %llu frames unanalysed; the audio thread never waited (%.1f µs) and the output was untouched",
              (unsigned long long)dropped, host.worstNs.load() / 1000.0);
        CHECK(after.breaks > before.breaks && (after.lastReasons & ABR_AUDIO_AFTER_DROP)
                  && std::fabs((after.missing - before.missing) - dropped / 48000.0) < 0.05,
              "the analysis marked a break for it (reasons 0x%x, %.2f s missing)", after.lastReasons, after.missing - before.missing);
        CHECK(after.generation == before.generation && std::fabs(after.integrated + 7.76f) < 0.05,
              "integrated loudness carries on across it (%.2f LUFS, same generation)", after.integrated);
    }

    std::printf("Format change\n");
    {
        Collector collector96;
        findSource(server, "Stereo bus", a);
        abr_server_select(server, a.session_id);
        abr_server_attach(server, Collector::sink, &collector96);
        const uint32_t generation = stereo->status().analysis.generation;
        stereo->setActive(false);
        stereo->configure(96000, 1, 1024);
        stereo->setActive(true);
        FakeHost host(*stereo, 1, 96000, 256);
        CHECK(waitFor([&] { const Result r = collector96.last(); return r.rate == 96000 && r.framesAnalysed > 96000; }, 4),
              "results of the new format arrive");
        host.stop();
        abr_server_detach(server);
        const Result r = collector96.last();
        CHECK(r.generation == generation + 1 && r.channels == 1 && std::fabs(db(r.peak[0]) + 6.021) < 0.01 && r.breaks == 0,
              "a new generation (%u → %u) analyses 96 kHz mono from scratch: peak %.3f dBFS, %u breaks",
              generation, r.generation, db(r.peak[0]), r.breaks);
        bool mixed = false;
        for (const auto &x : collector96.all()) if (x.generation == r.generation && x.rate != 96000) mixed = true;
        CHECK(!mixed, "no result mixes the two formats");
        stereo->setActive(false);
        stereo->configure(48000, 2, 512);
        stereo->setActive(true);
    }

    std::printf("Bypass and offline render\n");
    {
        Collector collectorB;
        findSource(server, "Stereo bus", a);
        abr_server_select(server, a.session_id);
        abr_server_attach(server, Collector::sink, &collectorB);
        FakeHost host(*stereo, 2, 48000, 128);
        waitFor([&] { return collectorB.last().framesAnalysed > 48000; }, 4);
        const Result before = collectorB.last();
        stereo->setBypassed(true);
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.state == ABR_STATE_BYPASSED; }, 2), "bypass reported");
        std::this_thread::sleep_for(milliseconds(150));
        const uint64_t analysedAtBypass = stereo->status().analysis.frames_analysed;
        std::this_thread::sleep_for(milliseconds(400));
        CHECK(stereo->status().analysis.frames_analysed == analysedAtBypass, "while bypassed nothing is measured");
        CHECK(collectorB.last().flags & 1, "…and the results say so (published without audio: meters fall to silence, peak %.1f dBFS)",
              db(collectorB.last().peak[0]));
        stereo->setBypassed(false);
        waitFor([&] { return collectorB.last().framesAnalysed > analysedAtBypass + 24000; }, 2);
        Result r = collectorB.last();
        CHECK(r.breaks == before.breaks + 1 && (r.lastReasons & ABR_AUDIO_AFTER_BYPASS) && r.generation == before.generation,
              "resuming counts one break after bypass (reasons 0x%x), same generation", r.lastReasons);
        stereo->setOffline(true);
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.state == ABR_STATE_OFFLINE; }, 2),
              "offline render reported as OFFLINE");
        std::this_thread::sleep_for(milliseconds(150));
        const uint64_t analysedAtOffline = stereo->status().analysis.frames_analysed;
        std::this_thread::sleep_for(milliseconds(400));
        CHECK(stereo->status().analysis.frames_analysed == analysedAtOffline, "offline-rendered audio is not measured as live");
        stereo->setOffline(false);
        waitFor([&] { return collectorB.last().framesAnalysed > analysedAtOffline + 24000; }, 2);
        r = collectorB.last();
        CHECK((r.lastReasons & ABR_AUDIO_AFTER_OFFLINE) && std::fabs(r.integrated + 7.76f) < 0.05,
              "live audio after it is a break after offline (reasons 0x%x); integrated carries on (%.2f LUFS)", r.lastReasons,
              r.integrated);
        host.stop();
        abr_server_detach(server);
    }

    std::printf("Commands\n");
    {
        Collector controlled;
        findSource(server, "Stereo bus", a);
        abr_server_select(server, a.session_id);
        abr_server_attach(server, Collector::sink, &controlled);
        FakeHost host(*stereo, 2, 48000, 128);
        waitFor([&] { return controlled.count() > 30; }, 3);
        auto ack = [&](uint32_t id) {
            AbrSourceInfo info{};
            waitFor([&] { findSource(server, "Stereo bus", info); return info.last_ack_id == id; }, 2);
            return info;
        };
        const uint32_t generation = controlled.last().generation;
        uint32_t id = abr_server_command(server, a.session_id, ABR_COMMAND_PAUSE, 0);
        AbrSourceInfo info = ack(id);
        CHECK(id != 0 && info.last_ack_id == id && info.last_ack_outcome == ABR_ACK_DONE
                  && info.last_ack_measurement == ABR_MEASUREMENT_PAUSED,
              "pause: acknowledged (command %u, outcome %u, measurement %u)", id, info.last_ack_outcome, info.last_ack_measurement);
        std::this_thread::sleep_for(milliseconds(100));
        const Result paused = controlled.last();
        std::this_thread::sleep_for(milliseconds(500));
        CHECK(paused.measurement == ABR_MEASUREMENT_PAUSED && controlled.last().framesAnalysed == paused.framesAnalysed,
              "…nothing accumulates while paused, and the results say paused");
        CHECK(waitFor([&] { findSource(server, "Stereo bus", info); return info.measurement == ABR_MEASUREMENT_PAUSED; }, 1),
              "…and so does the status");
        id = abr_server_command(server, a.session_id, ABR_COMMAND_RESET_TRUE_PEAK, generation);
        info = ack(id);
        CHECK(info.last_ack_outcome == ABR_ACK_DONE && waitFor([&] {
            const Result reset = controlled.last();
            return reset.heldTruePeak[0] == 0 && reset.heldTruePeak[1] == 0
                && reset.framesAnalysed == paused.framesAnalysed && reset.measurement == ABR_MEASUREMENT_PAUSED;
        }, 2), "reset true peak while paused: zero reaches the display without more measured frames");
        id = abr_server_command(server, a.session_id, ABR_COMMAND_RESUME, generation);
        info = ack(id);
        waitFor([&] { return controlled.last().framesAnalysed > paused.framesAnalysed + 4800; }, 2);
        Result r = controlled.last();
        CHECK(info.last_ack_outcome == ABR_ACK_DONE && r.measurement == ABR_MEASUREMENT_MEASURING && r.generation == generation
                  && r.breaks == paused.breaks,
              "resume: carries on in the same generation without a break (%u breaks)", r.breaks);
        id = abr_server_command(server, a.session_id, ABR_COMMAND_RESET_TRUE_PEAK, 0);
        info = ack(id);
        CHECK(info.last_ack_outcome == ABR_ACK_DONE && info.last_ack_command == ABR_COMMAND_RESET_TRUE_PEAK, "reset true peak: acknowledged");
        id = abr_server_command(server, a.session_id, ABR_COMMAND_RESET, generation);
        info = ack(id);
        waitFor([&] { return controlled.last().generation == generation + 1 && controlled.last().framesAnalysed > 9600; }, 2);
        r = controlled.last();
        CHECK(info.last_ack_outcome == ABR_ACK_DONE && info.last_ack_generation == generation + 1 && r.generation == generation + 1
                  && r.framesAnalysed < 48000 && r.breaks == 0,
              "reset: a new generation %u measuring afresh (%.2f s analysed)", r.generation, r.framesAnalysed / 48000.0);
        id = abr_server_command(server, a.session_id, ABR_COMMAND_RESET, generation);
        info = ack(id);
        CHECK(info.last_ack_outcome == ABR_ACK_STALE_GENERATION && controlled.last().generation == generation + 1,
              "a command for an obsolete generation is refused (outcome %u) and changes nothing", info.last_ack_outcome);
        // A pause from the display ends with the display's connection.
        abr_server_command(server, a.session_id, ABR_COMMAND_PAUSE, 0);
        CHECK(waitFor([&] { return controlled.last().measurement == ABR_MEASUREMENT_PAUSED; }, 2), "paused again from the display");
        abr_server_disconnect(server, a.session_id, 300);
        CHECK(waitFor([&] { return stereo->status().measurement == ABR_MEASUREMENT_MEASURING; }, 2),
              "…and when that display's connection goes, the plugin resumes by itself");
        waitFor([&] { findSource(server, "Stereo bus", a); return stereo->status().connected; }, 3);
        stereo->requestCommand(ABR_COMMAND_PAUSE);
        CHECK(waitFor([&] { return stereo->status().measurement == ABR_MEASUREMENT_PAUSED; }, 2),
              "the plugin window's own Pause pauses the same measurement");
        abr_server_disconnect(server, a.session_id, 300);
        std::this_thread::sleep_for(milliseconds(500));
        CHECK(stereo->status().measurement == ABR_MEASUREMENT_PAUSED, "…which a display's disconnection does not undo");
        stereo->requestCommand(ABR_COMMAND_RESUME);
        CHECK(waitFor([&] { return stereo->status().measurement == ABR_MEASUREMENT_MEASURING; }, 2), "…and its Resume resumes it");
        // Back to a connected, listed original before the next checks.
        waitFor([&] { return stereo->status().connected && findSource(server, "Stereo bus", a); }, 4);
        host.stop();
        abr_server_detach(server);
    }

    std::printf("Project state and identity\n");
    {
        const std::string saved = stereo->saveState();
        const std::string original = stereo->status().instanceTag;
        CHECK(saved.find("id=") != std::string::npos && saved.find("integrated") == std::string::npos,
              "the saved state holds the identity and name, no live measurement");
        {
            abr::BridgeCore copy(ABR_FORMAT_TEST);
            bool reassigned = false;
            CHECK(copy.restoreState(saved, &reassigned) && copy.sourceName() == "Stereo bus", "a copy restores the name");
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
        Collector collectorR;
        findSource(server, "Stereo bus", a);
        abr_server_select(server, a.session_id);
        abr_server_attach(server, Collector::sink, &collectorR);
        FakeHost host(*stereo, 2, 48000, 128);
        waitFor([&] { return collectorR.count() > 30; }, 3);
        const Result start = collectorR.last();
        stereo->setActive(false);
        stereo->configure(48000, 2, 1024);
        stereo->setActive(true);
        waitFor([&] { return collectorR.last().breaks > start.breaks; }, 2);
        Result r = collectorR.last();
        CHECK(r.generation == start.generation && r.breaks == start.breaks + 1 && (r.lastReasons & ABR_AUDIO_AFTER_RESTART),
              "reactivating with the same format keeps generation %u and counts a restart break (reasons 0x%x)", r.generation,
              r.lastReasons);
        uint32_t breaks = r.breaks;
        host.idleMs = 120;
        std::this_thread::sleep_for(milliseconds(400));
        CHECK(collectorR.last().breaks == breaks, "a 120 ms pause in processing is not a break");
        host.idleMs = 1000;
        std::this_thread::sleep_for(milliseconds(700));
        const Result idle = collectorR.last();
        CHECK((idle.flags & 1) && idle.peak[0] == 0, "while the host is idle the results fall to silence (idle flag, peak 0)");
        CHECK(waitFor([&] { return collectorR.last().breaks > breaks; }, 3), "a 1 s pause in processing is a break");
        r = collectorR.last();
        CHECK((r.lastReasons & ABR_AUDIO_AFTER_IDLE) && r.missing - start.missing >= 0.85 && r.missing - start.missing <= 1.35,
              "…as the host being idle, with the time missing (%.2f s)", r.missing - start.missing);
        breaks = r.breaks;
        const uint32_t jumps = stereo->status().transportJumps;
        host.jumpTo = 480000;
        std::this_thread::sleep_for(milliseconds(300));
        CHECK(stereo->status().transportJumps == jumps + 1 && collectorR.last().breaks == breaks,
              "a timeline jump is counted (%u) and is not a break in the signal", stereo->status().transportJumps);
        CHECK(waitFor([&] { findSource(server, "Stereo bus", a); return a.transport_jumps == jumps + 1; }, 2),
              "…and reaches the receiver in the status");
        CHECK(host.worstNs.load() < kWorstProcessNs, "worst process() %.1f µs", host.worstNs.load() / 1000.0);
        host.stop();
        abr_server_detach(server);
    }

    std::printf("Stale results after a quick re-selection\n");
    {
        Collector first, second;
        findSource(server, "Stereo bus", a);
        abr_server_select(server, a.session_id);
        abr_server_attach(server, Collector::sink, &first);
        FakeHost host(*stereo, 2, 48000, 128);
        waitFor([&] { return first.count() > 30; }, 3);
        first.sleepOnceMs = 400;  // the receiver thread stalls inside the sink: results pile up
        std::this_thread::sleep_for(milliseconds(150));
        const uint64_t staleBefore = a.results_stale;
        abr_server_select(server, nullptr);
        abr_server_select(server, a.session_id);
        const uint64_t positionAtSwitch = stereo->status().framesProcessed;
        abr_server_attach(server, Collector::sink, &second);
        waitFor([&] { return second.count() > 30; }, 3);
        host.stop();
        abr_server_detach(server);
        findSource(server, "Stereo bus", a);
        const auto results = second.all();
        uint32_t subscription = results.empty() ? 0 : results.front().subscription;
        bool oneSubscription = !results.empty(), forward = true;
        for (size_t i = 0; i < results.size(); ++i) {
            if (results[i].subscription != subscription) oneSubscription = false;
            if (i && results[i].timelineEnd < results[i - 1].timelineEnd) forward = false;
        }
        CHECK(oneSubscription && forward && results.front().timelineEnd + 4800 >= positionAtSwitch,
              "the new subscription gets only its own results, current from the start (%+.3f s at the switch) and never going back",
              (double(results.front().timelineEnd) - double(positionAtSwitch)) / 48000.0);
        std::printf("  info %llu results of the earlier subscription arrived after the switch and were dropped\n",
                    (unsigned long long)(a.results_stale - staleBefore));
    }

    std::printf("Labs away and back\n");
    {
        FakeHost host(*stereo, 2, 48000, 128);
        std::this_thread::sleep_for(milliseconds(200));
        const uint32_t generation = stereo->status().analysis.generation;
        abr_server_stop(server);
        CHECK(waitFor([&] { return !stereo->status().connected; }, 2), "plugin notices Auraliscope Labs is gone");
        const uint64_t analysedBefore = stereo->status().analysis.frames_analysed;
        std::this_thread::sleep_for(milliseconds(1500));
        const uint64_t analysedAway = stereo->status().analysis.frames_analysed;
        CHECK(analysedAway > analysedBefore + 48000 && host.worstNs.load() < kWorstProcessNs,
              "the insert goes on measuring with Labs gone (%.2f s more)", (analysedAway - analysedBefore) / 48000.0);
        server = abr_server_start(nullptr, error, sizeof error);
        CHECK(server != nullptr, "receiver restarts on the same path");
        CHECK(waitFor([&] { return findSource(server, "Stereo bus", a) && stereo->status().connected; }, 3),
              "plugin reconnects within the retry interval");
        Collector again;
        abr_server_select(server, a.session_id);
        abr_server_attach(server, Collector::sink, &again);
        CHECK(waitFor([&] { return again.count() > 10; }, 3), "results resume after reconnection");
        const Result r = again.all().front();
        CHECK(r.generation == generation && r.framesAnalysed >= analysedAway && std::fabs(r.integrated + 7.76f) < 0.05,
              "the first result is the coherent current state: same generation %u, %.2f s analysed, integrated %.2f LUFS",
              r.generation, r.framesAnalysed / 48000.0, r.integrated);
        host.stop();
        abr_server_detach(server);
    }

    std::printf("Resources\n");
    {
        // Eight more inserts playing 48 kHz stereo at real time, on top of the two above.
        const uint64_t before = footprint();
        std::vector<std::unique_ptr<abr::BridgeCore>> cores;
        std::vector<std::unique_ptr<FakeHost>> hosts;
        for (int i = 0; i < 8; ++i) {
            cores.push_back(std::make_unique<abr::BridgeCore>(ABR_FORMAT_TEST));
            cores.back()->configure(48000, 2, 256);
            cores.back()->setActive(true);
        }
        for (auto &core : cores) hosts.push_back(std::make_unique<FakeHost>(*core, 2, 48000, 256));
        std::this_thread::sleep_for(milliseconds(1000));
        const uint64_t busyStart = abr::analysisBusyNs();
        const auto wallStart = steady_clock::now();
        std::this_thread::sleep_for(milliseconds(4000));
        const double busy = double(abr::analysisBusyNs() - busyStart) / 1e9;
        const double wall = duration<double>(steady_clock::now() - wallStart).count();
        const uint64_t after = footprint();
        int64_t worst = 0;
        uint64_t unanalysed = 0;
        for (auto &h : hosts) worst = std::max<int64_t>(worst, h->worstNs.load());
        for (auto &h : hosts) h->stop();
        for (auto &c : cores) unanalysed += c->status().framesDropped;
        std::printf("  info analysis thread busy %.1f%% of one core for 8 inserts (%.2f%% each); memory %+.1f MB (%.2f MB each)\n",
                    100 * busy / wall, 100 * busy / wall / 8, (double(after) - double(before)) / 1048576.0,
                    (double(after) - double(before)) / 1048576.0 / 8);
        CHECK(busy / wall < 0.5 && unanalysed == 0 && worst < kWorstProcessNs,
              "8 inserts are analysed in real time with nothing unanalysed; worst process() %.1f µs", worst / 1000.0);
    }

    std::printf("Removal\n");
    {
        mono.reset();
        CHECK(waitFor([&] { AbrSourceInfo x; return !findSource(server, "Vocal", x); }, 2),
              "a destroyed instance disappears from the list at once");
    }

    std::printf("Protocol versions\n");
    {
        // Plugins of earlier versions connecting to this receiver: version 1 (build 1) and version 2 (build 2).
        for (uint32_t version = 1; version <= 2; ++version) {
            const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
            sockaddr_un address{};
            address.sun_family = AF_UNIX;
            std::snprintf(address.sun_path, sizeof address.sun_path, "%s", path);
            const bool connected = connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof address) == 0;
            uint8_t hello[sizeof(AbrHeader) + 256] = {};
            const AbrHeader header{ABR_MAGIC, ABR_MSG_HELLO, 0, 256, 0};
            const uint32_t words[2] = {version, ABR_FORMAT_VST3};
            std::memcpy(hello, &header, sizeof header);
            std::memcpy(hello + sizeof header, words, sizeof words);
            send(fd, hello, sizeof hello, 0);
            AbrSourceInfo old{};
            CHECK(connected && waitFor([&] {
                      for (const auto &info : sources(server))
                          if (info.protocol_version == version && !info.compatible) { old = info; return true; }
                      return false;
                  }, 2),
                  "a version %u plugin is listed as incompatible (protocol %u, format %u)", version, old.protocol_version,
                  old.plugin_format);
            pollfd waiting{fd, POLLIN, 0};
            const bool answered = poll(&waiting, 1, 300) > 0;
            uint8_t reply[64] = {};
            if (answered) recv(fd, reply, sizeof reply, 0);
            if (version == 1) {
                CHECK(!answered, "…version 1 hears nothing back, so it stays connected instead of reconnecting every second");
            } else {
                CHECK(answered && abr_get32(reply + sizeof(AbrHeader)) == ABR_PROTOCOL_VERSION,
                      "…version 2 is told this receiver's version, so it can say it needs an update");
            }
            close(fd);
        }
        CHECK(waitFor([&] {
                  for (const auto &info : sources(server)) if (!info.compatible) return false;
                  return true;
              }, 2),
              "…and they leave the list when they disconnect");

        // This plugin meeting receivers it cannot work with (Labs build 2, protocol 2), and a raw version 3 one
        // that sends a command naming another instance.
        char oldPath[256];
        std::snprintf(oldPath, sizeof oldPath, "%s/old.sock", folder);
        {
            RawReceiver old(oldPath);
            std::atomic<int> accepted{0};
            std::atomic<bool> serving{true};
            std::thread thread([&] {
                while (serving.load()) {
                    pollfd ready{old.listener, POLLIN, 0};
                    if (poll(&ready, 1, 50) <= 0) continue;
                    const int client = accept(old.listener, nullptr, nullptr);
                    if (client < 0) continue;
                    ++accepted;
                    uint8_t buffer[4096];
                    recv(client, buffer, sizeof buffer, 0);
                    const uint32_t welcome[2] = {2, 0};
                    RawReceiver::send(client, ABR_MSG_WELCOME, welcome, sizeof welcome);
                    close(client);
                }
            });
            setenv("AURALISCOPE_BRIDGE_SOCKET", oldPath, 1);
            auto newer = std::make_unique<abr::BridgeCore>(ABR_FORMAT_TEST);
            CHECK(waitFor([&] { return newer->status().receiverTooOld; }, 3) && !newer->status().connected,
                  "the plugin recognises an older receiver (protocol 2) and does not count it as connected");
            const int attempts = accepted.load();
            std::this_thread::sleep_for(milliseconds(3000));
            CHECK(accepted.load() == attempts, "…and does not retry every second (%d attempt(s) in 3 s)", accepted.load() - attempts);
            newer.reset();
            serving = false;
            thread.join();
        }
        {
            RawReceiver raw(oldPath);
            auto target = std::make_unique<abr::BridgeCore>(ABR_FORMAT_TEST);
            target->configure(48000, 2, 256);
            target->setActive(true);
            pollfd ready{raw.listener, POLLIN, 0};
            const int client = poll(&ready, 1, 3000) > 0 ? accept(raw.listener, nullptr, nullptr) : -1;
            uint8_t welcome[64];
            abr_put32(welcome, ABR_PROTOCOL_VERSION);
            abr_put32(welcome + 4, 0);
            RawReceiver::send(client, ABR_MSG_WELCOME, welcome, 8);
            uint8_t command[96];
            AbrWriter w = abr_writer(command, sizeof command);
            abr_put_u32(&w, ABR_COMMAND_ID, 77);
            abr_put_u32(&w, ABR_COMMAND_CODE, ABR_COMMAND_RESET);
            uint8_t other[16];
            std::memset(other, 0xAB, sizeof other);
            abr_put_bytes(&w, ABR_COMMAND_SESSION_ID, other, 16);
            RawReceiver::send(client, ABR_MSG_COMMAND, command, uint32_t(w.used));
            uint32_t outcome = 999;
            const auto end = steady_clock::now() + seconds(3);
            std::vector<uint8_t> in;
            while (steady_clock::now() < end && outcome == 999) {
                pollfd readable{client, POLLIN, 0};
                if (poll(&readable, 1, 50) <= 0) continue;
                uint8_t buffer[4096];
                const ssize_t n = recv(client, buffer, sizeof buffer, 0);
                if (n <= 0) break;
                in.insert(in.end(), buffer, buffer + n);
                size_t offset = 0;
                while (in.size() - offset >= sizeof(AbrHeader)) {
                    AbrHeader header;
                    std::memcpy(&header, in.data() + offset, sizeof header);
                    if (in.size() - offset < sizeof header + header.length) break;
                    if (header.type == ABR_MSG_ACK) {
                        AbrReader reader = abr_reader(in.data() + offset + sizeof header, header.length);
                        AbrField f;
                        uint32_t id = 0, value = 0;
                        bool haveOutcome = false;
                        while (abr_next_field(&reader, &f)) {
                            if (f.tag == ABR_ACK_COMMAND_ID) abr_field_u32(&f, &id);
                            if (f.tag == ABR_ACK_OUTCOME) haveOutcome = abr_field_u32(&f, &value);
                        }
                        if (id == 77 && haveOutcome) outcome = value;
                    }
                    offset += sizeof header + header.length;
                }
                in.erase(in.begin(), in.begin() + offset);
            }
            CHECK(outcome == ABR_ACK_WRONG_SESSION, "a command naming another instance is refused (outcome %u)", outcome);
            close(client);
            target.reset();
        }
        setenv("AURALISCOPE_BRIDGE_SOCKET", path, 1);
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
    CHECK(!abr::senderRunning() && !abr::analysisRunning(),
          "no thread is left once every instance is gone (the binary can be unloaded)");
    abr_server_stop(server);
    rmdir(folder);
    std::printf(failures ? "\n%d check(s) FAILED\n" : "\nAll transport checks passed\n", failures);
    return failures ? 1 : 0;
}
