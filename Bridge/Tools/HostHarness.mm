// A deterministic test host for the real Auraliscope Bridge binaries (not a product: no third-party plugins).
//
// Loads the VST3 bundle or the installed AU, plays a known signal through one or more instances on a thread with
// Core Audio's real-time policy, and checks that every output block equals its input bit for bit. Phases switch
// the instances between live processing, host bypass, offline render, idle (no process calls) and new formats,
// so the receiving side (Auraliscope Labs or the probe) can be checked against a known sequence.
//
//   HostHarness --format vst3|au [--bundle <path.vst3>] [--channels 1|2] [--rate 48000] [--block 256]
//               [--instances n] [--copies n] [--name <base>] [--id <32 hex>] [--phases live:4,bypass:2,live:2]
//               [--editor-snapshot <file.png>] [--editor-seconds s]
//
// Phases: live:s, bypass:s, offline:s, idle:s, rate=<hz>:s (reconfigure, then live), ch=<n>:s (likewise),
// reidentify:s (every instance is given its own state back with a new identity, as a host restoring a project
// into already-running plugins does; each reconnects under the same session, then live).
// --copies n: after the instances, n more restored from instance 1's saved state while it is live, as a host
// duplicating a track does.
// Instance i plays L = 0.5·2⁻ⁱ·sin(2π·997·n/fs) and R = 0.25·2⁻ⁱ·sin(2π·1499·n/fs), n counting live frames
// only (bypassed, offline and idle blocks do not advance it), so its stream position equals n.

#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AUCocoaUIView.h>
#import <Cocoa/Cocoa.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "base/source/fstreamer.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"
#include "public.sdk/source/vst/hosting/plugprovider.h"
#include "public.sdk/source/vst/hosting/processdata.h"

using namespace Steinberg;

// The SDK's hosting code expects the host executable to define this (the validator does the same).
void *moduleHandle = nullptr;

namespace {

struct Options {
    std::string format = "vst3", bundle, name = "Harness", id, snapshot;
    uint32_t channels = 2, block = 256, instances = 1, copies = 0;
    double rate = 48000, editorSeconds = 2;
    std::string phases = "live:5";
    bool clickConnect = false;  // press the plugin window's connect button, as a user would
};

// Every button and label under `view`, depth first.
void collect(NSView *view, NSMutableArray<NSButton *> *buttons, NSMutableArray<NSString *> *texts) {
    for (NSView *child in view.subviews) {
        if ([child isKindOfClass:NSButton.class]) [buttons addObject:(NSButton *)child];
        else if ([child isKindOfClass:NSTextField.class] && ((NSTextField *)child).stringValue.length)
            [texts addObject:((NSTextField *)child).stringValue];
        collect(child, buttons, texts);
    }
}

enum class Mode { live, bypass, offline, idle };

struct Phase {
    Mode mode = Mode::live;
    bool reidentify = false;
    double seconds = 1;
    double rate = 0;        // > 0: reconfigure to this rate first
    uint32_t channels = 0;  // > 0: reconfigure to this channel count first
    std::string label;
};

float signal(uint32_t instance, uint32_t channel, uint64_t n, double rate) {
    const double scale = std::ldexp(1.0, -int(instance));
    const double frequency = channel == 0 ? 997.0 : 1499.0, amplitude = (channel == 0 ? 0.5 : 0.25) * scale;
    return float(amplitude * std::sin(2 * M_PI * frequency * double(n) / rate));
}

std::string stateText(const Options &options, uint32_t instance) {
    std::string text = "AuraliscopeBridge 1\n";
    if (!options.id.empty()) text += "id=" + options.id + "\n";
    text += "name=" + options.name + (options.instances > 1 ? " " + std::to_string(instance + 1) : "") + "\n";
    return text;
}

// One plugin instance, whatever its format.
class Instance {
public:
    virtual ~Instance() = default;
    virtual bool configure(double rate, uint32_t channels, uint32_t block) = 0;
    virtual void setMode(Mode mode) = 0;
    // Processes `in` into `out` (planar). Returns false on a host-side error.
    virtual bool process(float *const *in, float *const *out, uint32_t channels, uint32_t frames, uint64_t sampleTime) = 0;
    virtual NSView *createEditor() = 0;
    virtual void closeEditor() = 0;
    // The plugin's own project state (the text Auraliscope Bridge saves), and restoring one, as a host does.
    virtual std::string saveState() = 0;
    virtual void restoreState(const std::string &state) = 0;
};

// `state` with its identity replaced by a new random one.
std::string reidentified(const std::string &state) {
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof bytes);
    char id[33];
    for (int i = 0; i < 16; ++i) std::snprintf(id + 2 * i, 3, "%02X", bytes[i]);
    const size_t at = state.find("\nid=");
    return at == std::string::npos ? state : state.substr(0, at + 4) + id + state.substr(at + 4 + 32);
}

