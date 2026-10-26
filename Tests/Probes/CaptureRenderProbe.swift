import AudioRing
import AudioToolbox
import CoreAudio
import Foundation

// Phase 2 probe (docs/maintenance/BASELINE_2026-10.md, P0-1). Drives the app's own input callback
// (Sources/AudioRing/CaptureCallback.c, capture_input_proc) through an AUHAL on a real input device for two seconds
// and reports every slice: its size, whether the callback refused it, and what reached the ring (frames, dropped
// count, break marks). The IO buffer size it sets applies to this process only; nothing global changes.
//
// usage: capture-render-probe <deviceID> <clientRate> <bufferFrames> <maxFrames>
// Client rate 0 takes the device's own (the control, as Auraliscope starts capture); a different rate is the state
// Auraliscope is in between a device sample-rate change and its capture restart.

nonisolated(unsafe) var slices: [(frames: UInt32, status: OSStatus)] = []
let slicesLock = NSLock()

let arguments = CommandLine.arguments
guard arguments.count == 5, let device = AudioDeviceID(arguments[1]), var clientRate = Double(arguments[2]),
      let bufferFrames = UInt32(arguments[3]), let maxFrames = UInt32(arguments[4]) else {
    print("usage: capture-render-probe <deviceID> <clientRate> <bufferFrames> <maxFrames>")
    exit(2)
}
slices.reserveCapacity(10_000)
func check(_ status: OSStatus, _ what: String) {
    if status != noErr { print("\(what) failed (OSStatus \(status))"); exit(1) }
}
var bufferAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
var frames = bufferFrames
check(AudioObjectSetPropertyData(device, &bufferAddress, 0, nil, 4, &frames), "set this process's IO buffer size")
var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
var created: AudioUnit?
check(AudioComponentInstanceNew(AudioComponentFindNext(nil, &description)!, &created), "create AUHAL")
let unit = created!
var on: UInt32 = 1, off: UInt32 = 0, deviceID = device
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4), "enable input")
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4), "disable output")
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, 4), "select device")
var deviceRate = Float64(0), rateSize = UInt32(8)
var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
check(AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &deviceRate), "read device rate")
if clientRate == 0 { clientRate = deviceRate }
var format = AudioStreamBasicDescription(mSampleRate: clientRate, mFormatID: kAudioFormatLinearPCM,
                                         mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
                                         mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format,
                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "client format")
let ring = channel_ring_create(1 << 20)!
let context = UnsafeMutablePointer<CaptureContext>.allocate(capacity: 1)
context.initialize(to: CaptureContext())
context.pointee.unit = unit
context.pointee.ring = ring
context.pointee.storage = .allocate(capacity: Int(maxFrames) * 2)
context.pointee.max_frames = maxFrames
context.pointee.channels = 2
withUnsafeMutableBytes(of: &context.pointee.source_for_role) { raw in
    let roles = raw.bindMemory(to: Int32.self)
    for role in 0..<16 { roles[role] = role < 2 ? Int32(role) : -1 }
}
// A recorder in front of the app's callback (probe only: it takes a lock on the IO thread, which the app never does).
let recorder: AURenderCallback = { reference, flags, time, bus, count, list in
    let status = capture_input_proc(reference, flags, time, bus, count, list)
    slicesLock.lock(); slices.append((count, status)); slicesLock.unlock()
    return status
}
var callback = AURenderCallbackStruct(inputProc: recorder, inputProcRefCon: UnsafeMutableRawPointer(context))
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")
check(AudioUnitInitialize(unit), "initialize")
var slice: UInt32 = 0, size = UInt32(4)
AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, &size)
check(AudioOutputUnitStart(unit), "start")
Thread.sleep(forTimeInterval: 2)
AudioOutputUnitStop(unit)
AudioUnitUninitialize(unit)
AudioComponentInstanceDispose(unit)
slicesLock.lock(); let log = slices; slicesLock.unlock()
var mark = ChannelRingMark(), has: Int32 = 0, read = 0, marks = 0
var out = [ChannelFrame](repeating: ChannelFrame(), count: 1 << 16)
while true {
    let n = channel_ring_read_marked(ring, &out, UInt32(out.count), &mark, &has)
    if has != 0 { marks += 1; continue }
    if n == 0 { break }
    read += Int(n)
}
let refused = log.filter { $0.status != noErr }
print("device \(device) at \(Int(deviceRate)) Hz; client \(Int(clientRate)) Hz; IO buffer \(bufferFrames) (this process); storage \(maxFrames) frames; AUHAL MaximumFramesPerSlice \(slice)")
print("slices \(log.count), sizes \(Set(log.map(\.frames)).sorted()), refused \(refused.count)\(refused.first.map { " (OSStatus \($0.status))" } ?? ""); ring: \(read) frames, \(channel_ring_dropped(ring)) dropped, \(marks) break marks")
