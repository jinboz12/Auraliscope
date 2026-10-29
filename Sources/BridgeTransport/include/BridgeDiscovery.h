#ifndef AURALISCOPE_BRIDGE_DISCOVERY_H
#define AURALISCOPE_BRIDGE_DISCOVERY_H

// Network discovery of Auraliscope receivers with DNS-SD (Bonjour), for the plugin's scan.
//
// On this Mac the Bridge finds Auraliscope through its local socket (BridgePaths.h); DNS-SD is for receivers on
// other devices of the local network, such as Auraliscope for iPad. Discovery only: nothing here connects to a peer
// or sends it audio (the network carrier is Bridge/Plugin/Core/BridgeNetLink.h, see Bridge/BRIDGE_NETWORK.md).
//
// A receiver advertises the service type ABR_SERVICE_TYPE on the port where it accepts connections, with these
// TXT keys (all optional except proto):
//   proto=3            Bridge protocol version it speaks (ABR_PROTOCOL_VERSION)
//   schema=1           analysis schema it reads (ABR_ANALYSIS_SCHEMA)
//   platform=iPadOS    iOS, iPadOS or macOS
//   app=Auraliscope    application name
//   ver=2.1            application version
//   role=display       display: renders analysis results; analyzer: analyses audio
//   transport=tls-psk  how a sender reaches it: TLS 1.2 with a pre-shared key from pairing (tcp: unauthenticated test
//                      beacons, never connected to)
//   rid=<32 hex>       the receiver's ID (16 bytes), stable for the installation: what a pairing is bound to
//   pair=<port>        present while the receiver accepts a pairing, on that port

#include <stdint.h>

#define ABR_SERVICE_TYPE "_auraliscope._tcp"

typedef struct {
    char name[64];           // service instance name (usually the device name)
    char host[128];          // resolved host, e.g. "Jinbos-iPad.local."
    uint16_t port;
    uint32_t protocol;       // TXT proto, 0 when absent
    char platform[16];
    char app[48];
    char version[24];
    char role[16];
    char transport[16];
    uint32_t schema;         // TXT schema, 0 when absent
    char receiver_id[33];    // TXT rid (hex), empty when absent
    uint16_t pairing_port;   // TXT pair, 0 when the receiver is not pairing
    int resolved;            // host, port and TXT are known
    int this_mac;            // advertised by this computer
} AbrPeer;

typedef struct AbrBrowser AbrBrowser;

// Starts browsing on a background thread. Returns NULL only when DNS-SD is unavailable.
AbrBrowser *_Nullable abr_browser_start(void);
void abr_browser_stop(AbrBrowser *_Nullable browser);
// Copies up to `capacity` peers; returns how many there are.
uint32_t abr_browser_peers(AbrBrowser *_Nonnull browser, AbrPeer *_Nullable out, uint32_t capacity);
// 0 while browsing works; otherwise the DNS-SD error (kDNSServiceErr_PolicyDenied, -65570, when the host app
// has no Local Network permission).
int32_t abr_browser_error(AbrBrowser *_Nonnull browser);

typedef struct AbrAdvertiser AbrAdvertiser;

// Advertises a receiver (used by test tools, and later by receivers that accept network connections).
// `local_only` keeps the advertisement on this Mac.
AbrAdvertiser *_Nullable abr_advertise_start(const char *_Nonnull name, uint16_t port, const char *_Nonnull platform,
                                             const char *_Nonnull app, const char *_Nonnull version,
                                             const char *_Nonnull role, const char *_Nonnull transport, int local_only);
void abr_advertise_stop(AbrAdvertiser *_Nullable advertiser);

#endif
