// Feasibility probe for a production (sandboxed) Bridge transport. Not part of Labs or the plugins.
//
//   SandboxTransportProbe receiver <group> [seconds]   run inside a sandboxed app bundle with the application group
//   SandboxTransportProbe plugin <group>               run unsandboxed, as a plugin inside a DAW is
//
// The receiver tries (1) a Unix socket in the group container and (2) a CFMessagePort named "<group>.bridge", then
// looks up (3) a port the plugin registered as "<group>.plugin" and (4) one without the group prefix. The plugin
// connects to (1) and (2), sends 1000 requests of 4 KB (about 10 s of 48 kHz stereo float in 11 ms blocks) and
// times them, and registers the ports (3) and (4) for the receiver to reach.
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <pwd.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static double now_us(void) {
    static mach_timebase_info_data_t base;
    if (!base.denom) mach_timebase_info(&base);
    return (double)mach_absolute_time() * base.numer / base.denom / 1000.0;
}
static CFStringRef port_name(const char *group, const char *suffix) {
    char name[256];
    snprintf(name, sizeof name, "%s%s", group, suffix);
    return CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
}
static CFDataRef answer(CFMessagePortRef port, SInt32 id, CFDataRef data, void *info) {
    (void)port; (void)id; (void)data; (void)info;
    return CFDataCreate(NULL, (const UInt8 *)"ok", 2);
}
static CFDataRef heard(CFMessagePortRef port, SInt32 id, CFDataRef data, void *info) {
    (void)port; (void)id; (void)info;
    printf("plugin: port %s reached by the receiver (%ld bytes)\n", id == 1 ? "with prefix" : "without prefix",
           CFDataGetLength(data));
    fflush(stdout);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s receiver|plugin <group> [seconds]\n", argv[0]); return 2; }
    const char *group = argv[2];
    char path[1024];
    snprintf(path, sizeof path, "%s/Library/Group Containers/%s/bridge.sock", getpwuid(getuid())->pw_dir, group);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, path, sizeof address.sun_path - 1);

    if (!strcmp(argv[1], "receiver")) {
        const char *home = getenv("HOME");
        printf("receiver: sandboxed: %s\n", home && strstr(home, "/Library/Containers/") ? "yes" : "NO");
        int listener = socket(AF_UNIX, SOCK_STREAM, 0);
        unlink(path);
        int bound = bind(listener, (struct sockaddr *)&address, sizeof address);
        printf("receiver: (1) Unix socket in the group container: %s\n", bound == 0 ? "bound" : strerror(errno));
        if (bound == 0) {
            listen(listener, 4);
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                int connection = accept(listener, NULL, NULL);
                char block[4096];
                while (connection >= 0 && read(connection, block, sizeof block) > 0) write(connection, "ok", 2);
            });
        }
        CFMessagePortRef local = CFMessagePortCreateLocal(NULL, port_name(group, ".bridge"), answer, NULL, NULL);
        printf("receiver: (2) CFMessagePort \"%s.bridge\": %s\n", group, local ? "registered" : "REFUSED");
        fflush(stdout);
        if (local) CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMessagePortCreateRunLoopSource(NULL, local, 0),
                                      kCFRunLoopCommonModes);
        double seconds = argc > 3 ? atof(argv[3]) : 9;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds - 3, false);
        const char *suffixes[2] = {".plugin", NULL};
        for (int i = 0; i < 2; i++) {
            CFStringRef name = suffixes[i] ? port_name(group, suffixes[i])
                                           : CFSTR("com.example.unprefixed.bridge-plugin");
            CFMessagePortRef remote = CFMessagePortCreateRemote(NULL, name);
            CFDataRef data = CFDataCreate(NULL, (const UInt8 *)"subscribe", 9);
            int sent = remote && CFMessagePortSendRequest(remote, i + 1, data, 1, 0, NULL, NULL) == kCFMessagePortSuccess;
            printf("receiver: (%d) plugin's port %s the group prefix: %s\n", i + 3, i ? "without" : "with",
                   sent ? "reached" : remote ? "found, send failed" : "not reachable");
        }
        fflush(stdout);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1, false);
        return 0;
    }

    CFMessagePortRef mine = CFMessagePortCreateLocal(NULL, port_name(group, ".plugin"), heard, NULL, NULL);
    CFMessagePortRef other = CFMessagePortCreateLocal(NULL, CFSTR("com.example.unprefixed.bridge-plugin"), heard, NULL, NULL);
    if (mine) CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMessagePortCreateRunLoopSource(NULL, mine, 0), kCFRunLoopCommonModes);
    if (other) CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMessagePortCreateRunLoopSource(NULL, other, 0), kCFRunLoopCommonModes);
    char block[4096] = {0};
    int client = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connect(client, (struct sockaddr *)&address, sizeof address) == 0) {
        double worst = 0, start = now_us();
        for (int i = 0; i < 1000; i++) {
            double t = now_us();
            char reply[2];
            write(client, block, sizeof block);
            read(client, reply, 2);
            if (now_us() - t > worst) worst = now_us() - t;
        }
        printf("plugin: (1) Unix socket: 1000 x 4 KB round trips, mean %.1f µs, worst %.0f µs\n", (now_us() - start) / 1000, worst);
    } else {
        printf("plugin: (1) Unix socket: %s\n", strerror(errno));
    }
    CFMessagePortRef remote = CFMessagePortCreateRemote(NULL, port_name(group, ".bridge"));
    if (remote) {
        CFDataRef data = CFDataCreate(NULL, (const UInt8 *)block, sizeof block);
        double worst = 0, start = now_us();
        int ok = 0;
        for (int i = 0; i < 1000; i++) {
            CFDataRef reply = NULL;
            double t = now_us();
            if (CFMessagePortSendRequest(remote, 1, data, 1, 1, kCFRunLoopDefaultMode, &reply) == kCFMessagePortSuccess) ok++;
            if (reply) CFRelease(reply);
            if (now_us() - t > worst) worst = now_us() - t;
        }
        printf("plugin: (2) CFMessagePort: %d/1000 x 4 KB requests answered, mean %.1f µs, worst %.0f µs\n", ok,
               (now_us() - start) / 1000, worst);
    } else {
        printf("plugin: (2) CFMessagePort: receiver's port not found\n");
    }
    fflush(stdout);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 8, false);  // let the receiver reach this plugin's ports
    return 0;
}
