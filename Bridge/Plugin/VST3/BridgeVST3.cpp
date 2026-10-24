// Auraliscope Bridge as a VST3 audio effect: a thin wrapper over BridgeCore.
//
// One component (processor and controller together, SingleComponentEffect), one audio input and one output bus
// with the same arrangement: mono, stereo, or an immersive bed from 3.0 to 9.1.6 (see `layoutFor`). The only
// parameter is the host-visible bypass.
//
//   bypass     kIsBypass parameter: audio still passes (the plugin is transparent), transmission stops
//   offline    ProcessSetup::processMode == kOffline: audio passes, nothing is transmitted
//   suspend    setProcessing(false): the host stops calling process; the next live block marks the gap
//   transport  ProcessContext kPlaying and projectTimeSamples are forwarded as metadata; they do not start or
//              stop transmission
//   channel    IInfoListener: the track name, and the host's unique channel ID when it gives one

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
// A test build to load next to an installed Bridge (build-dev-vst3.sh) has a class ID and name of its own.
#ifndef ABR_VST3_UID
#define ABR_VST3_UID 0x03A87F06, 0x69544B23, 0xB85B74F8, 0x248F8E42
#endif
#ifndef ABR_VST3_NAME
#define ABR_VST3_NAME "Auraliscope Bridge"
#endif
const FUID kBridgeUID(ABR_VST3_UID);

// The arrangements the Bridge measures, as Auraliscope speaker roles in the bus's channel order (VST3 orders a
// bus's channels by speaker bit, lowest first): mono, stereo, and every bed with L and R whose speakers all have a
// role: centre, LFE, surrounds, wides and up to six heights (3.0 to 9.1.6, with or without LFE). In a bed that has
// side speakers (Sl Sr: 7.x, 9.x) its Ls Rs are the rear pair; a .2 bed's one height pair, top front or top side, is
// Auraliscope's x.x.2 pair; top side beside other heights is top middle. Speakers without a role (Lc Rc, Cs, Tc, Tfc,
// Trc, Lfe2, bottom, proximity, Ambisonics) make the arrangement unsupported: measuring only some of its channels
// would misstate its loudness, so the host keeps the plugin on an arrangement it can measure.
bool layoutFor(SpeakerArrangement arrangement, abr::ChannelLayout &layout) {
    if (arrangement == SpeakerArr::kMono) { layout = abr::ChannelLayout::mono(); return true; }
    if (arrangement == SpeakerArr::kStereo) { layout = abr::ChannelLayout::stereo(); return true; }
    const int32 count = SpeakerArr::getChannelCount(arrangement);
    if (count < 3 || count > int32(ABR_MAX_CHANNELS)) return false;
    const bool sides = (arrangement & (kSpeakerSl | kSpeakerSr)) != 0;
    const bool upper = (arrangement & (kSpeakerTfl | kSpeakerTfr | kSpeakerTrl | kSpeakerTrr)) != 0;
    uint8_t roles[ABR_MAX_CHANNELS] = {};
    for (int32 index = 0; index < count; ++index) {
        int role = -1;
        switch (SpeakerArr::getSpeaker(arrangement, index)) {
        case kSpeakerL: role = ABR_ROLE_L; break;
        case kSpeakerR: role = ABR_ROLE_R; break;
        case kSpeakerC: role = ABR_ROLE_C; break;
        case kSpeakerLfe: role = ABR_ROLE_LFE; break;
        case kSpeakerLs: role = sides ? ABR_ROLE_LRS : ABR_ROLE_LS; break;
        case kSpeakerRs: role = sides ? ABR_ROLE_RRS : ABR_ROLE_RS; break;
        case kSpeakerSl: role = ABR_ROLE_LS; break;
        case kSpeakerSr: role = ABR_ROLE_RS; break;
        case kSpeakerLw: role = ABR_ROLE_LW; break;
        case kSpeakerRw: role = ABR_ROLE_RW; break;
        case kSpeakerTfl: role = ABR_ROLE_LTF; break;
        case kSpeakerTfr: role = ABR_ROLE_RTF; break;
        case kSpeakerTsl: role = upper ? ABR_ROLE_LTM : ABR_ROLE_LTF; break;
        case kSpeakerTsr: role = upper ? ABR_ROLE_RTM : ABR_ROLE_RTF; break;
        case kSpeakerTrl: role = ABR_ROLE_LTR; break;
        case kSpeakerTrr: role = ABR_ROLE_RTR; break;
        default: break;
        }
        if (role < 0) return false;
        roles[index] = uint8_t(role);
    }
    layout = abr::ChannelLayout::speakers(roles, uint32_t(count));
    return layout.valid();
}

