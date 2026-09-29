#include <condition_variable>
#include <mutex>
#include <pthread.h>
#include <thread>
#include <time.h>
#include <vector>

#include "BridgeCore.h"

// One sender thread per loaded plugin binary. It wakes every kIntervalMs, and for each instance: connects when
// needed (at most once a second), reads Auraliscope's subscribe requests, sends status, and moves queued audio
// to the socket. Every socket is non-blocking, so a stalled Auraliscope delays nothing but its own data.

namespace abr {
namespace {
constexpr auto kInterval = std::chrono::milliseconds(5);

struct Hub {
    std::mutex lock;                 // held while instances are serviced; never taken by an audio thread
    std::condition_variable wake;
    std::vector<BridgeCore *> cores;
    std::thread thread;
    bool stopping = false;

    void run() {
        pthread_setname_np("Auraliscope Bridge sender");
        std::unique_lock<std::mutex> guard(lock);
        while (!stopping) {
            const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            for (BridgeCore *core : cores) core->service(now);
            wake.wait_for(guard, kInterval);
        }
    }
};

Hub &hub() {
    static Hub *instance = new Hub;  // never destroyed: static destructors may run while a host still unloads
    return *instance;
}
}  // namespace

void registerCore(BridgeCore *core) {
    Hub &h = hub();
    std::thread finished;
    {
        std::lock_guard<std::mutex> guard(h.lock);
        h.cores.push_back(core);
        if (h.cores.size() == 1) {
            if (h.thread.joinable()) finished = std::move(h.thread);  // a stop that is still winding down
            h.stopping = false;
        }
    }
    if (finished.joinable()) finished.join();
    std::lock_guard<std::mutex> guard(h.lock);
    if (!h.thread.joinable() && !h.cores.empty()) {
        h.stopping = false;
        h.thread = std::thread([&h] { h.run(); });
    }
}

void unregisterCore(BridgeCore *core) {
    Hub &h = hub();
    std::thread finished;
    {
        std::lock_guard<std::mutex> guard(h.lock);
        for (auto it = h.cores.begin(); it != h.cores.end(); ++it) {
            if (*it == core) { h.cores.erase(it); break; }
        }
        if (h.cores.empty() && h.thread.joinable()) {
            h.stopping = true;
            finished = std::move(h.thread);
        }
    }
    h.wake.notify_all();
    if (finished.joinable()) finished.join();
}

}  // namespace abr
