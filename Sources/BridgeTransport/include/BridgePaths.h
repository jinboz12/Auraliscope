#ifndef AURALISCOPE_BRIDGE_PATHS_H
#define AURALISCOPE_BRIDGE_PATHS_H

// Where the application listens, shared by both ends so they can never disagree.
//
// `~/Library/Application Support/Auraliscope Bridge/bridge-v1.sock`, in the real home folder of the current user
// (not a sandbox container's HOME). The folder is created 0700 by the application, and both ends check their
// peer's user ID, so another account on the Mac can neither connect nor listen in its place.
//
// `AURALISCOPE_BRIDGE_SOCKET`, when set, overrides the path (tests use it to run a private receiver).

#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#define ABR_SOCKET_FOLDER "/Library/Application Support/Auraliscope Bridge"
#define ABR_SOCKET_NAME "bridge-v1.sock"

// Writes the folder to `buffer`; returns 0 on success. Allocation-free except inside getpwuid_r's own buffer.
static inline int abr_socket_folder(char *buffer, size_t size) {
    const char *override = getenv("AURALISCOPE_BRIDGE_SOCKET");
    if (override && *override) {
        const char *slash = strrchr(override, '/');
        if (!slash) return -1;
        size_t length = (size_t)(slash - override);
        if (length + 1 > size) return -1;
        memcpy(buffer, override, length);
        buffer[length] = 0;
        return 0;
    }
    struct passwd entry, *result = NULL;
    char scratch[2048];
    if (getpwuid_r(getuid(), &entry, scratch, sizeof scratch, &result) != 0 || !result || !result->pw_dir) return -1;
    int written = snprintf(buffer, size, "%s%s", result->pw_dir, ABR_SOCKET_FOLDER);
    return written > 0 && (size_t)written < size ? 0 : -1;
}

static inline int abr_socket_path(char *buffer, size_t size) {
    const char *override = getenv("AURALISCOPE_BRIDGE_SOCKET");
    if (override && *override) {
        if (strlen(override) + 1 > size) return -1;
        strcpy(buffer, override);
        return 0;
    }
    char folder[1024];
    if (abr_socket_folder(folder, sizeof folder) != 0) return -1;
    int written = snprintf(buffer, size, "%s/%s", folder, ABR_SOCKET_NAME);
    return written > 0 && (size_t)written < size ? 0 : -1;
}

#endif