// The view keeps the core alive through its own reference, and reaches the component only through `nameEdited`,
// which holds a counted reference too: a host that releases the component before the view cannot leave either
// pointing at freed memory.
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

    // No exception may reach the host: without memory for the ring the factory reports failure instead.
    static FUnknown *createInstance(void *) {
        try {
            return static_cast<IAudioProcessor *>(new BridgeVST3);
        } catch (...) {
            return nullptr;
        }
    }

    tresult PLUGIN_API initialize(FUnknown *context) override {
        const tresult result = SingleComponentEffect::initialize(context);
        if (result != kResultOk) return result;
        addAudioInput(STR16("Input"), SpeakerArr::kStereo);
        addAudioOutput(STR16("Output"), SpeakerArr::kStereo);
        parameters.addParameter(STR16("Bypass"), nullptr, 1, 0,
                                ParameterInfo::kCanAutomate | ParameterInfo::kIsBypass, kBypassID);
        return kResultOk;
    }

    // Any arrangement `layoutFor` measures, the same on both sides. Offered a measurable input with another output,
    // the plugin takes the input's arrangement on both sides and declines, so the host reads that back.
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement *inputs, int32 numIns, SpeakerArrangement *outputs,
                                          int32 numOuts) override {
        abr::ChannelLayout layout;
        if (numIns != 1 || numOuts != 1 || !inputs || !outputs || !layoutFor(inputs[0], layout)) return kResultFalse;
        removeAudioBusses();
        addAudioInput(STR16("Input"), inputs[0]);
        addAudioOutput(STR16("Output"), inputs[0]);
        return inputs[0] == outputs[0] ? kResultTrue : kResultFalse;
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
            abr::ChannelLayout layout;
            if (!layoutFor(arrangement, layout))
                layout = abr::ChannelLayout::standard(uint32(SpeakerArr::getChannelCount(arrangement)));
            core_->configure(processSetup.sampleRate, layout, uint32(processSetup.maxSamplesPerBlock));
            core_->setOffline(offline_);
        }
        core_->setActive(state);
        return kResultOk;
    }

    // Not a break by itself: REAPER, for one, toggles processing around every locate and loop without any audio
    // going missing. A real stop is seen by the core as time passing between process calls.
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
        abr::HostTransport transport;
        if (data.processContext) {
            // projectTimeSamples is always valid (ivstprocesscontext.h).
            transport.flags = ABR_TRANSPORT_KNOWN | ABR_TRANSPORT_POSITION;
            if (data.processContext->state & ProcessContext::kPlaying) transport.flags |= ABR_TRANSPORT_PLAYING;
            transport.position = data.processContext->projectTimeSamples;
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
        bool reassigned = false;
        if (!core_->restoreState(text, &reassigned)) return kResultFalse;
        const bool bypass = text.find("\nbypass=1") != std::string::npos;
        core_->setBypassed(bypass);
        setParamNormalized(kBypassID, bypass ? 1 : 0);
        // A copy of another live insert took an identity of its own: the project must save it.
        if (reassigned) markDirty();
        return kResultOk;
    }

    IPlugView *PLUGIN_API createView(FIDString name) override {
        if (!name || std::strcmp(name, ViewType::kEditor) != 0) return nullptr;
        IPtr<BridgeVST3> self(this);  // counted: see BridgeView
        return new BridgeView(core_, [self] { self->markDirty(); });  // the name is saved with the project
    }

    // The host's channel or track name, used when the user has not named the source, and its unique channel ID,
    // which tells duplicated tracks apart when they carry the same name.
    tresult PLUGIN_API setChannelContextInfos(IAttributeList *list) override {
        if (!list) return kResultFalse;
        String128 value{};
        if (list->getString(ChannelContext::kChannelNameKey, value, sizeof value) == kResultTrue)
            core_->setTrackName(VST3::StringConvert::convert(reinterpret_cast<const char16_t *>(value)));
        String128 id{};
        if (list->getString(ChannelContext::kChannelUIDKey, id, sizeof id) == kResultTrue)
            core_->setChannelID(VST3::StringConvert::convert(reinterpret_cast<const char16_t *>(id)));
        return kResultOk;
    }

    void markDirty() {
        FUnknownPtr<IComponentHandler2> handler(componentHandler);
        if (handler) handler->setDirty(true);
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
    DEF_CLASS2(INLINE_UID_FROM_FUID(kBridgeUID), PClassInfo::kManyInstances, kVstAudioEffectClass, ABR_VST3_NAME,
               0, "Fx|Analyzer", ABR_PLUGIN_VERSION, kVstVersionString, BridgeVST3::createInstance)
END_FACTORY
