#include <pthread.h>
#include <pthread/qos.h>
#include <time.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

#include "BridgeCore.h"

// One analysis thread per loaded plugin binary, shared by every instance. It never runs on, waits for, or is waited
// for by a host's audio thread: the audio threads only fill each instance's ring.
//
// Scheduling, per pass (every kInterval):
//   - every instance is visited, starting one further along each pass, so none is always served last;
//   - an instance analyses at most kSliceSeconds of its queued audio per visit (a large host block, a high sample
//     rate or a backlog cannot hold the others up; the rest waits for the next pass);
//   - a pass stops early after kPassBudget of work, and the next pass starts where it stopped.
// The thread runs at the user-initiated QoS, below the host's real-time audio threads, so analysis load can delay
// only analysis. If it falls behind for longer than an instance's ring holds (about 2.7 s at 48 kHz stereo), the
// audio thread drops the newest audio from the analysis (never from the output) and the analysis marks a break.

namespace abr {
namespace {
constexpr auto kInterval = std::chrono::milliseconds(5);
constexpr double kSliceSeconds = 0.05;
constexpr uint64_t kPassBudgetNs = 8000000;  // 8 ms

struct AnalysisHub {
    std::mutex lifecycle;            // serialises starting and stopping the thread
    std::mutex lock;                 // the instance list; held while instances are analysed
    std::condition_variable wake;
    std::vector<BridgeCore *> cores;
    std::thread thread;
    bool stopping = false;
    size_t next = 0;
    std::atomic<uint64_t> busyNs{0};
    std::atomic<uint64_t> passes{0};
    std::atomic<bool> held{false};   // tests: the thread skips its passes, as if starved of CPU

    void run() {
        pthread_setname_np("Auraliscope Bridge analysis");
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
        std::unique_lock<std::mutex> guard(lock);
        while (!stopping) {
            if (held.load(std::memory_order_relaxed)) {
                wake.wait_for(guard, kInterval);
                continue;
            }
            const uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            const size_t count = cores.size();
            for (size_t i = 0; i < count; ++i) {
                const size_t index = (next + i) % count;
                cores[index]->analyse(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), kSliceSeconds);
                if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start > kPassBudgetNs && i + 1 < count) {
                    next = (index + 1) % count;  // over budget: the next pass starts with the one not reached
                    goto done;
                }
            }
            next = count ? (next + 1) % count : 0;
        done:
            busyNs.fetch_add(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start, std::memory_order_relaxed);
            passes.fetch_add(1, std::memory_order_relaxed);
            wake.wait_for(guard, kInterval);
        }
    }
};

AnalysisHub &hub() {
    static AnalysisHub *instance = new AnalysisHub;  // never destroyed: static destructors may run while a host unloads
    return *instance;
}
}  // namespace

void registerAnalysis(BridgeCore *core) {
    AnalysisHub &h = hub();
    std::lock_guard<std::mutex> life(h.lifecycle);
    {
        std::lock_guard<std::mutex> guard(h.lock);
        h.cores.push_back(core);
        h.stopping = false;
    }
    if (!h.thread.joinable()) {
        try {
            h.thread = std::thread([&h] { h.run(); });
        } catch (...) {
            // No thread (the system is out of resources): the instance still passes audio through, unanalysed.
        }
    }
}

void unregisterAnalysis(BridgeCore *core) {
    AnalysisHub &h = hub();
    std::lock_guard<std::mutex> life(h.lifecycle);
    bool last;
    {
        // Taking the lock waits for a pass in progress: after this, the thread never touches `core` again.
        std::lock_guard<std::mutex> guard(h.lock);
        h.cores.erase(std::remove(h.cores.begin(), h.cores.end(), core), h.cores.end());
        last = h.cores.empty();
        if (last) h.stopping = true;
        h.next = 0;
    }
    if (last && h.thread.joinable()) {
        h.wake.notify_all();
        h.thread.join();
    }
}

bool analysisRunning() {
    AnalysisHub &h = hub();
    std::lock_guard<std::mutex> life(h.lifecycle);
    return h.thread.joinable();
}

uint64_t analysisBusyNs() { return hub().busyNs.load(std::memory_order_relaxed); }

void holdAnalysisForTesting(bool held) { hub().held.store(held, std::memory_order_relaxed); }

}  // namespace abr
