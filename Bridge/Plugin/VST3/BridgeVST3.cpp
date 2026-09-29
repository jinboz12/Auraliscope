// Auraliscope Bridge as a VST3 audio effect: a thin wrapper over BridgeCore.
//
// One component (processor and controller together, SingleComponentEffect), one audio input and one output bus
// with the same arrangement, mono or stereo. The only parameter is the host-visible bypass.
//
//   bypass     kIsBypass parameter: audio still passes (the plugin is transparent), transmission stops
//   offline    ProcessSetup::processMode == kOffline: audio passes, nothing is transmitted
//   transport  ProcessContext kPlaying is forwarded as metadata; it does not start or stop transmission

#include <cstring>
#include <memory>
#include <string>

#include "base/source/fstreamer.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstchannelcontextinfo.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/vsttypes.h"
#include "public.sdk/source/common/pluginview.h"
#include "public.sdk/source/main/pluginfactory.h"
#include "public.sdk/source/vst/utility/stringconvert.h"
#include "public.sdk/source/vst/vstsinglecomponenteffect.h"

#include "BridgeCore.h"
#include "BridgeEditor.h"

#ifndef ABR_PLUGIN_VERSION
#define ABR_PLUGIN_VERSION "0.1.0"
#endif

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

constexpr ParamID kBypassID = 0;
const FUID kBridgeUID(0x03A87F06, 0x69544B23, 0xB85B74F8, 0x248F8E42);

class BridgeView : public CPluginView {
public:
    BridgeView(std::shared_ptr<abr::BridgeCore> core, std::function<void()> nameEdited)
        : core_(std::move(core)), nameEdited_(std::move(nameEdited)) {
        ViewRect size(0, 0, abr::kEditorWidth, abr::kEditorHeight);
        setRect(size);
    }
    ~BridgeView() override { close(); }

    tresult PLUGIN_API isPlatformTypeSupported(FIDString type) override {
        return std::strcmp(type, kPlatformTypeNSView) == 0 ? kResultTrue : kResultFalse;
    }
    void attachedToParent() override {
        view_ = abr::createEditorView(core_, nameEdited_, "VST3");
        abr::attachEditorView(view_, systemWindow);
    }
    void removedFromParent() override { close(); }

private:
    void close() {
        if (view_) abr::destroyEditorView(view_);
        view_ = nullptr;
    }
    std::shared_ptr<abr::BridgeCore> core_;
    std::function<void()> nameEdited_;
    void *view_ = nullptr;
};

class BridgeVST3 : public SingleComponentEffect, public ChannelContext::IInfoListener {
public:
    BridgeVST3() : core_(std::make_shared<abr::BridgeCore>(ABR_FORMAT_VST3)) {}

    static FUnknown *createInstance(void *) { return static_cast<IAudioProcessor *>(new BridgeVST3); }

    tresult PLUGIN_API initialize(FUnknown *context) override {
        const tresult result = SingleComponentEffect::initialize(context);
        if (result != kResultOk) return result;
        addAudioInput(STR16("Input"), SpeakerArr::kStereo);
        addAudioOutput(STR16("Output"), SpeakerArr::kStereo);
        parameters.addParameter(STR16("Bypass"), nullptr, 1, 0,
                                ParameterInfo::kCanAutomate | ParameterInfo::kIsBypass, kBypassID);
        return kResultOk;
    }

