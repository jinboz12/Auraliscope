#include "BridgeNetLink.h"

#include <CommonCrypto/CommonCryptoError.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <Network/Network.h>
#include <Security/SecProtocolOptions.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <mutex>
#include <vector>

namespace abr {

struct NetLink::Shared {
    std::mutex lock;
    nw_connection_t connection = nullptr;
    dispatch_queue_t queue = nullptr;
    std::atomic<int> state{int(State::connecting)};
    std::atomic<size_t> inFlight{0};
    std::atomic<uint64_t> sent{0}, received{0};
    std::atomic<bool> policyDenied{false};
    std::vector<uint8_t> inbound;   // under `lock`
    bool receiving = false;         // a receive is scheduled (under `lock`)
    bool peerDone = false;          // under `lock`
    std::string error;              // under `lock`
    // The key and identity, kept for as long as the connection may configure TLS again.
    dispatch_data_t psk = nullptr, identity = nullptr;
};

namespace {
constexpr int kPolicyDenied = -65570;  // kDNSServiceErr_PolicyDenied

void scheduleReceive(const std::shared_ptr<NetLink::Shared> &shared);

std::string describe(nw_error_t error) {
    if (!error) return "";
    const int code = nw_error_get_error_code(error);
    switch (nw_error_get_error_domain(error)) {
    case nw_error_domain_dns:
        return code == kPolicyDenied ? "Local Network access is off for this application"
                                     : "The receiver could not be found on the network (DNS-SD " + std::to_string(code) + ")";
    case nw_error_domain_tls:
        // A wrong pre-shared key ends the handshake with a bad record MAC (or a decrypt error).
        return "The receiver refused the key (not paired, or paired again since): TLS " + std::to_string(code);
    case nw_error_domain_posix:
        return std::string("Network: ") + std::strerror(code);
    default:
        return "Network error " + std::to_string(code);
    }
}

void fail(const std::shared_ptr<NetLink::Shared> &shared, nw_error_t error, NetLink::State state) {
    std::lock_guard<std::mutex> guard(shared->lock);
    if (error) {
        shared->error = describe(error);
        if (nw_error_get_error_domain(error) == nw_error_domain_dns && nw_error_get_error_code(error) == kPolicyDenied)
            shared->policyDenied.store(true);
    }
    shared->state.store(int(state));
}

void scheduleReceive(const std::shared_ptr<NetLink::Shared> &shared) {
    nw_connection_t connection;
    {
        std::lock_guard<std::mutex> guard(shared->lock);
        if (shared->receiving || shared->peerDone || shared->inbound.size() >= NetLink::kMaxInbound) return;
        shared->receiving = true;
        connection = shared->connection;
    }
    const uint32_t room = uint32_t(NetLink::kMaxInbound);
    std::weak_ptr<NetLink::Shared> weak = shared;
    nw_connection_receive(connection, 1, room, ^(dispatch_data_t content, nw_content_context_t, bool complete, nw_error_t error) {
        auto strong = weak.lock();
        if (!strong) return;
        {
            std::lock_guard<std::mutex> guard(strong->lock);
            strong->receiving = false;
            if (content) {
                dispatch_data_apply(content, ^bool(dispatch_data_t, size_t, const void *buffer, size_t size) {
                    const auto *bytes = static_cast<const uint8_t *>(buffer);
                    strong->inbound.insert(strong->inbound.end(), bytes, bytes + size);
                    return true;
                });
                strong->received.fetch_add(dispatch_data_get_size(content));
            }
            if (complete) strong->peerDone = true;
        }
        if (error) { fail(strong, error, NetLink::State::failed); return; }
        scheduleReceive(strong);  // stops by itself while the inbound buffer is full
    });
}

std::unique_ptr<NetLink> start(nw_endpoint_t endpoint, const uint8_t *key, size_t keyBytes, const uint8_t *identity,
                               size_t identityBytes, std::shared_ptr<NetLink::Shared> shared) {
    dispatch_data_t pskData = dispatch_data_create(key, keyBytes, nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t identityData = dispatch_data_create(identity, identityBytes, nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(
        ^(nw_protocol_options_t tls) {
            sec_protocol_options_t options = nw_tls_copy_sec_protocol_options(tls);
            sec_protocol_options_add_pre_shared_key(options, pskData, identityData);
            sec_protocol_options_append_tls_ciphersuite(options, (tls_ciphersuite_t)0x00A8);  // TLS_PSK_WITH_AES_128_GCM_SHA256
            sec_protocol_options_set_min_tls_protocol_version(options, tls_protocol_version_TLSv12);
            sec_protocol_options_set_max_tls_protocol_version(options, tls_protocol_version_TLSv12);
            sec_release(options);
        },
        ^(nw_protocol_options_t tcp) {
            nw_tcp_options_set_no_delay(tcp, true);
            nw_tcp_options_set_connection_timeout(tcp, 5);
            nw_tcp_options_set_enable_keepalive(tcp, true);
            nw_tcp_options_set_keepalive_idle_time(tcp, 2);
            nw_tcp_options_set_keepalive_interval(tcp, 1);
            nw_tcp_options_set_keepalive_count(tcp, 3);
        });
    nw_parameters_set_include_peer_to_peer(parameters, false);
    shared->queue = dispatch_queue_create("Auraliscope Bridge network", DISPATCH_QUEUE_SERIAL);
    shared->connection = nw_connection_create(endpoint, parameters);
    nw_release(parameters);
    nw_release(endpoint);
    shared->psk = pskData;
    shared->identity = identityData;
    std::weak_ptr<NetLink::Shared> weak = shared;
    nw_connection_set_queue(shared->connection, shared->queue);
    nw_connection_set_state_changed_handler(shared->connection, ^(nw_connection_state_t state, nw_error_t error) {
        auto strong = weak.lock();
        if (!strong) return;
        switch (state) {
        case nw_connection_state_ready:
            strong->state.store(int(NetLink::State::ready));
            scheduleReceive(strong);
            break;
        case nw_connection_state_waiting:
            // Not reachable yet (no route, refused, the Local Network permission): Network.framework tries again by
            // itself. The reason is kept for the plugin window; the owner gives up on its own timeout.
            // A refused handshake (a key the display does not hold) is final: no retry will change it.
            fail(strong, error, error && nw_error_get_error_domain(error) == nw_error_domain_tls ? NetLink::State::failed
                                                                                                : NetLink::State::connecting);
            break;
        case nw_connection_state_failed:
            fail(strong, error, NetLink::State::failed);
            break;
        case nw_connection_state_cancelled:
            if (strong->state.load() != int(NetLink::State::failed)) strong->state.store(int(NetLink::State::closed));
            break;
        default:
            break;
        }
    });
    nw_connection_start(shared->connection);
    return std::unique_ptr<NetLink>(new NetLink(std::move(shared)));
}
}  // namespace

NetLink::NetLink(std::shared_ptr<Shared> shared) : shared_(std::move(shared)) {}

NetLink::~NetLink() {
    nw_connection_t connection;
    {
        std::lock_guard<std::mutex> guard(shared_->lock);
        connection = shared_->connection;
        shared_->connection = nullptr;
    }
    if (connection) {
        nw_connection_cancel(connection);
        nw_release(connection);
    }
    if (shared_->queue) dispatch_release(shared_->queue);
    // The handlers hold only weak references; the key data goes once the connection is cancelled.
    dispatch_release(shared_->psk);
    dispatch_release(shared_->identity);
}

std::unique_ptr<NetLink> NetLink::toService(const std::string &serviceName, const uint8_t *key, size_t keyBytes,
                                            const uint8_t *identity, size_t identityBytes) {
    nw_endpoint_t endpoint = nw_endpoint_create_bonjour_service(serviceName.c_str(), "_auraliscope._tcp", "local.");
    return start(endpoint, key, keyBytes, identity, identityBytes, std::make_shared<Shared>());
}

std::unique_ptr<NetLink> NetLink::toHost(const std::string &host, uint16_t port, const uint8_t *key, size_t keyBytes,
                                         const uint8_t *identity, size_t identityBytes) {
    nw_endpoint_t endpoint = nw_endpoint_create_host(host.c_str(), std::to_string(port).c_str());
    return start(endpoint, key, keyBytes, identity, identityBytes, std::make_shared<Shared>());
}

NetLink::State NetLink::state() const { return State(shared_->state.load()); }

std::string NetLink::error() const {
    std::lock_guard<std::mutex> guard(shared_->lock);
    return shared_->error;
}

bool NetLink::policyDenied() const { return shared_->policyDenied.load(); }

bool NetLink::send(const uint8_t *bytes, size_t length) {
    if (length == 0) return true;
    if (state() != State::ready || shared_->inFlight.load() + length > kMaxInFlight) return false;
    nw_connection_t connection;
    {
        std::lock_guard<std::mutex> guard(shared_->lock);
        connection = shared_->connection;
    }
    if (!connection) return false;
    shared_->inFlight.fetch_add(length);
    dispatch_data_t data = dispatch_data_create(bytes, length, nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    std::weak_ptr<Shared> weak = shared_;
    nw_connection_send(connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t error) {
        auto strong = weak.lock();
        if (!strong) return;
        strong->inFlight.fetch_sub(length);
        strong->sent.fetch_add(length);
        if (error) fail(strong, error, State::failed);
    });
    dispatch_release(data);
    return true;
}

size_t NetLink::inFlight() const { return shared_->inFlight.load(); }

size_t NetLink::receive(uint8_t *out, size_t capacity) {
    size_t count;
    {
        std::lock_guard<std::mutex> guard(shared_->lock);
        count = std::min(capacity, shared_->inbound.size());
        if (count == 0) return 0;
        std::memcpy(out, shared_->inbound.data(), count);
        shared_->inbound.erase(shared_->inbound.begin(), shared_->inbound.begin() + long(count));
    }
    if (state() == State::ready) scheduleReceive(shared_);  // reading again once there is room
    return count;
}

bool NetLink::finished() const {
    std::lock_guard<std::mutex> guard(shared_->lock);
    return shared_->peerDone && shared_->inbound.empty();
}

uint64_t NetLink::bytesSent() const { return shared_->sent.load(); }
uint64_t NetLink::bytesReceived() const { return shared_->received.load(); }

std::string normaliseCode(const std::string &typed) {
    static const char alphabet[] = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    std::string code;
    for (char raw : typed) {
        char c = char(std::toupper(static_cast<unsigned char>(raw)));
        if (c == '-' || c == ' ') continue;
        if (c == 'O') c = '0';
        if (c == 'I' || c == 'L') c = '1';
        if (!std::strchr(alphabet, c) || c == 0) return "";
        code.push_back(c);
    }
    return code.size() == 8 ? code : "";
}

bool pairingKey(const std::string &typed, const uint8_t receiverID[16], uint8_t key[32]) {
    const std::string code = normaliseCode(typed);
    if (code.empty()) return false;
    static const char prefix[] = "AuraliscopeBridgePair1";
    uint8_t salt[sizeof prefix - 1 + 16];
    std::memcpy(salt, prefix, sizeof prefix - 1);
    std::memcpy(salt + sizeof prefix - 1, receiverID, 16);
    return CCKeyDerivationPBKDF(kCCPBKDF2, code.data(), code.size(), salt, sizeof salt, kCCPRFHmacAlgSHA256, 200000, key,
                                32) == kCCSuccess;
}

}  // namespace abr
