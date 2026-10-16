#ifndef AURALISCOPE_BRIDGE_DISCOVERY_H
#define AURALISCOPE_BRIDGE_DISCOVERY_H

// Network discovery of Auraliscope receivers with DNS-SD (Bonjour), for the plugin's scan.
//
// On this Mac the Bridge finds Auraliscope through its local socket (BridgePaths.h); DNS-SD is for receivers on
// other devices of the local network, such as a future Auraliscope for iOS. Discovery only: nothing here
// connects to a peer or sends it audio.
//
// A receiver advertises the service type ABR_SERVICE_TYPE on the port where it accepts connections, with these
// TXT keys (all optional except proto):
//   proto=1            Bridge protocol version it speaks
//   platform=iOS       iOS, iPadOS or macOS
//   app=Auraliscope    application name
//   ver=1.4            application version
//   role=display       display: renders analysis results; analyzer: analyses audio
//   transport=tcp      how a sender reaches it

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