// ---- VST3 -----------------------------------------------------------------------------------------------------

class VST3Instance : public Instance {
public:
    static VST3::Hosting::Module::Ptr module;

    VST3Instance(const Options &options, uint32_t index) {
        std::string error;
        if (!module) module = VST3::Hosting::Module::create(options.bundle, error);
        if (!module) { std::fprintf(stderr, "cannot load %s: %s\n", options.bundle.c_str(), error.c_str()); return; }
        static Vst::HostApplication host;
        Vst::PluginContextFactory::instance().setPluginContext(&host);
        for (auto &info : module->getFactory().classInfos()) {
            if (info.category() != kVstAudioEffectClass) continue;
            provider_ = owned(new Vst::PlugProvider(module->getFactory(), info, true));
            break;
        }
        if (!provider_ || !provider_->initialize()) { std::fprintf(stderr, "cannot instantiate the VST3 class\n"); provider_ = nullptr; return; }
        component_ = provider_->getComponentPtr();
        controller_ = provider_->getControllerPtr();
        processor_ = U::cast<Vst::IAudioProcessor>(component_);
        const std::string state = stateText(options, index);
        MemoryStream stream;
        int32 written = 0;
        stream.write(const_cast<char *>(state.data()), int32(state.size()), &written);
        stream.seek(0, IBStream::kIBSeekSet, nullptr);
        component_->setState(&stream);
        stream.seek(0, IBStream::kIBSeekSet, nullptr);
        if (controller_) controller_->setComponentState(&stream);
    }

    bool ok() const { return processor_ != nullptr; }

    std::string saveState() override {
        MemoryStream stream;
        component_->getState(&stream);
        return std::string(stream.getData(), size_t(stream.getSize()));
    }

    void restoreState(const std::string &state) override {
        MemoryStream stream;
        int32 written = 0;
        stream.write(const_cast<char *>(state.data()), int32(state.size()), &written);
        stream.seek(0, IBStream::kIBSeekSet, nullptr);
        component_->setState(&stream);
    }

    bool configure(double rate, uint32_t channels, uint32_t block) override {
        if (active_) { processor_->setProcessing(false); component_->setActive(false); active_ = false; }
        Vst::SpeakerArrangement arrangement = channels == 1 ? Vst::SpeakerArr::kMono : Vst::SpeakerArr::kStereo;
        if (processor_->setBusArrangements(&arrangement, 1, &arrangement, 1) != kResultTrue) return false;
        component_->activateBus(Vst::kAudio, Vst::kInput, 0, true);
        component_->activateBus(Vst::kAudio, Vst::kOutput, 0, true);
        Vst::ProcessSetup setup{offline_ ? Vst::kOffline : Vst::kRealtime, Vst::kSample32, int32(block), rate};
        if (processor_->setupProcessing(setup) != kResultOk) return false;
        if (component_->setActive(true) != kResultOk) return false;
        processor_->setProcessing(true);
        active_ = true;
        rate_ = rate; channels_ = channels; block_ = block;
        data_ = std::make_unique<Vst::HostProcessData>();
        return data_->prepare(*component_, int32(block), Vst::kSample32);
    }

    void setMode(Mode mode) override {
        const bool offline = mode == Mode::offline;
        if (offline != offline_) {
            offline_ = offline;  // ProcessSetup changes only while inactive
            configure(rate_, channels_, block_);
        }
        const bool bypass = mode == Mode::bypass;
        if (bypass != bypass_) { bypass_ = bypass; pendingBypass_ = true; }
    }

    bool process(float *const *in, float *const *out, uint32_t channels, uint32_t frames, uint64_t) override {
        Vst::ParameterChanges changes;
        if (pendingBypass_) {
            int32 index = 0;
            if (Vst::IParamValueQueue *queue = changes.addParameterData(0, index)) queue->addPoint(0, bypass_ ? 1 : 0, index);
            pendingBypass_ = false;
        }
        data_->inputParameterChanges = &changes;
        data_->numSamples = int32(frames);
        for (uint32_t c = 0; c < channels; ++c) std::memcpy(data_->inputs[0].channelBuffers32[c], in[c], frames * sizeof(float));
        const tresult result = processor_->process(*data_);
        data_->inputParameterChanges = nullptr;
        for (uint32_t c = 0; c < channels; ++c) std::memcpy(out[c], data_->outputs[0].channelBuffers32[c], frames * sizeof(float));
        return result == kResultOk;
    }

