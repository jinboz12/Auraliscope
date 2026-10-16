// Auraliscope Bridge as an Audio Unit v2 effect (aufx Abrg Jnbz): a thin wrapper over BridgeCore.
//
// Mono → mono or stereo → stereo, Float32 non-interleaved (the AudioUnitSDK canonical format), processed in place.
//
//   bypass     kAudioUnitProperty_BypassEffect: AUEffectBase passes audio without calling ProcessBufferLists;
//              the core is told, and stops transmitting
//   offline    kAudioUnitProperty_OfflineRender: audio passes, nothing is transmitted
//   transport  the host's transport-state callback (playing, timeline position) is forwarded as metadata only
//   state      ClassInfo carries the core's text (name, persistent ID) under kStateKey
//   track name kAudioUnitProperty_ContextName, when the host sets it

#include <AudioUnitSDK/AUEffectBase.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>

#include "BridgeAUProperties.h"
#include "BridgeCore.h"

// kAudioUnitProperty_CocoaUI names this class; it must be the one BridgeAUView.mm defines.
#ifndef ABR_AU_VIEW_FACTORY
#error "Define ABR_AU_VIEW_FACTORY (see build-plugins.sh)"
#endif

namespace {

const CFStringRef kStateKey = CFSTR("com.jinboz.AuraliscopeBridge.state");

std::string utf8(CFStringRef string) {
    if (!string) return {};
    const CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
    std::string text(size_t(size), '\0');
    if (!CFStringGetCString(string, text.data(), size, kCFStringEncodingUTF8)) return {};
    text.resize(std::strlen(text.c_str()));
    return text;
}

class BridgeAU : public ausdk::AUEffectBase {
public:
    explicit BridgeAU(AudioComponentInstance unit)
        : AUEffectBase(unit, true), core_(std::make_shared<abr::BridgeCore>(ABR_FORMAT_AU)) {}

    OSStatus Initialize() override {
        const OSStatus result = AUEffectBase::Initialize();
        if (result != noErr) return result;
        core_->configure(GetSampleRate(), Output(0).GetStreamFormat().mChannelsPerFrame, GetMaxFramesPerSlice());
        core_->setOffline(offline_);
        core_->setActive(true);
        return noErr;
    }

    void Cleanup() override {
        core_->setActive(false);
        AUEffectBase::Cleanup();
    }

    UInt32 SupportedNumChannels(const AUChannelInfo **info) override {
        static const AUChannelInfo supported[] = {{1, 1}, {2, 2}};
        if (info) *info = supported;
        return 2;
    }

    void SetBypassEffect(bool bypass) override {
        AUEffectBase::SetBypassEffect(bypass);
        core_->setBypassed(bypass);
    }

    bool SupportsTail() override { return true; }
    Float64 GetTailTime() override { return 0; }
    Float64 GetLatency() override { return 0; }

    OSStatus ProcessBufferLists(AudioUnitRenderActionFlags &, const AudioBufferList &in, AudioBufferList &out,
                                UInt32 frames) override {
        const UInt32 channels = std::min({in.mNumberBuffers, out.mNumberBuffers, UInt32(ABR_MAX_CHANNELS)});
        const float *planar[ABR_MAX_CHANNELS] = {};
        for (UInt32 c = 0; c < channels; ++c) {
            // Pass-through: in place this is a no-op; otherwise the output is a copy of the input. The silence
            // flag the input set stays as it is.
            const auto *source = static_cast<const float *>(in.mBuffers[c].mData);
            auto *destination = static_cast<float *>(out.mBuffers[c].mData);
            if (source && destination && source != destination) std::memcpy(destination, source, frames * sizeof(float));
            planar[c] = source;
        }
        // The host's callback runs on this thread; hosts implement it for the render thread.
        abr::HostTransport transport;
        Boolean playing = false, changed = false, cycling = false;
        Float64 sample = 0, cycleStart = 0, cycleEnd = 0;
        if (CallHostTransportState(&playing, &changed, &sample, &cycling, &cycleStart, &cycleEnd) == noErr) {
            transport.flags = ABR_TRANSPORT_KNOWN | ABR_TRANSPORT_POSITION | (playing ? uint32_t(ABR_TRANSPORT_PLAYING) : 0u);
            transport.position = int64_t(std::llround(sample));  // a fractional sample count, in some hosts
        }
        core_->process(planar, channels, frames, transport);
        return noErr;
    }

