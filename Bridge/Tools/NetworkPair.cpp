// Pairs this Mac with an Auraliscope display on the network, with the plugin's own pairing code (BridgeRemote.cpp),
// for tests and for setting up a host without opening the plugin window. Uses the same store as the plugins
// (~/Library/Application Support/Auraliscope Bridge, or the folder of AURALISCOPE_BRIDGE_SOCKET when set).
//
//   NetworkPair --list                                 receivers found on the network, and the paired ones
//   NetworkPair --pair "<service name>" --code ABCD-EFGH   pairs (approve on the display), prints the receiver ID
//   NetworkPair --forget <receiver ID>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

#include "BridgeRemote.h"
extern "C" {
#include "BridgeDiscovery.h"
}

static uint32_t browse(AbrBrowser *browser, AbrPeer *peers, uint32_t capacity, double seconds) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    uint32_t count = 0;
    while (std::chrono::steady_clock::now() < end) {
        count = abr_browser_peers(browser, peers, capacity);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return count < capacity ? count : capacity;
}

int main(int argc, char **argv) {
    std::string action, service, code, id;
    for (int i = 1; i < argc; ++i) {
        const std::string key = argv[i];
        if (key == "--list") action = "list";
        else if (key == "--pair" && i + 1 < argc) { action = "pair"; service = argv[++i]; }
        else if (key == "--code" && i + 1 < argc) code = argv[++i];
        else if (key == "--forget" && i + 1 < argc) { action = "forget"; id = argv[++i]; }
    }
    if (action == "forget") { abr::forgetReceiver(id); std::printf("forgot %s\n", id.c_str()); return 0; }
    if (action.empty()) { std::fprintf(stderr, "usage: NetworkPair --list | --pair <name> --code <code> | --forget <id>\n"); return 2; }
    AbrBrowser *browser = abr_browser_start();
    if (!browser) { std::fprintf(stderr, "DNS-SD unavailable\n"); return 1; }
    AbrPeer peers[32];
    const uint32_t count = browse(browser, peers, 32, 3);
    if (abr_browser_error(browser)) std::fprintf(stderr, "browse error %d\n", abr_browser_error(browser));
    if (action == "list") {
        for (uint32_t i = 0; i < count; ++i) {
            const AbrPeer &p = peers[i];
            std::printf("%s\thost=%s port=%u proto=%u schema=%u platform=%s role=%s transport=%s rid=%s pair=%u\n", p.name,
                        p.host, p.port, p.protocol, p.schema, p.platform, p.role, p.transport, p.receiver_id, p.pairing_port);
        }
        for (const abr::PairedReceiver &r : abr::pairedReceivers())
            std::printf("paired\t%s\t%s\t%s\n", r.id.c_str(), r.name.c_str(), r.serviceName.c_str());
        abr_browser_stop(browser);
        return 0;
    }
    const AbrPeer *target = nullptr;
    for (uint32_t i = 0; i < count; ++i) if (service == peers[i].name && peers[i].resolved) target = &peers[i];
    if (!target || !target->pairing_port) {
        std::fprintf(stderr, "no receiver \"%s\" with pairing open\n", service.c_str());
        abr_browser_stop(browser);
        return 1;
    }
    abr::PairingJob job(target->host, target->pairing_port, target->receiver_id, target->name, code, "NetworkPair", "test");
    abr_browser_stop(browser);
    abr::PairingJob::Phase last = abr::PairingJob::Phase::connecting;
    while (job.phase() == abr::PairingJob::Phase::connecting || job.phase() == abr::PairingJob::Phase::waitingForApproval) {
        if (job.phase() != last) { last = job.phase(); std::printf("waiting for approval on the display…\n"); std::fflush(stdout); }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    std::printf("%s\n", job.message().c_str());
    if (job.phase() != abr::PairingJob::Phase::paired) return 1;
    std::printf("receiver %s\n", job.receiverID().c_str());
    return 0;
}
