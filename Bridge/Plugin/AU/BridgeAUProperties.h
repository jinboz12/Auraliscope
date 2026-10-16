#pragma once

// Private Audio Unit properties shared by the AU and its view factory (same binary, same process).

#include <AudioToolbox/AudioUnitProperties.h>
#include <unistd.h>

#define ABR_STRINGIFY_INNER(x) #x
#define ABR_STRINGIFY(x) ABR_STRINGIFY_INNER(x)

#ifndef ABR_AU_BUNDLE_ID
#define ABR_AU_BUNDLE_ID "com.jinboz.AuraliscopeBridge.component"
#endif

namespace abr {
// Global, read-only: a `CoreReference` to the unit's std::shared_ptr<BridgeCore>.
constexpr AudioUnitPropertyID kCoreProperty = 64000;
constexpr uint32_t kCoreReferenceMagic = 0x41425243;  // "ABRC"
struct CoreReference {
    uint32_t magic;
    pid_t process;   // the address is valid in this process only
    void *core;      // std::shared_ptr<BridgeCore> *
};
// Global, write-only: the view reports that the user renamed the source.
constexpr AudioUnitPropertyID kNameEditedProperty = 64001;
}  // namespace abr