    OSStatus GetPropertyInfo(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element, UInt32 &size,
                             bool &writable) override {
        if (scope == kAudioUnitScope_Global) {
            switch (id) {
            case kAudioUnitProperty_OfflineRender: size = sizeof(UInt32); writable = true; return noErr;
            case kAudioUnitProperty_CocoaUI: size = sizeof(AudioUnitCocoaViewInfo); writable = false; return noErr;
            case abr::kCoreProperty: size = sizeof(abr::CoreReference); writable = false; return noErr;
            case abr::kNameEditedProperty: size = sizeof(UInt32); writable = true; return noErr;
            default: break;
            }
        }
        return AUEffectBase::GetPropertyInfo(id, scope, element, size, writable);
    }

    OSStatus GetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element, void *data) override {
        if (scope == kAudioUnitScope_Global) {
            switch (id) {
            case kAudioUnitProperty_OfflineRender:
                *static_cast<UInt32 *>(data) = offline_ ? 1 : 0;
                return noErr;
            case kAudioUnitProperty_CocoaUI: {
                CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR(ABR_AU_BUNDLE_ID));
                if (!bundle) return kAudioUnitErr_InvalidProperty;
                auto *info = static_cast<AudioUnitCocoaViewInfo *>(data);
                info->mCocoaAUViewBundleLocation = CFBundleCopyBundleURL(bundle);  // released by the host
                info->mCocoaAUViewClass[0] = CFStringCreateWithCString(nullptr, ABR_STRINGIFY(ABR_AU_VIEW_FACTORY),
                                                                        kCFStringEncodingUTF8);
                return noErr;
            }
            case abr::kCoreProperty: {
                // The view factory copies the shared pointer while this unit is alive, and only in this process:
                // a unit hosted in another process (AUHostingService) hands over bytes, not a usable address.
                abr::CoreReference reference{abr::kCoreReferenceMagic, getpid(), &core_};
                std::memcpy(data, &reference, sizeof reference);
                return noErr;
            }
            default: break;
            }
        }
        return AUEffectBase::GetProperty(id, scope, element, data);
    }

    OSStatus SetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element, const void *data,
                         UInt32 size) override {
        if (scope == kAudioUnitScope_Global && id == kAudioUnitProperty_OfflineRender) {
            if (size < sizeof(UInt32)) return kAudioUnitErr_InvalidPropertyValue;
            offline_ = *static_cast<const UInt32 *>(data) != 0;
            core_->setOffline(offline_);
            return noErr;
        }
        if (scope == kAudioUnitScope_Global && id == abr::kNameEditedProperty) {
            // The plugin window changed the source name: the saved state changed with it.
            PropertyChanged(kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0);
            return noErr;
        }
        return AUEffectBase::SetProperty(id, scope, element, data, size);
    }

    void PropertyChanged(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element) override {
        AUEffectBase::PropertyChanged(id, scope, element);
        if (id == kAudioUnitProperty_ContextName) core_->setTrackName(utf8(GetContextName()));
    }

    OSStatus SaveState(CFPropertyListRef *data) override {
        const OSStatus result = AUEffectBase::SaveState(data);
        if (result != noErr || !data || !*data) return result;
        const std::string state = core_->saveState();
        CFDataRef bytes = CFDataCreate(nullptr, reinterpret_cast<const UInt8 *>(state.data()), CFIndex(state.size()));
        CFDictionarySetValue((CFMutableDictionaryRef)*data, kStateKey, bytes);
        CFRelease(bytes);
        return noErr;
    }

    OSStatus RestoreState(CFPropertyListRef data) override {
        const OSStatus result = AUEffectBase::RestoreState(data);
        if (result != noErr) return result;
        if (CFGetTypeID(data) != CFDictionaryGetTypeID()) return noErr;
        auto bytes = static_cast<CFDataRef>(CFDictionaryGetValue(static_cast<CFDictionaryRef>(data), kStateKey));
        if (bytes && CFGetTypeID(bytes) == CFDataGetTypeID()) {
            bool reassigned = false;
            core_->restoreState(std::string(reinterpret_cast<const char *>(CFDataGetBytePtr(bytes)),
                                            size_t(CFDataGetLength(bytes))), &reassigned);
            // A copy of another live insert took an identity of its own: its saved state changed.
            if (reassigned) PropertyChanged(kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0);
        }
        return noErr;
    }

private:
    std::shared_ptr<abr::BridgeCore> core_;
    bool offline_ = false;
};

}  // namespace

AUSDK_COMPONENT_ENTRY(ausdk::AUBaseFactory, BridgeAU)
