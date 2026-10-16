#import <AudioUnit/AUCocoaUIView.h>
#import <Cocoa/Cocoa.h>

#include <memory>

#include "BridgeAUProperties.h"
#include "BridgeCore.h"
#include "BridgeEditor.h"

#ifndef ABR_AU_VIEW_FACTORY
#error "Define ABR_AU_VIEW_FACTORY"
#endif

// The Cocoa view factory named by kAudioUnitProperty_CocoaUI. Hosts instantiate it in the process that runs the
// unit, so the unit's core can be reached through a private property.
@interface ABR_AU_VIEW_FACTORY : NSObject <AUCocoaUIBase>
@end

@implementation ABR_AU_VIEW_FACTORY

- (unsigned)interfaceVersion { return 0; }

- (NSString *)description { return @"Auraliscope Bridge"; }

- (NSView *)uiViewForAudioUnit:(AudioUnit)unit withSize:(NSSize)size {
    abr::CoreReference reference{};
    UInt32 bytes = sizeof reference;
    if (AudioUnitGetProperty(unit, abr::kCoreProperty, kAudioUnitScope_Global, 0, &reference, &bytes) != noErr
        || bytes != sizeof reference || reference.magic != abr::kCoreReferenceMagic || reference.process != getpid()
        || !reference.core)
        return nil;  // the unit runs in another process: no window rather than a crash
    std::shared_ptr<abr::BridgeCore> core = *static_cast<std::shared_ptr<abr::BridgeCore> *>(reference.core);
    void *view = abr::createEditorView(core, [unit] {
        UInt32 edited = 1;
        AudioUnitSetProperty(unit, abr::kNameEditedProperty, kAudioUnitScope_Global, 0, &edited, sizeof edited);
    }, "AU");
    // The host owns the view from here; its update timer stops when it leaves the window.
    return (__bridge_transfer NSView *)view;
}

@end
