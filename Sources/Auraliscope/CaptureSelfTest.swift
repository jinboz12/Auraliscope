import AnalysisCore
import AudioRing
import AudioToolbox
import CoreAudio
import Foundation

/// `--capture-selftest <device id>`: end-to-end check of the capture path on a loopback device (for example a
/// Pro Tools Audio Bridge). Every output channel plays 1 kHz at its own level; capture then reads the inputs
/// through a scrambled routing, so each role must show the level of the input it is routed to. It proves the
/// channel map, the C input callback and the ring mapping agree. Needs microphone permission.
/// With `--output` the same tones are read back through a process tap on the device's output instead of its
/// input (System Audio Recording permission; without it macOS delivers silence, which reads as FAIL).
enum CaptureSelfTest {
    private final class Tone {
        var phase = 0.0
        var channels = 0
        var rate = 48_000.0
        static func amplitude(_ channel: Int) -> Float { 0.02 + 0.03 * Float(channel % 24) }
    }

    static func run(deviceID: AudioDeviceID, output: Bool = false) -> Bool {
        guard let device = AudioDevices.availableSources().first(where: { $0.device == deviceID && $0.output == output }) else {
            print("No \(output ? "output" : "input") device \(deviceID)")
            return false
        }
        let channels = Int(min(device.channels, 64))
        let tone = Tone()
        tone.channels = channels
        // `--listen`: another process plays; only report what arrives.
        let listen = CommandLine.arguments.contains("--listen")
        let toneUnit = listen ? nil : startTone(device: deviceID, tone: tone)
        guard listen || toneUnit != nil else { return false }
        defer {
            if let toneUnit {
                AudioOutputUnitStop(toneUnit)
                AudioUnitUninitialize(toneUnit)
                AudioComponentInstanceDispose(toneUnit)
            }
        }
        // Reverse order, plus two roles sharing one input, plus one role switched off.
        var routing = (0..<Role.count).map { Int32((channels - 1 - $0 % channels + channels) % channels) }
        routing[Role.count - 1] = routing[0]
        routing[5] = -1
        guard let capture = AudioCapture() else { return false }
        do { try capture.start(device: device, sourceForRole: routing) } catch {
            print("Capture failed: \(error.localizedDescription)")
            return false
        }
        defer { capture.stop() }
        print("Device \(device.name) \(output ? "output (tap)" : "input"): \(channels) channels, capture delivers \(capture.deliveredChannels)")
        var frames = [ChannelFrame](repeating: ChannelFrame(), count: 4096)
        var sums = [Double](repeating: 0, count: Role.count)
        var count = 0
        let settle = Date().addingTimeInterval(0.8), end = Date().addingTimeInterval(1.6)
        while Date() < end {
            let read = frames.withUnsafeMutableBufferPointer { Int(channel_ring_read(capture.ring, $0.baseAddress!, 4096)) }
            if read == 0 { usleep(5_000); continue }
            guard Date() > settle else { continue }
            frames.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Float.self)
                for frame in 0..<read {
                    for role in 0..<Role.count { sums[role] += Double(samples[frame * Role.count + role] * samples[frame * Role.count + role]) }
                }
            }
            count += read
        }
        guard count > 0 else { print("FAIL: no frames captured"); return false }
        var passed = true
        for role in 0..<Role.count {
            let rms = Float(sqrt(sums[role] / Double(count)))
            let expected = routing[role] >= 0 ? Tone.amplitude(Int(routing[role])) / sqrt(2) : 0
            let ok = routing[role] < 0 ? rms < 1e-6 : abs(rms - expected) < 0.1 * expected
            if !ok { passed = false }
            print(String(format: "role %2d ← input %3d  rms %.4f  expected %.4f  %@", role, routing[role], rms, expected, ok ? "ok" : "FAIL"))
        }
        print(passed ? "PASS: every role reads its routed input" : "FAIL")
        return passed
    }

    private static func startTone(device: AudioDeviceID, tone: Tone) -> AudioUnit? {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var unit: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description), AudioComponentInstanceNew(component, &unit) == noErr,
              let unit else { return nil }
        var id = device
        var rate = 48_000.0
        var size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        tone.rate = rate
        let channels = UInt32(tone.channels)
        var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                                                 mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var callback = AURenderCallbackStruct(inputProc: { context, _, _, _, frames, data in
            let tone = Unmanaged<Tone>.fromOpaque(context).takeUnretainedValue()
            guard let buffer = UnsafeMutableAudioBufferListPointer(data)?.first, let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let step = 2 * Double.pi * 1_000 / tone.rate
            for frame in 0..<Int(frames) {
                let value = Float(sin(tone.phase))
                tone.phase += step
                for channel in 0..<tone.channels { samples[frame * tone.channels + channel] = value * Tone.amplitude(channel) }
            }
            tone.phase = tone.phase.truncatingRemainder(dividingBy: 2 * Double.pi)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(tone).toOpaque())
        let ok = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
            && AudioUnitInitialize(unit) == noErr && AudioOutputUnitStart(unit) == noErr
        if !ok {
            print("Could not start the test tone on device \(device)")
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return unit
    }
}
