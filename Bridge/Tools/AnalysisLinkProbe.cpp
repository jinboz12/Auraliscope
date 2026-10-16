// Feasibility probe for plugin-side analysis (not shipped). Two roles, one source file:
//
//   built with -DABR_PROBE_LIBRARY: a loadable bundle standing in for one plugin binary, linked with that format's
//   analysis library (Bridge/scripts/build-analysis-lib.sh); it exports `probe_run`, which drives the Swift core
//   through the C interface of BridgeAnalysis.h on a background thread, as the plugin does.
//
//   built without: a host that dlopens two such bundles (the VST3 and the AU analysis libraries) into one process,
//   runs both at once, and reports timing, the numbers measured and any Objective-C class clash.
//
//   AnalysisLinkProbe <bundle-a> <bundle-b> [seconds] [rate] [channels]

#include <dlfcn.h>
#include <mach/mach_time.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "BridgeAnalysis.h"

#ifdef ABR_PROBE_LIBRARY
extern "C" __attribute__((visibility("default"))) int probe_run(double rate, int channels, double seconds, char *report,
                                                                 size_t size) {
    AbrAnalyzer *a = abr_analyzer_create(rate, uint32_t(channels), 1, 1);
    if (!a) return 1;
    const uint32_t block = 512;
    std::vector<float> buffer(block * channels);
    std::vector<uint8_t> out(128 * 1024);
    const uint64_t total = uint64_t(rate * seconds);
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    uint64_t busy = 0, worst = 0, encodeBusy = 0, bytes = 0, results = 0;
    uint64_t spec = 0, wave = 0;
    for (uint64_t n = 0; n < total; n += block) {
        for (uint32_t i = 0; i < block; ++i) {
            const double t = double(n + i) / rate;
            buffer[i * channels] = float(0.5 * std::sin(2 * M_PI * 997 * t));
            if (channels > 1) buffer[i * channels + 1] = float(0.25 * std::sin(2 * M_PI * 1499 * t));
        }
        const uint64_t start = mach_absolute_time();
        const uint64_t before = abr_analyzer_ticks(a);
        abr_analyzer_consume(a, buffer.data(), block, n, double(n) / rate);
        const uint64_t mid = mach_absolute_time();
        if (abr_analyzer_ticks(a) != before) {
            uint64_t s = 0, w = 0;
            bytes += abr_analyzer_encode(a, out.data(), uint32_t(out.size()), 1, uint32_t(channels), spec, wave, &s, &w);
            spec = s;
            wave = w;
            ++results;
        }
        const uint64_t end = mach_absolute_time();
        busy += mid - start;
        encodeBusy += end - mid;
        if (end - start > worst) worst = end - start;
    }
    AbrAnalysisSummary s;
    abr_analyzer_summary(a, &s);
    abr_analyzer_destroy(a);
    const double ns = double(tb.numer) / tb.denom;
    std::snprintf(report, size,
                  "%.0f Hz %d ch, %.0f s: analysis %.2f%% of real time, encode %.2f%%, worst call %.0f us; "
                  "%llu results, %.1f KB each; peak %.3f dBFS, integrated %.2f LUFS, ticks %llu",
                  rate, channels, seconds, 100.0 * busy * ns / (seconds * 1e9), 100.0 * encodeBusy * ns / (seconds * 1e9),
                  worst * ns / 1e3, (unsigned long long)results, results ? bytes / 1024.0 / results : 0.0,
                  20 * std::log10(std::max(1e-9f, s.peak[0])), s.integrated, (unsigned long long)s.ticks);
    return 0;
}
#else
int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <bundle-a> <bundle-b> [seconds] [rate] [channels]\n", argv[0]);
        return 2;
    }
    const double seconds = argc > 3 ? std::atof(argv[3]) : 20;
    const double rate = argc > 4 ? std::atof(argv[4]) : 48000;
    const int channels = argc > 5 ? std::atoi(argv[5]) : 2;
    using Run = int (*)(double, int, double, char *, size_t);
    Run runs[2];
    for (int i = 0; i < 2; ++i) {
        void *handle = dlopen(argv[1 + i], RTLD_NOW | RTLD_LOCAL);
        if (!handle) { std::fprintf(stderr, "dlopen %s: %s\n", argv[1 + i], dlerror()); return 1; }
        runs[i] = reinterpret_cast<Run>(dlsym(handle, "probe_run"));
        if (!runs[i]) { std::fprintf(stderr, "no probe_run in %s\n", argv[1 + i]); return 1; }
    }
    char reports[2][512] = {};
    int status[2] = {};
    std::thread threads[2];
    for (int i = 0; i < 2; ++i)
        threads[i] = std::thread([&, i] { status[i] = runs[i](rate, channels, seconds, reports[i], sizeof reports[i]); });
    for (auto &t : threads) t.join();
    for (int i = 0; i < 2; ++i) std::printf("%s: %s\n", i ? "B" : "A", status[i] ? "failed" : reports[i]);
    return status[0] || status[1];
}
#endif
