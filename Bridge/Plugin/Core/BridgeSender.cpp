#include <array>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <pthread.h>
#include <thread>
#include <time.h>
#include <utility>
#include <vector>

#include "BridgeCore.h"

// One sender thread per loaded plugin binary. It wakes every kIntervalMs, and for each instance: connects when
// needed (at most once a second), reads Auraliscope's subscribe requests, sends status, and moves queued audio
// to the socket. Every socket is non-blocking, so a stalled Auraliscope delays nothing but its own data.

namespace abr {
namespace {
constexpr auto kInterval = std::chrono::milliseconds(5);

struct Hub {
    // Serialises starting and stopping the thread, so a registration can never meet a thread that is still
    // winding down. The sender thread never takes it.
    std::mutex lifecycle;
    std::mutex lock;                 // the instance list; held while instances are serviced; never taken by an audio thread
    std::condition_variable wake;
    std::vector<BridgeCore *> cores;
    std::thread thread;
    bool stopping = false;           // guarded by `lock`

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

struct Identities {
    std::mutex lock;
    std::vector<std::pair<const BridgeCore *, std::array<uint8_t, 16>>> claims;
};

Identities &identities() {
    static Identities *instance = new Identities;  // as the hub: outlives every instance
    return *instance;
}
}  // namespace

void registerCore(BridgeCore *core) {
    Hub &h = hub();
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
            // No thread (the system is out of resources): the instance still passes audio through, unconnected.
        }
    }
}

void unregisterCore(BridgeCore *core) {
    Hub &h = hub();
    std::lock_guard<std::mutex> life(h.lifecycle);
    bool last;
    {
        std::lock_guard<std::mutex> guard(h.lock);
        for (auto it = h.cores.begin(); it != h.cores.end(); ++it) {
            if (*it == core) { h.cores.erase(it); break; }
        }
        last = h.cores.empty();
        if (last) h.stopping = true;
    }
    if (last && h.thread.joinable()) {
        h.wake.notify_all();
        h.thread.join();  // it exits at its next check of `stopping`, within one interval
    }
}

bool senderRunning() {
    Hub &h = hub();
    std::lock_guard<std::mutex> life(h.lifecycle);
    return h.thread.joinable();
}

bool claimIdentity(const BridgeCore *core, const uint8_t id[16]) {
    Identities &registry = identities();
    std::lock_guard<std::mutex> guard(registry.lock);
    for (const auto &claim : registry.claims)
        if (claim.first != core && std::memcmp(claim.second.data(), id, 16) == 0) return false;
    for (auto &claim : registry.claims) {
        if (claim.first == core) {
            std::memcpy(claim.second.data(), id, 16);
            return true;
        }
    }
    std::array<uint8_t, 16> value;
    std::memcpy(value.data(), id, 16);
    registry.claims.emplace_back(core, value);
    return true;
}

void releaseIdentity(const BridgeCore *core) {
    Identities &registry = identities();
    std::lock_guard<std::mutex> guard(registry.lock);
    for (auto it = registry.claims.begin(); it != registry.claims.end(); ++it) {
        if (it->first == core) { registry.claims.erase(it); return; }
    }
}

}  // namespace abr