    NSView *createEditor() override {
        if (!controller_) return nil;
        view_ = owned(controller_->createView(Vst::ViewType::kEditor));
        if (!view_) return nil;
        ViewRect rect;
        view_->getSize(&rect);
        NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, rect.getWidth(), rect.getHeight())];
        if (view_->attached((__bridge void *)container, kPlatformTypeNSView) != kResultOk) { view_ = nullptr; return nil; }
        return container;
    }

    void closeEditor() override {
        if (view_) view_->removed();
        view_ = nullptr;
    }

    ~VST3Instance() override {
        closeEditor();
        if (active_) { processor_->setProcessing(false); component_->setActive(false); }
        data_.reset();
        processor_ = nullptr;
        controller_ = nullptr;
        component_ = nullptr;
        provider_ = nullptr;
    }

private:
    IPtr<Vst::PlugProvider> provider_;
    IPtr<Vst::IComponent> component_;
    IPtr<Vst::IEditController> controller_;
    IPtr<Vst::IAudioProcessor> processor_;
    IPtr<IPlugView> view_;
    std::unique_ptr<Vst::HostProcessData> data_;
    bool active_ = false, offline_ = false, bypass_ = false, pendingBypass_ = false;
    double rate_ = 48000;
    uint32_t channels_ = 2, block_ = 256;
};
VST3::Hosting::Module::Ptr VST3Instance::module;

// ---- AU -------------------------------------------------------------------------------------------------------

