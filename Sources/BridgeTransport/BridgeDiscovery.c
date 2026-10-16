#include "BridgeDiscovery.h"
#include "BridgeProtocol.h"

#include <arpa/inet.h>

#include <dns_sd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/select.h>
#include <unistd.h>

#define MAX_PEERS 32

typedef struct {
    AbrPeer peer;
    uint32_t interfaces;           // interfaces it is currently seen on; removed at zero
    char domain[64];
    DNSServiceRef resolve;         // shares the browser's connection while resolving
    struct AbrBrowser *owner;
} Entry;

struct AbrBrowser {
    DNSServiceRef connection;
    DNSServiceRef browse;
    pthread_t thread;
    atomic_bool stopping;
    atomic_int error;
    pthread_mutex_t lock;          // entries' peers, read by abr_browser_peers
    Entry entries[MAX_PEERS];
    uint32_t count;
    char local_host[256];          // "<LocalHostName>.local." of this Mac
};

static void copy_txt(const void *txt, uint16_t length, const char *key, char *out, size_t size) {
    uint8_t value_length = 0;
    const void *value = TXTRecordGetValuePtr(length, txt, key, &value_length);
    if (!value) return;
    size_t n = value_length < size - 1 ? value_length : size - 1;
    memcpy(out, value, n);
    out[n] = 0;
}

static void DNSSD_API resolved(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interface, DNSServiceErrorType error,
                               const char *full_name, const char *host, uint16_t port, uint16_t txt_length,
                               const unsigned char *txt, void *context) {
    (void)ref; (void)flags; (void)full_name;
    Entry *entry = context;
    AbrBrowser *browser = entry->owner;
    pthread_mutex_lock(&browser->lock);
    if (error == kDNSServiceErr_NoError) {
        AbrPeer *peer = &entry->peer;
        snprintf(peer->host, sizeof peer->host, "%s", host);
        peer->port = ntohs(port);
        char proto[8] = "";
        copy_txt(txt, txt_length, "proto", proto, sizeof proto);
        peer->protocol = (uint32_t)atoi(proto);
        copy_txt(txt, txt_length, "platform", peer->platform, sizeof peer->platform);
        copy_txt(txt, txt_length, "app", peer->app, sizeof peer->app);
        copy_txt(txt, txt_length, "ver", peer->version, sizeof peer->version);
        copy_txt(txt, txt_length, "role", peer->role, sizeof peer->role);
        copy_txt(txt, txt_length, "transport", peer->transport, sizeof peer->transport);
        peer->this_mac = interface == kDNSServiceInterfaceIndexLocalOnly || strcasecmp(host, browser->local_host) == 0;
        peer->resolved = 1;
    }
    DNSServiceRefDeallocate(entry->resolve);
    entry->resolve = NULL;
    pthread_mutex_unlock(&browser->lock);
}

static void DNSSD_API browsed(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interface, DNSServiceErrorType error,
                              const char *name, const char *type, const char *domain, void *context) {
    (void)ref;
    AbrBrowser *browser = context;
    if (error != kDNSServiceErr_NoError) { atomic_store(&browser->error, error); return; }
    pthread_mutex_lock(&browser->lock);
    Entry *entry = NULL;
    for (uint32_t i = 0; i < browser->count; ++i)
        if (strcmp(browser->entries[i].peer.name, name) == 0) entry = &browser->entries[i];
    if (flags & kDNSServiceFlagsAdd) {
        if (!entry && browser->count < MAX_PEERS) {
            entry = &browser->entries[browser->count++];
            memset(entry, 0, sizeof *entry);
            entry->owner = browser;
            snprintf(entry->peer.name, sizeof entry->peer.name, "%s", name);
            snprintf(entry->domain, sizeof entry->domain, "%s", domain);
            entry->resolve = browser->connection;
            if (DNSServiceResolve(&entry->resolve, kDNSServiceFlagsShareConnection, interface, name, type, domain,
                                  resolved, entry) != kDNSServiceErr_NoError) entry->resolve = NULL;
        }
        if (entry) entry->interfaces++;
    } else if (entry && --entry->interfaces == 0) {
        if (entry->resolve) DNSServiceRefDeallocate(entry->resolve);
        // Keep the array dense; a moved entry's pending resolve would point at the old slot, so cancel it and
        // resolve again under the new address.
        Entry *last = &browser->entries[--browser->count];
        if (entry != last) {
            *entry = *last;
            if (entry->resolve) {
                DNSServiceRefDeallocate(entry->resolve);
                entry->resolve = browser->connection;
                if (DNSServiceResolve(&entry->resolve, kDNSServiceFlagsShareConnection, kDNSServiceInterfaceIndexAny,
                                      entry->peer.name, ABR_SERVICE_TYPE, entry->domain, resolved, entry) != kDNSServiceErr_NoError)
                    entry->resolve = NULL;
            }
        }
    }
    pthread_mutex_unlock(&browser->lock);
}

