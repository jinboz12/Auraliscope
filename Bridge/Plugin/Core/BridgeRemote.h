#pragma once

// Auraliscope displays on other devices (Bridge/BRIDGE_NETWORK.md): this Mac's pairing identity, the receivers it is
// paired with, and the pairing itself. Shared by every plugin instance of this user on this Mac.
//
//   ~/Library/Application Support/Auraliscope Bridge/        0700 (the folder the local socket lives in)
//     network-device-id                                      0600: this Mac's pairing ID, 32 hex digits
//     Receivers/<receiver ID>.pairing                        0600: name, service name and key of one receiver
//
// Nothing here runs on the host's audio thread; the pairing runs on a thread of its own.

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace abr {

struct PairedReceiver {
    std::string id;           // 32 hex digits (TXT rid)
    std::string name;         // as the receiver named itself when paired
    std::string serviceName;  // its DNS-SD service name, to connect by
    uint8_t key[32] = {};
};

// This Mac's pairing ID (created on first use) and name.
bool networkDeviceID(uint8_t id[16]);
std::string computerName();

std::vector<PairedReceiver> pairedReceivers();
bool findReceiver(const std::string &id, PairedReceiver *out);
bool saveReceiver(const PairedReceiver &receiver);
void forgetReceiver(const std::string &id);

// One pairing attempt with a receiver whose pairing listener is open (TXT pair=<port>).
class PairingJob {
public:
    enum class Phase { connecting, waitingForApproval, paired, failed };
    PairingJob(const std::string &host, uint16_t port, const std::string &receiverID, const std::string &serviceName,
               const std::string &code, const std::string &hostName, const std::string &pluginVersion);
    ~PairingJob();   // cancels and waits for the thread (at most about 100 ms)
    Phase phase() const { return phase_.load(); }
    std::string message() const;
    const std::string &receiverID() const { return receiverID_; }

private:
    void run(std::string host, uint16_t port, std::string code, std::string hostName, std::string pluginVersion);
    std::atomic<Phase> phase_{Phase::connecting};
    std::atomic<bool> cancelled_{false};
    mutable std::mutex lock_;
    std::string message_;
    std::string receiverID_, serviceName_;
    std::thread thread_;
};

}  // namespace abr
