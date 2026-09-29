#pragma once

// Private Audio Unit properties shared by the AU and its view factory (same binary, same process).

#include <AudioToolbox/AudioUnitProperties.h>

#define ABR_STRINGIFY_INNER(x) #x
#define ABR_STRINGIFY(x) ABR_STRINGIFY_INNER(x)

#ifndef ABR_AU_BUNDLE_ID
#define ABR_AU_BUNDLE_ID "com.jinboz.AuraliscopeBridge.component"
#endif

namespace abr {
// Global, read-only: a pointer to the unit's std::shared_ptr<BridgeCore>.
constexpr AudioUnitPropertyID kCoreProperty = 64000;
// Global, write-only: the view reports that the user renamed the source.
constexpr AudioUnitPropertyID kNameEditedProperty = 64001;
}  // namespace abr
