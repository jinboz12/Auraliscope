#include "BridgeRemote.h"

#include <SystemConfiguration/SystemConfiguration.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>

#include "BridgeNetLink.h"
#include "BridgePaths.h"
#include "BridgeProtocol.h"
#include "BridgeWire.h"

namespace abr {

namespace {
std::mutex gStoreLock;   // one writer at a time among this process's instances

std::string hex(const uint8_t *bytes, size_t count) {
    static const char digits[] = "0123456789abcdef";
    std::string text;
    for (size_t i = 0; i < count; ++i) {
        text.push_back(digits[bytes[i] >> 4]);
        text.push_back(digits[bytes[i] & 15]);
    }
    return text;
}

bool unhex(const std::string &text, uint8_t *bytes, size_t count) {
    if (text.size() != count * 2) return false;
    for (size_t i = 0; i < count; ++i) {
        unsigned value;
        if (std::sscanf(text.c_str() + 2 * i, "%2x", &value) != 1) return false;
        bytes[i] = uint8_t(value);
    }
    return true;
}

bool validID(const std::string &id) {
    if (id.size() != 32) return false;
    for (char c : id) if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
    return true;
}

std::string folder() {
    char path[1024];
    if (abr_socket_folder(path, sizeof path) != 0) return "";
    mkdir(path, 0700);
    return path;
}

// Writes `contents` to `path` with mode 0600, replacing it atomically.
bool writePrivate(const std::string &path, const std::string &contents) {
    const std::string temporary = path + ".tmp";
    const int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return false;
    const bool ok = write(fd, contents.data(), contents.size()) == ssize_t(contents.size());
    fchmod(fd, 0600);
    close(fd);
    return ok && rename(temporary.c_str(), path.c_str()) == 0;
}

std::string readSmall(const std::string &path) {
    std::ifstream file(path);
    std::stringstream text;
    text << file.rdbuf();
    std::string s = text.str();
    return s.size() > 4096 ? std::string() : s;
}

std::string clean(const std::string &text, size_t limit) {
    std::string out;
    for (unsigned char c : text) if (c >= 0x20 && c != 0x7F && c != '\n') out.push_back(char(c));
    if (out.size() > limit) {
        size_t cut = limit;
        while (cut > 0 && (static_cast<unsigned char>(out[cut]) & 0xC0) == 0x80) --cut;
        out.resize(cut);
    }
    return out;
}

bool parseReceiver(const std::string &text, PairedReceiver *out) {
    if (text.rfind("AuraliscopeBridgeReceiver 1\n", 0) != 0) return false;
    PairedReceiver receiver;
    bool haveKey = false;
    std::istringstream lines(text);
    std::string line;
    while (std::getline(lines, line)) {
        if (line.rfind("id=", 0) == 0) receiver.id = line.substr(3);
        else if (line.rfind("name=", 0) == 0) receiver.name = line.substr(5);
        else if (line.rfind("service=", 0) == 0) receiver.serviceName = line.substr(8);
        else if (line.rfind("key=", 0) == 0) haveKey = unhex(line.substr(4), receiver.key, 32);
    }
    if (!validID(receiver.id) || !haveKey || receiver.serviceName.empty()) return false;
    *out = receiver;
    return true;
}
}  // namespace

bool networkDeviceID(uint8_t id[16]) {
    std::lock_guard<std::mutex> guard(gStoreLock);
    const std::string base = folder();
    if (base.empty()) return false;
    const std::string path = base + "/network-device-id";
    std::string text = readSmall(path);
    while (!text.empty() && (text.back() == '\n' || text.back() == ' ')) text.pop_back();
    if (unhex(text, id, 16)) return true;
    arc4random_buf(id, 16);
    return writePrivate(path, hex(id, 16) + "\n");
}

std::string computerName() {
    CFStringRef name = SCDynamicStoreCopyComputerName(nullptr, nullptr);
    char text[128] = "";
    if (name) {
        CFStringGetCString(name, text, sizeof text, kCFStringEncodingUTF8);
        CFRelease(name);
    }
    if (!*text) gethostname(text, sizeof text);
    return clean(text, 63);
}

std::vector<PairedReceiver> pairedReceivers() {
    std::lock_guard<std::mutex> guard(gStoreLock);
    std::vector<PairedReceiver> list;
    const std::string base = folder();
    if (base.empty()) return list;
    DIR *dir = opendir((base + "/Receivers").c_str());
    if (!dir) return list;
    while (dirent *entry = readdir(dir)) {
        const std::string file = entry->d_name;
        if (file.size() != 32 + 8 || file.compare(32, 8, ".pairing") != 0) continue;
        PairedReceiver receiver;
        if (parseReceiver(readSmall(base + "/Receivers/" + file), &receiver)) list.push_back(receiver);
    }
    closedir(dir);
    return list;
}

bool findReceiver(const std::string &id, PairedReceiver *out) {
    if (!validID(id)) return false;
    for (const PairedReceiver &receiver : pairedReceivers()) {
        if (receiver.id == id) { *out = receiver; return true; }
    }
    return false;
}

bool saveReceiver(const PairedReceiver &receiver) {
    if (!validID(receiver.id)) return false;
    std::lock_guard<std::mutex> guard(gStoreLock);
    const std::string base = folder();
    if (base.empty()) return false;
    mkdir((base + "/Receivers").c_str(), 0700);
    return writePrivate(base + "/Receivers/" + receiver.id + ".pairing",
                        "AuraliscopeBridgeReceiver 1\nid=" + receiver.id + "\nname=" + clean(receiver.name, 63) + "\nservice="
                            + clean(receiver.serviceName, 63) + "\nkey=" + hex(receiver.key, 32) + "\n");
}

void forgetReceiver(const std::string &id) {
    if (!validID(id)) return;
    std::lock_guard<std::mutex> guard(gStoreLock);
    const std::string base = folder();
    if (!base.empty()) unlink((base + "/Receivers/" + id + ".pairing").c_str());
}

// ---- Pairing ---------------------------------------------------------------------------------------------------

PairingJob::PairingJob(const std::string &host, uint16_t port, const std::string &receiverID, const std::string &serviceName,
                       const std::string &code, const std::string &hostName, const std::string &pluginVersion)
    : receiverID_(receiverID), serviceName_(serviceName) {
    thread_ = std::thread([=] { run(host, port, code, hostName, pluginVersion); });
}

PairingJob::~PairingJob() {
    cancelled_.store(true);
    if (thread_.joinable()) thread_.join();
}

std::string PairingJob::message() const {
    std::lock_guard<std::mutex> guard(lock_);
    return message_;
}

void PairingJob::run(std::string host, uint16_t port, std::string code, std::string hostName, std::string pluginVersion) {
    pthread_setname_np("Auraliscope Bridge pairing");
    auto finish = [&](Phase phase, const std::string &message) {
        {
            std::lock_guard<std::mutex> guard(lock_);
            message_ = message;
        }
        phase_.store(phase);
    };
    uint8_t rid[16], key[32], device[16];
    if (!validID(receiverID_) || !unhex(receiverID_, rid, 16)) return finish(Phase::failed, "The receiver did not identify itself.");
    if (!pairingKey(code, rid, key)) return finish(Phase::failed, "A code is 8 letters and digits, as the iPad shows it.");
    if (!networkDeviceID(device)) return finish(Phase::failed, "This Mac's pairing identity could not be stored.");
    static const uint8_t identity[] = {'p', 'a', 'i', 'r'};
    std::unique_ptr<NetLink> link = NetLink::toHost(host, port, key, 32, identity, sizeof identity);
    const auto began = std::chrono::steady_clock::now();
    auto elapsed = [&] { return std::chrono::duration<double>(std::chrono::steady_clock::now() - began).count(); };
    while (link->state() == NetLink::State::connecting) {
        if (cancelled_.load()) return finish(Phase::failed, "Cancelled.");
        if (elapsed() > 10) return finish(Phase::failed, "The iPad did not answer. Is its pairing code still shown?");
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    if (link->state() != NetLink::State::ready) {
        const std::string error = link->error();
        return finish(Phase::failed, error.find("TLS") != std::string::npos ? "Wrong code: the iPad refused it." : error);
    }
    // PAIR_REQUEST
    uint8_t payload[256];
    AbrWriter w = abr_writer(payload, sizeof payload);
    abr_put_bytes(&w, ABR_PAIR_DEVICE_ID, device, 16);
    abr_put_text(&w, ABR_PAIR_COMPUTER_NAME, computerName().c_str(), 63);
    abr_put_text(&w, ABR_PAIR_HOST_NAME, clean(hostName, 63).c_str(), 63);
    abr_put_text(&w, ABR_PAIR_PLUGIN_VERSION, clean(pluginVersion, 31).c_str(), 31);
    uint8_t message[sizeof(AbrHeader) + sizeof payload];
    const AbrHeader header{ABR_MAGIC, ABR_MSG_PAIR_REQUEST, 0, uint32_t(w.used), 0};
    std::memcpy(message, &header, sizeof header);
    std::memcpy(message + sizeof header, payload, w.used);
    link->send(message, sizeof header + w.used);
    phase_.store(Phase::waitingForApproval);
    // PAIR_GRANT or PAIR_DENY, while the person decides on the iPad (at most two minutes).
    uint8_t in[4096];
    size_t used = 0;
    while (!cancelled_.load()) {
        used += link->receive(in + used, sizeof in - used);
        if (used >= sizeof(AbrHeader)) {
            AbrHeader reply;
            std::memcpy(&reply, in, sizeof reply);
            if (reply.magic != ABR_MAGIC || reply.length > sizeof in - sizeof reply)
                return finish(Phase::failed, "The receiver answered something unexpected.");
            if (used >= sizeof reply + reply.length) {
                AbrReader r = abr_reader(in + sizeof reply, reply.length);
                AbrField f;
                if (reply.type == ABR_MSG_PAIR_DENY) return finish(Phase::failed, "Declined on the iPad.");
                if (reply.type != ABR_MSG_PAIR_GRANT) return finish(Phase::failed, "The receiver answered something unexpected.");
                PairedReceiver receiver;
                uint8_t grantedID[16] = {};
                bool haveID = false, haveKey = false;
                char name[64] = "";
                while (abr_next_field(&r, &f)) {
                    if (f.tag == ABR_PAIR_RECEIVER_ID) haveID = abr_field_bytes(&f, grantedID, 16);
                    else if (f.tag == ABR_PAIR_KEY) haveKey = abr_field_bytes(&f, receiver.key, 32);
                    else if (f.tag == ABR_PAIR_RECEIVER_NAME) abr_field_text(&f, name, sizeof name);
                }
                // The grant must come from the receiver that was advertised (the one the person chose).
                if (!haveID || !haveKey || std::memcmp(grantedID, rid, 16) != 0)
                    return finish(Phase::failed, "The receiver's answer did not match it.");
                receiver.id = receiverID_;
                receiver.name = clean(name, 63);
                receiver.serviceName = serviceName_;
                if (!saveReceiver(receiver)) return finish(Phase::failed, "The pairing could not be stored on this Mac.");
                return finish(Phase::paired, "Paired with " + (receiver.name.empty() ? std::string("the iPad") : receiver.name) + ".");
            }
        }
        if (link->state() != NetLink::State::ready || link->finished())
            return finish(Phase::failed, "The iPad closed the pairing.");
        if (elapsed() > 130) return finish(Phase::failed, "Nobody answered on the iPad.");
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
    }
    finish(Phase::failed, "Cancelled.");
}

}  // namespace abr
