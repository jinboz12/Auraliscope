import AudioToolbox
import CoreAudio
import Foundation
import AudioRing

/// A capture source: a device's input channels, or what apps play to a device's output channels.
struct SourceID: Hashable {
    var device: AudioDeviceID
    var output = false
    static let none = SourceID(device: 0)
    static let noOutput = SourceID(device: 0, output: true)
    var isNone: Bool { device == 0 }
}

struct InputDevice: Identifiable, Hashable {
    /// The Core Audio device (for an output source, the output device being tapped).
    let device: AudioDeviceID
    let name: String
    let channels: UInt32
    let uid: String
    /// Captures the device's output (macOS 14.2+ process tap) instead of its input.
    var output = false

    var id: SourceID { SourceID(device: device, output: output) }
    /// Routing, saved selection and the like are kept apart for the two sides of one device.
    var key: String { output ? "out.\(uid)" : uid }
}

enum AudioCaptureError: LocalizedError {
    case operation(String, OSStatus)
    case noInput
    case allocation
    case tapUnavailable

    var errorDescription: String? {
        switch self {
        case let .operation(name, status): return L("%@ failed (OSStatus %d)", L(name), Int(status))
        case .noInput: return L("The selected device has no input channels")
        case .tapUnavailable: return L("Capturing a device's output needs macOS 14.2 or later")
        case .allocation: return L("Could not allocate the audio ring buffer")
        }
    }
}

/// UID prefix of the private aggregate devices behind output sources.
let tapUIDPrefix = "com.jinboz.Auraliscope.tap."

enum AudioDevices {
    /// Every input device, then (macOS 14.2+) every output device as a tap source, sorted by name within each.
    static func availableSources() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        func named(_ id: AudioDeviceID) -> String { stringProperty(id, selector: kAudioObjectPropertyName) ?? L("Input device %d", Int(id)) }
        func uid(_ id: AudioDeviceID) -> String { stringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? "" }
        // Our own tap aggregates are private, but this process can still see them.
        let visible = ids.filter { !uid($0).hasPrefix(tapUIDPrefix) && isAlive($0) }
        let inputs = visible.compactMap { id -> InputDevice? in
            let channels = channelCount(id, scope: kAudioObjectPropertyScopeInput)
            return channels > 0 ? InputDevice(device: id, name: named(id), channels: channels, uid: uid(id)) : nil
        }
        var outputs: [InputDevice] = []
        if #available(macOS 14.2, *) {
            outputs = visible.compactMap { id -> InputDevice? in
                // A tap follows one output stream: the first, which carries every channel on most interfaces.
                let channels = channelCount(id, scope: kAudioObjectPropertyScopeOutput, firstStreamOnly: true)
                return channels > 0 ? InputDevice(device: id, name: named(id), channels: channels, uid: uid(id), output: true) : nil
            }
        }
        let byName: (InputDevice, InputDevice) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return inputs.sorted(by: byName) + outputs.sorted(by: byName)
    }

    static func availableInputs() -> [InputDevice] { availableSources().filter { !$0.output } }

    private static func isAlive(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        let result = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive)
        return result != noErr || alive != 0
    }

    /// The macOS default input, or with `output` the default output (what System Settings ▸ Sound plays to).
    static func defaultDeviceID(output: Bool = false) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr ? id : nil
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope, firstStreamOnly: Bool = false) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        if firstStreamOnly { return list.first?.mNumberChannels ?? 0 }
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }

    static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

final class AudioCapture {
    let ring: OpaquePointer
    private var unit: AudioUnit?
    /// Read by the C input callback on the IO thread; written only while the unit is stopped.
    private let context: UnsafeMutablePointer<CaptureContext>
    private var allocatedSamples = 0
    private(set) var sampleRate: Double = 48_000
    /// Input channels of the device (shown in the status line).
    private(set) var channels: UInt32 = 8
    /// Channels the unit actually delivers: only the device inputs some role is routed to.
    private(set) var deliveredChannels: UInt32 = 0
    /// Keeps an output source's process tap and aggregate device alive while capturing.
    private var tap: AnyObject?
    /// The IOProc reading an output source's tap aggregate, and that aggregate.
    private var tapProc: AudioDeviceIOProcID?
    private var tapDevice = AudioDeviceID(0)

    init?() {
        guard let ring = channel_ring_create(32_768) else { return nil }
        self.ring = ring
        context = .allocate(capacity: 1)
        context.initialize(to: CaptureContext())
        context.pointee.ring = ring
    }