class AUInstance : public Instance {
public:
    AUInstance(const Options &options, uint32_t index) {
        AudioComponentDescription description{kAudioUnitType_Effect, 'Abrg', 'Jnbz', 0, 0};
        AudioComponent component = AudioComponentFindNext(nullptr, &description);
        if (!component || AudioComponentInstanceNew(component, &unit_) != noErr) {
            std::fprintf(stderr, "cannot instantiate aufx Abrg Jnbz (installed?)\n");
            unit_ = nullptr;
            return;
        }
        AURenderCallbackStruct callback{input, this};
        AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback);
        // The project state carries the name: read ClassInfo, add ours, write it back as a host restoring would.
        CFPropertyListRef info = nullptr;
        UInt32 size = sizeof info;
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info, &size) == noErr && info) {
            CFMutableDictionaryRef dictionary = CFDictionaryCreateMutableCopy(nullptr, 0, (CFDictionaryRef)info);
            const std::string state = stateText(options, index);
            CFDataRef bytes = CFDataCreate(nullptr, (const UInt8 *)state.data(), CFIndex(state.size()));
            CFDictionarySetValue(dictionary, CFSTR("com.jinboz.AuraliscopeBridge.state"), bytes);
            CFPropertyListRef updated = dictionary;
            AudioUnitSetProperty(unit_, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &updated, sizeof updated);
            CFRelease(bytes);
            CFRelease(dictionary);
            CFRelease(info);
        }
    }

    bool ok() const { return unit_ != nullptr; }

    std::string saveState() override {
        CFPropertyListRef info = nullptr;
        UInt32 size = sizeof info;
        std::string state;
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info, &size) == noErr && info) {
            auto bytes = (CFDataRef)CFDictionaryGetValue((CFDictionaryRef)info, CFSTR("com.jinboz.AuraliscopeBridge.state"));
            if (bytes) state.assign((const char *)CFDataGetBytePtr(bytes), size_t(CFDataGetLength(bytes)));
            CFRelease(info);
        }
        return state;
    }

    void restoreState(const std::string &state) override {
        CFPropertyListRef info = nullptr;
        UInt32 size = sizeof info;
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info, &size) != noErr || !info) return;
        CFMutableDictionaryRef dictionary = CFDictionaryCreateMutableCopy(nullptr, 0, (CFDictionaryRef)info);
        CFDataRef bytes = CFDataCreate(nullptr, (const UInt8 *)state.data(), CFIndex(state.size()));
        CFDictionarySetValue(dictionary, CFSTR("com.jinboz.AuraliscopeBridge.state"), bytes);
        CFPropertyListRef updated = dictionary;
        AudioUnitSetProperty(unit_, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &updated, sizeof updated);
        CFRelease(bytes);
        CFRelease(dictionary);
        CFRelease(info);
    }

    bool configure(double rate, uint32_t channels, uint32_t block) override {
        AudioUnitUninitialize(unit_);
        AudioStreamBasicDescription format{rate, kAudioFormatLinearPCM,
                                           kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                           4, 1, 4, channels, 32, 0};
        for (AudioUnitScope scope : {kAudioUnitScope_Input, kAudioUnitScope_Output})
            if (AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, scope, 0, &format, sizeof format) != noErr) return false;
        UInt32 frames = block;
        AudioUnitSetProperty(unit_, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, sizeof frames);
        channels_ = channels;
        list_.reset(static_cast<AudioBufferList *>(calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * channels)));
        return AudioUnitInitialize(unit_) == noErr;
    }

    void setMode(Mode mode) override {
        UInt32 bypass = mode == Mode::bypass, offline = mode == Mode::offline;
        AudioUnitSetProperty(unit_, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &bypass, sizeof bypass);
        AudioUnitSetProperty(unit_, kAudioUnitProperty_OfflineRender, kAudioUnitScope_Global, 0, &offline, sizeof offline);
    }

    bool process(float *const *in, float *const *out, uint32_t channels, uint32_t frames, uint64_t sampleTime) override {
        input_ = in;
        list_->mNumberBuffers = channels;
        for (uint32_t c = 0; c < channels; ++c) list_->mBuffers[c] = {1, frames * uint32_t(sizeof(float)), nullptr};
        AudioTimeStamp stamp{};
        stamp.mSampleTime = double(sampleTime);
        stamp.mFlags = kAudioTimeStampSampleTimeValid;
        AudioUnitRenderActionFlags flags = 0;
        const OSStatus status = AudioUnitRender(unit_, &flags, &stamp, 0, frames, list_.get());
        for (uint32_t c = 0; c < channels && status == noErr; ++c) std::memcpy(out[c], list_->mBuffers[c].mData, frames * sizeof(float));
        return status == noErr;
    }

    NSView *createEditor() override {
        AudioUnitCocoaViewInfo info{};
        UInt32 size = sizeof info;
        const OSStatus status = AudioUnitGetProperty(unit_, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &info, &size);
        if (status != noErr) { std::fprintf(stderr, "[harness] CocoaUI property: OSStatus %d\n", int(status)); return nil; }
        NSBundle *bundle = [NSBundle bundleWithURL:(__bridge_transfer NSURL *)info.mCocoaAUViewBundleLocation];
        NSString *className = (__bridge_transfer NSString *)info.mCocoaAUViewClass[0];
        Class factoryClass = [bundle classNamed:className] ?: NSClassFromString(className);
        if (!factoryClass) { std::fprintf(stderr, "[harness] view factory %s not found in %s\n", className.UTF8String, bundle.bundlePath.UTF8String); return nil; }
        id<AUCocoaUIBase> factory = [[factoryClass alloc] init];
        editor_ = [factory uiViewForAudioUnit:unit_ withSize:NSMakeSize(440, 466)];
        if (!editor_) std::fprintf(stderr, "[harness] the view factory returned no view\n");
        return editor_;
    }

    void closeEditor() override {
        [editor_ removeFromSuperview];
        editor_ = nil;
    }

    ~AUInstance() override {
        closeEditor();
        if (unit_) {
            AudioUnitUninitialize(unit_);
            AudioComponentInstanceDispose(unit_);
        }
    }

private:
    static OSStatus input(void *context, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
                          AudioBufferList *data) {
        auto *self = static_cast<AUInstance *>(context);
        for (UInt32 c = 0; c < data->mNumberBuffers && c < self->channels_; ++c) {
            if (data->mBuffers[c].mData) std::memcpy(data->mBuffers[c].mData, self->input_[c], frames * sizeof(float));
            else data->mBuffers[c].mData = self->input_[c];
        }
        return noErr;
    }

    AudioUnit unit_ = nullptr;
    uint32_t channels_ = 2;
    float *const *input_ = nullptr;
    std::unique_ptr<AudioBufferList, decltype(&free)> list_{nullptr, &free};
    NSView *editor_ = nil;
};

void makeRealTime(double periodSeconds) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    const double ticks = 1e9 * timebase.denom / timebase.numer;
    thread_time_constraint_policy_data_t policy{uint32_t(periodSeconds * ticks), uint32_t(0.001 * ticks),
                                                uint32_t(std::max(0.002, periodSeconds * 0.9) * ticks), 1};
    thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&policy,
                      THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