    // Mono or stereo, the same on both sides.
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement *inputs, int32 numIns, SpeakerArrangement *outputs,
                                          int32 numOuts) override {
        if (numIns != 1 || numOuts != 1 || inputs[0] != outputs[0]
            || (inputs[0] != SpeakerArr::kMono && inputs[0] != SpeakerArr::kStereo)) return kResultFalse;
        removeAudioBusses();
        addAudioInput(STR16("Input"), inputs[0]);
        addAudioOutput(STR16("Output"), outputs[0]);
        return kResultTrue;
    }

    tresult PLUGIN_API canProcessSampleSize(int32 size) override {
        return size == kSample32 ? kResultTrue : kResultFalse;
    }

    tresult PLUGIN_API setupProcessing(ProcessSetup &setup) override {
        offline_ = setup.processMode == kOffline;
        return SingleComponentEffect::setupProcessing(setup);
    }

    tresult PLUGIN_API setActive(TBool state) override {
        if (state) {
            SpeakerArrangement arrangement = SpeakerArr::kStereo;
            getBusArrangement(kInput, 0, arrangement);
            core_->configure(processSetup.sampleRate, uint32(SpeakerArr::getChannelCount(arrangement)),
                             uint32(processSetup.maxSamplesPerBlock));
            core_->setOffline(offline_);
        }
        core_->setActive(state);
        return kResultOk;
    }

    tresult PLUGIN_API setProcessing(TBool) override { return kResultOk; }

    tresult PLUGIN_API process(ProcessData &data) override {
        if (IParameterChanges *changes = data.inputParameterChanges) {
            for (int32 i = 0; i < changes->getParameterCount(); ++i) {
                IParamValueQueue *queue = changes->getParameterData(i);
                ParamValue value;
                int32 offset;
                if (queue && queue->getParameterId() == kBypassID && queue->getPointCount() > 0
                    && queue->getPoint(queue->getPointCount() - 1, offset, value) == kResultOk) {
                    core_->setBypassed(value >= 0.5);
                }
            }
        }
        if (data.numInputs < 1 || data.numOutputs < 1 || data.numSamples <= 0) return kResultOk;
        AudioBusBuffers &in = data.inputs[0], &out = data.outputs[0];
        const int32 channels = std::min(in.numChannels, out.numChannels);
        // Pass-through: the output is the input, bit for bit, whatever else happens.
        for (int32 c = 0; c < channels; ++c) {
            if (in.channelBuffers32[c] != out.channelBuffers32[c])
                std::memcpy(out.channelBuffers32[c], in.channelBuffers32[c], size_t(data.numSamples) * sizeof(float));
        }
        out.silenceFlags = in.silenceFlags;
        uint32 transport = 0;
        if (data.processContext) {
            transport = ABR_TRANSPORT_KNOWN;
            if (data.processContext->state & ProcessContext::kPlaying) transport |= ABR_TRANSPORT_PLAYING;
        }
        core_->process(in.channelBuffers32, uint32(channels), uint32(data.numSamples), transport);
        return kResultOk;
    }

    // Project state: the core's text (name, persistent ID) plus the bypass switch.
    tresult PLUGIN_API getState(IBStream *state) override {
        if (!state) return kInvalidArgument;
        const std::string text = core_->saveState() + (core_->bypassed() ? "bypass=1\n" : "bypass=0\n");
        int32 written = 0;
        return state->write(const_cast<char *>(text.data()), int32(text.size()), &written);
    }

    tresult PLUGIN_API setState(IBStream *state) override {
        if (!state) return kInvalidArgument;
        std::string text;
        char buffer[512];
        int32 read = 0;
        while (state->read(buffer, sizeof buffer, &read) == kResultOk && read > 0) {
            text.append(buffer, size_t(read));
            if (text.size() > 64 * 1024) return kResultFalse;
        }
        if (!core_->restoreState(text)) return kResultFalse;
        const bool bypass = text.find("\nbypass=1") != std::string::npos;
        core_->setBypassed(bypass);
        setParamNormalized(kBypassID, bypass ? 1 : 0);
        return kResultOk;
    }

    IPlugView *PLUGIN_API createView(FIDString name) override {
        if (!name || std::strcmp(name, ViewType::kEditor) != 0) return nullptr;
        return new BridgeView(core_, [this] {
            // The name is saved with the project: tell the host it changed.
            FUnknownPtr<IComponentHandler2> handler(componentHandler);
            if (handler) handler->setDirty(true);
        });
    }

    // The host's channel or track name, used when the user has not named the source.
    tresult PLUGIN_API setChannelContextInfos(IAttributeList *list) override {
        if (!list) return kResultFalse;
        String128 name{};
        if (list->getString(ChannelContext::kChannelNameKey, name, sizeof name) == kResultTrue)
            core_->setTrackName(VST3::StringConvert::convert(reinterpret_cast<const char16_t *>(name)));
        return kResultOk;
    }

    OBJ_METHODS(BridgeVST3, SingleComponentEffect)
    DEFINE_INTERFACES
        DEF_INTERFACE(ChannelContext::IInfoListener)
    END_DEFINE_INTERFACES(SingleComponentEffect)
    REFCOUNT_METHODS(SingleComponentEffect)

private:
    std::shared_ptr<abr::BridgeCore> core_;
    bool offline_ = false;
};

}  // namespace

BEGIN_FACTORY_DEF("JINBOZ", "", "")
    DEF_CLASS2(INLINE_UID_FROM_FUID(kBridgeUID), PClassInfo::kManyInstances, kVstAudioEffectClass, "Auraliscope Bridge",
               0, "Fx|Analyzer", ABR_PLUGIN_VERSION, kVstVersionString, BridgeVST3::createInstance)
END_FACTORY
