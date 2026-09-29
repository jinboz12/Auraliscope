// Stands in for a future Auraliscope on iPhone or iPad: advertises the receiver service (BridgeDiscovery.h) so the
// plugin's network scan can be checked before an iOS app exists. Local-only by default (visible on this Mac only).
//
//   DiscoveryBeacon [--name "Test iPad"] [--platform iPadOS] [--version 1.4] [--seconds 20] [--network 1]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "BridgeDiscovery.h"

int main(int argc, char **argv) {
    const char *name = "Test iPad", *platform = "iPadOS", *version = "1.4";
    int seconds = 20, network = 0;
    for (int i = 1; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--name")) name = argv[i + 1];
        else if (!strcmp(argv[i], "--platform")) platform = argv[i + 1];
        else if (!strcmp(argv[i], "--version")) version = argv[i + 1];
        else if (!strcmp(argv[i], "--seconds")) seconds = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--network")) network = atoi(argv[i + 1]);
    }
    AbrAdvertiser *beacon = abr_advertise_start(name, 50505, platform, "Auraliscope", version, "display", "tcp", !network);
    if (!beacon) { fprintf(stderr, "[beacon] DNS-SD registration failed\n"); return 1; }
    printf("[beacon] advertising \"%s\" (%s, Auraliscope %s) %s for %d s\n", name, platform, version,
           network ? "on the local network" : "on this Mac only", seconds);
    fflush(stdout);
    sleep((unsigned)seconds);
    abr_advertise_stop(beacon);
    return 0;
}