static void *run(void *argument) {
    AbrBrowser *browser = argument;
    pthread_setname_np("Auraliscope Bridge discovery");
    const int fd = DNSServiceRefSockFD(browser->connection);
    while (!atomic_load(&browser->stopping)) {
        fd_set read;
        FD_ZERO(&read);
        FD_SET(fd, &read);
        struct timeval timeout = {0, 200000};
        if (select(fd + 1, &read, NULL, NULL, &timeout) > 0) {
            DNSServiceErrorType error = DNSServiceProcessResult(browser->connection);
            if (error != kDNSServiceErr_NoError) { atomic_store(&browser->error, error); break; }
        }
    }
    return NULL;
}

AbrBrowser *abr_browser_start(void) {
    AbrBrowser *browser = calloc(1, sizeof(AbrBrowser));
    if (!browser) return NULL;
    pthread_mutex_init(&browser->lock, NULL);
    char name[200] = "";
    gethostname(name, sizeof name);
    char *dot = strchr(name, '.');
    if (dot) *dot = 0;
    snprintf(browser->local_host, sizeof browser->local_host, "%s.local.", name);
    if (DNSServiceCreateConnection(&browser->connection) != kDNSServiceErr_NoError) { free(browser); return NULL; }
    browser->browse = browser->connection;
    DNSServiceErrorType error = DNSServiceBrowse(&browser->browse, kDNSServiceFlagsShareConnection,
                                                 kDNSServiceInterfaceIndexAny, ABR_SERVICE_TYPE, NULL, browsed, browser);
    if (error != kDNSServiceErr_NoError) atomic_store(&browser->error, error);
    if (pthread_create(&browser->thread, NULL, run, browser) != 0) {
        DNSServiceRefDeallocate(browser->connection);
        free(browser);
        return NULL;
    }
    return browser;
}

void abr_browser_stop(AbrBrowser *browser) {
    if (!browser) return;
    atomic_store(&browser->stopping, true);
    pthread_join(browser->thread, NULL);
    DNSServiceRefDeallocate(browser->connection);  // also ends the browse and every pending resolve
    pthread_mutex_destroy(&browser->lock);
    free(browser);
}

uint32_t abr_browser_peers(AbrBrowser *browser, AbrPeer *out, uint32_t capacity) {
    pthread_mutex_lock(&browser->lock);
    uint32_t count = browser->count;
    for (uint32_t i = 0; out && i < count && i < capacity; ++i) out[i] = browser->entries[i].peer;
    pthread_mutex_unlock(&browser->lock);
    return count;
}

int32_t abr_browser_error(AbrBrowser *browser) { return atomic_load(&browser->error); }

struct AbrAdvertiser {
    DNSServiceRef ref;
};

AbrAdvertiser *abr_advertise_start(const char *name, uint16_t port, const char *platform, const char *app,
                                   const char *version, const char *role, const char *transport, int local_only) {
    AbrAdvertiser *advertiser = calloc(1, sizeof(AbrAdvertiser));
    if (!advertiser) return NULL;
    TXTRecordRef txt;
    char buffer[256];
    TXTRecordCreate(&txt, sizeof buffer, buffer);
    char proto[8];
    snprintf(proto, sizeof proto, "%u", ABR_PROTOCOL_VERSION);
    TXTRecordSetValue(&txt, "proto", (uint8_t)strlen(proto), proto);
    TXTRecordSetValue(&txt, "platform", (uint8_t)strlen(platform), platform);
    TXTRecordSetValue(&txt, "app", (uint8_t)strlen(app), app);
    TXTRecordSetValue(&txt, "ver", (uint8_t)strlen(version), version);
    TXTRecordSetValue(&txt, "role", (uint8_t)strlen(role), role);
    TXTRecordSetValue(&txt, "transport", (uint8_t)strlen(transport), transport);
    DNSServiceErrorType error = DNSServiceRegister(&advertiser->ref, 0,
                                                   local_only ? kDNSServiceInterfaceIndexLocalOnly : kDNSServiceInterfaceIndexAny,
                                                   name, ABR_SERVICE_TYPE, NULL, NULL, htons(port),
                                                   TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), NULL, NULL);
    TXTRecordDeallocate(&txt);
    if (error != kDNSServiceErr_NoError) { free(advertiser); return NULL; }
    return advertiser;  // the daemon keeps the registration until the reference is deallocated
}

void abr_advertise_stop(AbrAdvertiser *advertiser) {
    if (!advertiser) return;
    DNSServiceRefDeallocate(advertiser->ref);
    free(advertiser);
}
