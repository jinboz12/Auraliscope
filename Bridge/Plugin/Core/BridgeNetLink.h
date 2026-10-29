#pragma once

// The Bridge's network carrier (Bridge/BRIDGE_NETWORK.md): one TLS 1.2 connection with a pre-shared key
// (TLS_PSK_WITH_AES_128_GCM_SHA256), through Network.framework, to an Auraliscope display on the local network.
// It carries exactly the byte stream the local socket carries (the same framing and messages), so BridgeCore treats
// both alike.
//
// Never used by the host's audio thread. Every call returns at once: connecting, resolving and the TLS handshake
// happen on the link's own dispatch queue. Both directions are bounded: at most `kMaxInFlight` bytes are accepted for
// sending until the network takes them, and at most `kMaxInbound` received bytes wait to be read (beyond that the
// link stops reading, and TCP holds the peer back). A slow, stalled or vanished display costs a fixed amount of memory
// and nothing else.

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace abr {

class NetLink {
public:
    enum class State { connecting, ready, failed, closed };
    static constexpr size_t kMaxInFlight = 256 * 1024;
    static constexpr size_t kMaxInbound = 64 * 1024;

    // To an advertised receiver: its DNS-SD service name (type _auraliscope._tcp, domain local.).
    static std::unique_ptr<NetLink> toService(const std::string &serviceName, const uint8_t *key, size_t keyBytes,
                                              const uint8_t *identity, size_t identityBytes);
    // To a host and port (the pairing listener, whose port the receiver advertises in its TXT record).
    static std::unique_ptr<NetLink> toHost(const std::string &host, uint16_t port, const uint8_t *key, size_t keyBytes,
                                           const uint8_t *identity, size_t identityBytes);
    ~NetLink();
    NetLink(const NetLink &) = delete;
    NetLink &operator=(const NetLink &) = delete;

    State state() const;
    // Why it failed (or is waiting), for the plugin window; empty otherwise.
    std::string error() const;
    // True when the reason is the host application's Local Network permission.
    bool policyDenied() const;
    // Takes all `length` bytes, or none when that would exceed kMaxInFlight (the caller keeps them and retries).
    bool send(const uint8_t *bytes, size_t length);
    size_t inFlight() const;
    // Copies up to `capacity` received bytes; 0 when none are waiting.
    size_t receive(uint8_t *out, size_t capacity);
    // The peer closed its side and every byte it sent has been read.
    bool finished() const;
    // Bytes sent and received so far (for diagnostics and measurements).
    uint64_t bytesSent() const;
    uint64_t bytesReceived() const;

    struct Shared;
    explicit NetLink(std::shared_ptr<Shared> shared);  // through toService / toHost

private:
    std::shared_ptr<Shared> shared_;
};

// PBKDF2-HMAC-SHA256 of the 8-character pairing code (already normalised) with the receiver's ID: the pairing key.
// Returns false when `code` is not 8 characters of the Crockford alphabet.
bool pairingKey(const std::string &code, const uint8_t receiverID[16], uint8_t key[32]);
// What a person typed, as the code (case, spaces and dashes ignored, O read as 0, I and L as 1); empty when invalid.
std::string normaliseCode(const std::string &typed);

}  // namespace abr