std::vector<Phase> parsePhases(const std::string &text) {
    std::vector<Phase> phases;
    size_t start = 0;
    while (start < text.size()) {
        size_t end = text.find(',', start);
        if (end == std::string::npos) end = text.size();
        const std::string item = text.substr(start, end - start);
        const size_t colon = item.rfind(':');
        Phase phase;
        phase.label = item;
        const std::string kind = item.substr(0, colon);
        phase.seconds = colon == std::string::npos ? 1 : std::atof(item.c_str() + colon + 1);
        if (kind == "bypass") phase.mode = Mode::bypass;
        else if (kind == "offline") phase.mode = Mode::offline;
        else if (kind == "idle") phase.mode = Mode::idle;
        else if (kind == "reidentify") phase.reidentify = true;
        else if (kind.rfind("rate=", 0) == 0) phase.rate = std::atof(kind.c_str() + 5);
        else if (kind.rfind("ch=", 0) == 0) phase.channels = uint32_t(std::atoi(kind.c_str() + 3));
        phases.push_back(phase);
        start = end + 1;
    }
    return phases;
}

}  // namespace

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Options options;
        for (int i = 1; i + 1 < argc; i += 2) {
            const std::string key = argv[i], value = argv[i + 1];
            if (key == "--format") options.format = value;
            else if (key == "--bundle") options.bundle = value;
            else if (key == "--channels") options.channels = uint32_t(std::atoi(value.c_str()));
            else if (key == "--rate") options.rate = std::atof(value.c_str());
            else if (key == "--block") options.block = uint32_t(std::atoi(value.c_str()));
            else if (key == "--instances") options.instances = uint32_t(std::atoi(value.c_str()));
            else if (key == "--copies") options.copies = uint32_t(std::atoi(value.c_str()));
            else if (key == "--name") options.name = value;
            else if (key == "--id") options.id = value;
            else if (key == "--phases") options.phases = value;
            else if (key == "--editor-snapshot") options.snapshot = value;
            else if (key == "--editor-seconds") options.editorSeconds = std::atof(value.c_str());
            else if (key == "--click-connect") options.clickConnect = value == "1";
            else { std::fprintf(stderr, "unknown option %s\n", key.c_str()); return 2; }
        }
        [NSApplication sharedApplication];

        std::vector<std::unique_ptr<Instance>> instances;
        for (uint32_t i = 0; i < options.instances; ++i) {
            if (options.format == "au") {
                auto instance = std::make_unique<AUInstance>(options, i);
                if (!instance->ok()) return 1;
                instances.push_back(std::move(instance));
            } else {
                auto instance = std::make_unique<VST3Instance>(options, i);
                if (!instance->ok()) return 1;
                instances.push_back(std::move(instance));
            }
        }
        // Duplicated tracks: new instances given instance 1's saved state while it is live.
        for (uint32_t i = 0; i < options.copies && !instances.empty(); ++i) {
            const std::string state = instances[0]->saveState();
            std::unique_ptr<Instance> copy;
            if (options.format == "au") copy = std::make_unique<AUInstance>(options, options.instances + i);
            else copy = std::make_unique<VST3Instance>(options, options.instances + i);
            copy->restoreState(state);
            instances.push_back(std::move(copy));
        }
        double rate = options.rate;
        uint32_t channels = options.channels;
        for (auto &instance : instances)
            if (!instance->configure(rate, channels, options.block)) { std::fprintf(stderr, "configure failed\n"); return 1; }
        std::printf("[harness] %s, %u instance(s) \"%s\", %.0f Hz, %u ch, block %u\n", options.format.c_str(),
                    options.instances, options.name.c_str(), rate, channels, options.block);
        std::fflush(stdout);

        std::atomic<bool> done{false};
        std::atomic<long> mismatches{0}, errors{0};
        std::thread audio([&] {
            makeRealTime(options.block / rate);
            std::vector<std::vector<float>> in(2, std::vector<float>(options.block)), out(2, std::vector<float>(options.block));
            float *inputs[2] = {in[0].data(), in[1].data()}, *outputs[2] = {out[0].data(), out[1].data()};
            std::vector<uint64_t> position(instances.size(), 0);
            uint64_t sampleTime = 0;
            for (const Phase &phase : parsePhases(options.phases)) {
                if (phase.rate > 0 || phase.channels > 0) {
                    if (phase.rate > 0) rate = phase.rate;
                    if (phase.channels > 0) channels = phase.channels;
                    for (auto &instance : instances) instance->configure(rate, channels, options.block);
                    std::fill(position.begin(), position.end(), 0);  // a new format epoch: compare from its start
                }
                if (phase.reidentify)
                    for (auto &instance : instances) instance->restoreState(reidentified(instance->saveState()));
                for (auto &instance : instances) instance->setMode(phase.mode == Mode::idle ? Mode::live : phase.mode);
                const uint64_t blocks = uint64_t(phase.seconds * rate / options.block);
                int64_t worst = 0;
                long phaseMismatches = 0;
                auto next = std::chrono::steady_clock::now();
                const auto period = std::chrono::duration<double>(options.block / rate);
                for (uint64_t b = 0; b < blocks; ++b) {
                    if (phase.mode != Mode::idle) {
                        for (size_t i = 0; i < instances.size(); ++i) {
                            // Offline and bypassed audio is still the programme: fill it the same way, but only live
                            // blocks advance the stream position the receiver sees.
                            for (uint32_t c = 0; c < channels; ++c)
                                for (uint32_t f = 0; f < options.block; ++f)
                                    in[c][f] = signal(uint32_t(i), c, position[i] + f, rate);
                            const auto before = std::chrono::steady_clock::now();
                            if (!instances[i]->process(inputs, outputs, channels, options.block, sampleTime)) errors++;
                            worst = std::max<int64_t>(worst, std::chrono::duration_cast<std::chrono::nanoseconds>(
                                                                 std::chrono::steady_clock::now() - before).count());
                            for (uint32_t c = 0; c < channels; ++c)
                                if (std::memcmp(in[c].data(), out[c].data(), options.block * sizeof(float)) != 0) ++phaseMismatches;
                            if (phase.mode == Mode::live) position[i] += options.block;
                        }
                        sampleTime += options.block;
                    }
                    next += std::chrono::duration_cast<std::chrono::steady_clock::duration>(period);
                    std::this_thread::sleep_until(next);
                }
                mismatches += phaseMismatches;
                std::printf("[harness] phase %-12s %.1f s at %.0f Hz, %u ch: output %s input, worst process %.1f µs\n",
                            phase.label.c_str(), phase.seconds, rate, channels,
                            phaseMismatches ? "DIFFERS FROM" : "identical to", worst / 1000.0);
                std::fflush(stdout);
            }
            done = true;
        });

        if (!options.snapshot.empty()) {
            // Open the first instance's editor in a window, capture it, then close it while audio keeps running.
            NSView *editor = instances[0]->createEditor();
            if (editor) {
                NSWindow *window = [[NSWindow alloc] initWithContentRect:editor.frame styleMask:NSWindowStyleMaskTitled
                                                                 backing:NSBackingStoreBuffered defer:NO];
                window.releasedWhenClosed = NO;
                window.title = @"Auraliscope Bridge (test host)";
                [window.contentView addSubview:editor];
                [window makeKeyAndOrderFront:nil];
                if (options.clickConnect) {
                    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
                    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
                    collect(editor, buttons, [NSMutableArray array]);
                    std::printf("[harness] clicking \"%s\"\n", buttons.firstObject.title.UTF8String ?: "?");
                    std::fflush(stdout);
                    [buttons.firstObject performClick:nil];
                }
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:options.editorSeconds]];
                NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
                NSMutableArray<NSString *> *texts = [NSMutableArray array];
                collect(editor, buttons, texts);
                std::printf("[harness] plugin window shows: %s | button \"%s\"\n",
                            [texts componentsJoinedByString:@" | "].UTF8String, buttons.firstObject.title.UTF8String ?: "");
                NSBitmapImageRep *image = [editor bitmapImageRepForCachingDisplayInRect:editor.bounds];
                [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:image];
                [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                    writeToFile:[NSString stringWithUTF8String:options.snapshot.c_str()] atomically:YES];
                instances[0]->closeEditor();
                [window close];
                std::printf("[harness] editor captured to %s and closed; audio continues\n", options.snapshot.c_str());
                std::fflush(stdout);
            } else {
                std::printf("[harness] no editor\n");
            }
        }
        while (!done) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        audio.join();
        instances.clear();
        const bool pass = mismatches == 0 && errors == 0;
        std::printf("[harness] %s: %ld output mismatch(es), %ld process error(s)\n", pass ? "PASS" : "FAIL",
                    long(mismatches), long(errors));
        return pass ? 0 : 1;
    }
}