    deinit {
        stop()
        context.deinitialize(count: 1)
        context.deallocate()
        channel_ring_destroy(ring)
    }

    /// Distinct routed device inputs in ascending order, and each role's index into them (−1 when off).
    /// The unit is asked for exactly these channels, so a 64-channel bridge with a stereo routing moves two
    /// channels per frame instead of 64.
    static func compactRouting(_ sourceForRole: [Int32], deviceChannels: UInt32) -> (inputs: [Int32], roles: [Int32]) {
        let inputs = Array(Set(sourceForRole.filter { $0 >= 0 && $0 < Int32(deviceChannels) })).sorted()
        let roles = sourceForRole.map { source in inputs.firstIndex(of: source).map(Int32.init) ?? -1 }
        return (inputs, roles)
    }

    func start(device: InputDevice, sourceForRole: [Int32]) throws {
        stop()
        guard device.channels > 0 else { throw AudioCaptureError.noInput }
        guard sourceForRole.count == Role.count else { throw AudioCaptureError.operation(LKey("Channel routing needs 16 roles"), -1) }
        if device.output {
            guard #available(macOS 14.2, *) else { throw AudioCaptureError.tapUnavailable }
            return try startTap(device: device, sourceForRole: sourceForRole)
        }
        channels = min(device.channels, 64)
        let captureDevice = device.device
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw AudioCaptureError.operation(LKey("Find HAL AudioUnit"), -1) }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), LKey("Create HAL AudioUnit"))
        guard let newUnit else { throw AudioCaptureError.operation(LKey("Create HAL AudioUnit"), -1) }
        unit = newUnit
        do {
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            try check(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)), LKey("Enable input"))
            try check(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)), LKey("Disable output"))
            var deviceID = captureDevice
            try check(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), LKey("Select input device"))
            sampleRate = try nominalRate(captureDevice)
            // Only the routed inputs cross the HAL. With nothing routed, one channel keeps the stream (and the
            // status line) alive. A driver that refuses the channel map falls back to every input.
            var routing = Self.compactRouting(sourceForRole, deviceChannels: channels)
            if routing.inputs.isEmpty { routing.inputs = [0] }
            if !applyFormat(newUnit, rate: sampleRate, inputs: routing.inputs) {
                routing = (Array(0..<Int32(channels)), sourceForRole.map { $0 >= 0 && $0 < Int32(channels) ? $0 : -1 })
                try check(setFormat(newUnit, rate: sampleRate, channels: channels), LKey("Set Float32 PCM format"))
                deliveredChannels = channels
            }
            Diagnostics.log("Capture delivers \(deliveredChannels) of \(channels) device inputs")
            prepareContext(device: captureDevice, unit: newUnit, roles: routing.roles)
            var callback = AURenderCallbackStruct(inputProc: capture_input_proc, inputProcRefCon: UnsafeMutableRawPointer(context))
            try check(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), LKey("Set input callback"))
            try check(AudioUnitInitialize(newUnit), LKey("Initialize audio unit"))
            channel_ring_clear(ring)
            try check(AudioOutputUnitStart(newUnit), LKey("Start audio unit"))
        } catch {
            stop()
            throw error
        }
    }

    /// An output source is read through a private aggregate device holding a tap on that output, by a plain
    /// device IOProc (see `capture_tap_io_proc`): macOS then asks only for System Audio Recording. Opened through
    /// the AUHAL input element, the tap counted as microphone use, so the orange microphone indicator stayed on and
    /// the microphone permission decided whether the tap read silence, whatever the source.
    @available(macOS 14.2, *)
    private func startTap(device: InputDevice, sourceForRole: [Int32]) throws {
        do {
            let outputTap = try OutputTap(outputUID: device.uid)
            tap = outputTap
            let aggregate = outputTap.aggregateID
            channels = min(AudioDevices.channelCount(aggregate, scope: kAudioObjectPropertyScopeInput), 64)
            guard channels > 0 else { throw AudioCaptureError.noInput }
            sampleRate = try nominalRate(aggregate)
            // The IOProc sees every channel of the tap; the roles index them directly.
            deliveredChannels = channels
            Diagnostics.log("Capture delivers all \(channels) tap channels")
            prepareContext(device: aggregate, unit: nil,
                           roles: sourceForRole.map { $0 >= 0 && $0 < Int32(channels) ? $0 : -1 })
            var procID: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcID(aggregate, capture_tap_io_proc, UnsafeMutableRawPointer(context), &procID),
                      LKey("Create output tap"))
            tapProc = procID
            tapDevice = aggregate
            channel_ring_clear(ring)
            try check(AudioDeviceStart(aggregate, procID), LKey("Start output capture"))
        } catch {
            stop()
            throw error
        }
    }

    private func nominalRate(_ device: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Double(48_000)
        var size = UInt32(MemoryLayout<Double>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate), LKey("Read sample rate"))
        return rate
    }

    /// Storage and routing for the IO callback, sized from the device's IO buffer. The callback renders at the
    /// device's own IO size; nothing here changes the buffer size that other clients of the device (a DAW) use.
    private func prepareContext(device: AudioDeviceID, unit: AudioUnit?, roles: [Int32]) {
        var bufferAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceFrames: UInt32 = 0
        var bufferSize = UInt32(MemoryLayout<UInt32>.size)
        var maximumFrames = 4096
        if AudioObjectGetPropertyData(device, &bufferAddress, 0, nil, &bufferSize, &deviceFrames) == noErr {
            maximumFrames = max(4096, min(16_384, Int(deviceFrames) * 2))
        }
        allocatedSamples = maximumFrames * Int(deliveredChannels)
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: allocatedSamples)
        storage.initialize(repeating: 0, count: allocatedSamples)
        context.pointee.unit = unit
        context.pointee.storage = storage
        context.pointee.max_frames = UInt32(maximumFrames)
        context.pointee.channels = deliveredChannels
        withUnsafeMutableBytes(of: &context.pointee.source_for_role) { raw in
            let slots = raw.bindMemory(to: Int32.self)
            for role in 0..<Role.count { slots[role] = roles[role] }
        }
    }

    /// Client format with `inputs.count` channels plus the channel map that picks those device inputs.
    private func applyFormat(_ unit: AudioUnit, rate: Double, inputs: [Int32]) -> Bool {
        let count = UInt32(inputs.count)
        guard setFormat(unit, rate: rate, channels: count) == noErr else { return false }
        var map = inputs
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                                          &map, UInt32(MemoryLayout<Int32>.size * map.count))
        guard status == noErr else {
            Diagnostics.log("Channel map refused (OSStatus \(status)); capturing every input")
            return false
        }
        deliveredChannels = count
        return true
    }

    private func setFormat(_ unit: AudioUnit, rate: Double, channels: UInt32) -> OSStatus {
        var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        return AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    }

    /// Returns drops from this capture after the last callback, before clearing its ring for reuse.
    @discardableResult
    func stop() -> UInt64 {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        // Stopped and destroyed from this thread, the IOProc has run for the last time before storage is freed.
        if let tapProc {
            AudioDeviceStop(tapDevice, tapProc)
            AudioDeviceDestroyIOProcID(tapDevice, tapProc)
            self.tapProc = nil
            tapDevice = 0
        }
        if let storage = context.pointee.storage {
            storage.deinitialize(count: allocatedSamples)
            storage.deallocate()
        }
        context.pointee.storage = nil
        context.pointee.unit = nil
        // The unit is gone, so the aggregate and its tap can go too.
        tap = nil
        allocatedSamples = 0
        deliveredChannels = 0
        let dropped = channel_ring_dropped(ring)
        channel_ring_clear(ring)
        return dropped
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioCaptureError.operation(operation, status) }
    }
}

/// What every app plays to one output device, as an input: a Core Audio process tap on the device's first
/// output stream (all processes, this one included), wrapped in a private aggregate device whose input an IOProc
/// reads. macOS asks once for System Audio Recording permission. The tap does not alter or delay what the device
/// plays.
@available(macOS 14.2, *)
final class OutputTap {
    let aggregateID: AudioDeviceID
    private let tapID: AudioObjectID

    init(outputUID: String) throws {
        let description = CATapDescription(excludingProcesses: [], deviceUID: outputUID, stream: 0)
        description.name = "Auraliscope"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw AudioCaptureError.operation(LKey("Create output tap"), tapStatus) }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Auraliscope output tap",
            kAudioAggregateDeviceUIDKey: tapUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: 1]]
        ]
        var aggregate = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw AudioCaptureError.operation(LKey("Create output tap"), status)
        }
        tapID = tap
        aggregateID = aggregate
    }

    deinit {
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}
