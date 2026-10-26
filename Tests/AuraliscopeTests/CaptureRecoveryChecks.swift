import Foundation
import AudioRing
import AudioToolbox

/// Recovery of a device capture that keeps failing (P0-1), without capture hardware.
///
/// - **Health record:** what the IO callbacks record of each slice (written whole, refused, too long for the storage,
///   cut off), the current failing run and the largest slice, read as `CaptureHealthReading`. The callbacks are driven
///   as the baseline checks drive them: an AUHAL never initialised refuses every slice, and tap deliveries are built in
///   memory. The ring's accounting of the same slices is checked alongside, unchanged.
enum CaptureRecoveryChecks {
    static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        try BaselineChecks.require(condition, message())
    }

    static func run() throws {
        try healthRecordsEachSlice()
        try healthResetsAndToleratesNoRecord()
        print("PASS: capture recovery: the IO callbacks record whole, refused, oversize and cut slices, and the failing run")
    }

    static func reading(_ health: OpaquePointer?) -> CaptureHealthReading {
        var reading = CaptureHealthReading()
        capture_health_read(health, &reading)
        return reading
    }

    /// Each kind of slice, in the order a failing capture meets them, with the ring's own count beside the record's.
    static func healthRecordsEachSlice() throws {
        guard let ring = channel_ring_create(1_024), let health = capture_health_create() else {
            throw BaselineChecks.Failure(description: "ring or health record")
        }
        defer { channel_ring_destroy(ring); capture_health_destroy(health) }
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 4 * 256)
        storage.initialize(repeating: 0, count: 4 * 256)
        defer { storage.deallocate() }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var unit: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            throw BaselineChecks.Failure(description: "health record check: no HAL output unit")
        }
        // Never initialised and never started: no audio device is opened, and AudioUnitRender refuses every slice.
        defer { AudioComponentInstanceDispose(unit) }
        var context = BaselineChecks.captureContext(ring: ring, storage: storage, maxFrames: 256, channels: 2)
        context.unit = unit
        context.health = health
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        try require(reading(health).delivered_slices == 0 && reading(health).failed_slices == 0
                    && reading(health).largest_slice == 0, "a new record has seen nothing")

        // Too long for the storage: a failed slice, the run starts.
        _ = withUnsafeMutablePointer(to: &context) { capture_input_proc($0, &flags, &time, 1, 512, nil) }
        var seen = reading(health)
        try require(seen.failed_slices == 1 && seen.run_slices == 1 && seen.run_lost_frames == 512
                    && seen.run_failures == CAPTURE_FAILURE_OVERSIZE && seen.largest_slice == 512 && seen.last_status == 0
                    && seen.delivered_slices == 0, "an oversize slice: \(seen)")
        // Refused twice by AudioUnitRender: the same run, its status kept.
        var refusal: OSStatus = noErr
        for _ in 0..<2 {
            refusal = withUnsafeMutablePointer(to: &context) { capture_input_proc($0, &flags, &time, 1, 128, nil) }
        }
        seen = reading(health)
        try require(refusal != noErr && seen.failed_slices == 3 && seen.run_slices == 3 && seen.run_lost_frames == 768
                    && seen.run_failures == CAPTURE_FAILURE_OVERSIZE | CAPTURE_FAILURE_REFUSED && seen.last_status == refusal
                    && seen.largest_slice == 512, "two refusals continue the run: \(seen)")
        try require(channel_ring_dropped(ring) == 768, "the ring counts the same 768 frames, \(channel_ring_dropped(ring))")

        // A tap delivery within the storage (several streams): written whole, the run is over.
        try BaselineChecks.tapDelivery(frames: 8, context: &context)
        seen = reading(health)
        try require(seen.delivered_slices == 1 && seen.delivered_frames == 8 && seen.run_slices == 0
                    && seen.run_lost_frames == 0 && seen.run_failures == 0 && seen.failed_slices == 3
                    && seen.last_status == refusal, "a whole delivery ends the run: \(seen)")
        // One cut off: 300 frames against storage for 256 keeps 256, loses 44.
        try BaselineChecks.tapDelivery(frames: 300, context: &context)
        seen = reading(health)
        try require(seen.failed_slices == 4 && seen.run_slices == 1 && seen.run_lost_frames == 44
                    && seen.run_failures == CAPTURE_FAILURE_TRUNCATED && seen.largest_slice == 512 && seen.delivered_slices == 1,
                    "a delivery cut off starts a run with the frames it lost: \(seen)")
        try require(channel_ring_dropped(ring) == 812, "the ring counts the cut frames too, \(channel_ring_dropped(ring))")

        // A tap delivery in one interleaved stream (the direct path): written whole.
        var direct = [Float](repeating: 0.5, count: 16 * 2)
        try direct.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            var output = AudioBufferList()
            let status = withUnsafeMutablePointer(to: &context) {
                capture_tap_io_proc(0, &time, &list, &time, &output, &time, UnsafeMutableRawPointer($0))
            }
            try require(status == noErr, "direct tap delivery: status \(status)")
        }
        seen = reading(health)
        try require(seen.delivered_slices == 2 && seen.delivered_frames == 24 && seen.run_slices == 0 && seen.failed_slices == 4,
                    "a direct tap delivery is written whole: \(seen)")
    }

    /// A reset forgets everything; a context without a record (as the baseline checks build it) changes nothing.
    static func healthResetsAndToleratesNoRecord() throws {
        guard let ring = channel_ring_create(64), let health = capture_health_create() else {
            throw BaselineChecks.Failure(description: "ring or health record")
        }
        defer { channel_ring_destroy(ring); capture_health_destroy(health) }
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 8 * 4)
        storage.initialize(repeating: 0, count: 8 * 4)
        defer { storage.deallocate() }
        var context = BaselineChecks.captureContext(ring: ring, storage: storage, maxFrames: 8, channels: 4)
        context.health = health
        try BaselineChecks.tapDelivery(frames: 12, context: &context)
        try require(reading(health).failed_slices == 1, "a cut delivery is recorded")
        capture_health_reset(health)
        let cleared = reading(health)
        try require(cleared.delivered_frames == 0 && cleared.delivered_slices == 0 && cleared.failed_slices == 0
                    && cleared.run_slices == 0 && cleared.run_lost_frames == 0 && cleared.run_failures == 0
                    && cleared.last_status == 0 && cleared.largest_slice == 0, "a reset forgets everything: \(cleared)")
        context.health = nil
        try BaselineChecks.tapDelivery(frames: 12, context: &context)
        try require(reading(health).failed_slices == 0 && reading(nil).failed_slices == 0,
                    "a context without a record records nothing")
        try require(channel_ring_dropped(ring) == 8, "the ring counts both cut deliveries, \(channel_ring_dropped(ring))")
    }
}
