import Foundation
import AudioRing
import AudioToolbox

/// Recovery of a device capture that keeps failing (P0-1), without capture hardware.
///
/// - **Health record:** what the IO callbacks record of each slice (written whole, refused, too long for the storage,
///   cut off), the current failing run and the largest slice, read as `CaptureHealthReading`. The callbacks are driven
///   as the baseline checks drive them: an AUHAL never initialised refuses every slice, and tap deliveries are built in
///   memory. The ring's accounting of the same slices is checked alongside, unchanged.
/// - **Policy:** `CaptureRecoveryPolicy` fed with readings and times chosen here: what counts as sustained, one restart
///   per decision, verification by audio delivered, backoff, giving up, the episode's end, sessions, and storage sizes.
///   The model's side (what it restarts, stops and shows) is checked by `--test-model-lifecycle`.
enum CaptureRecoveryChecks {
    static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        try BaselineChecks.require(condition, message())
    }

    static func run() throws {
        try healthRecordsEachSlice()
        try healthResetsAndToleratesNoRecord()
        print("PASS: capture recovery: the IO callbacks record whole, refused, oversize and cut slices, and the failing run")
        try policyDetectsOnlySustainedFailures()
        try policyRestartsOnceAndVerifies()
        try policyBacksOffAndGivesUp()
        try policyBelongsToItsSession()
        try policySizesStorageFromTheNewestRun()
        print("PASS: capture recovery: sustained failures only, one restart per decision, verified by audio, 0/2/8 s, then give up")
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

    // MARK: - Policy

    static let rate = 48_000.0

    /// A reading of a capture failing for `seconds` of audio over `slices` callbacks, after `delivered` frames written whole.
    static func failing(_ seconds: Double, slices: UInt64 = 100, failures: UInt32 = CAPTURE_FAILURE_REFUSED,
                        status: Int32 = -10863, largest: UInt32 = 512, delivered: UInt64 = 0) -> CaptureHealthReading {
        var health = CaptureHealthReading()
        health.delivered_frames = delivered
        health.delivered_slices = delivered / 512
        health.failed_slices = slices
        health.run_slices = slices
        health.run_lost_frames = UInt64(seconds * rate)
        health.run_failures = failures
        health.last_status = status
        health.largest_slice = largest
        return health
    }

    /// A reading of a capture that has delivered `seconds` of audio whole and is not failing.
    static func delivering(_ seconds: Double) -> CaptureHealthReading {
        var health = CaptureHealthReading()
        health.delivered_frames = UInt64(seconds * rate)
        health.delivered_slices = max(1, health.delivered_frames / 512)
        health.largest_slice = 512
        return health
    }

    /// What a sustained failure is, and what is not: a short run, a long run of too few slices, a single huge slice.
    static func policyDetectsOnlySustainedFailures() throws {
        var policy = CaptureRecoveryPolicy()
        let session: UInt64 = 1
        for (health, label) in [(failing(0.99), "0.99 s lost"), (failing(5, slices: 2), "5 s lost in 2 slices"),
                                (delivering(10), "healthy"), (CaptureHealthReading(), "nothing seen")] {
            try require(policy.observe(health, sampleRate: rate, session: session, now: 10) == nil && policy.phase == .watching,
                        "\(label) is not a sustained failure: \(policy.phase)")
        }
        try require(policy.sustainedFailure(failing(1.0, slices: 3), sampleRate: rate) == .refused(status: -10863),
                    "1 s lost over 3 slices is sustained")
        try require(policy.sustainedFailure(failing(1.0, slices: 3), sampleRate: 0) == nil, "no rate, no decision")
        try require(CaptureRecoveryPolicy.failure(of: failing(1, failures: CAPTURE_FAILURE_REFUSED | CAPTURE_FAILURE_OVERSIZE,
                                                              largest: 9_000)) == .capacity(largest: 9_000)
                    && CaptureRecoveryPolicy.failure(of: failing(1, failures: CAPTURE_FAILURE_TRUNCATED, largest: 20_000))
                    == .capacity(largest: 20_000),
                    "slices too long for the storage call for storage, whatever else failed")
    }

    /// A refusal that lasts: one restart at once; repeated readings decide nothing more; the restart verified by audio
    /// delivered, not by opening.
    static func policyRestartsOnceAndVerifies() throws {
        var policy = CaptureRecoveryPolicy()
        try require(policy.observe(failing(1.2), sampleRate: rate, session: 1, now: 10) == .restart(attempt: 1, failure: .refused(status: -10863)),
                    "a sustained refusal restarts at once")
        for tick in 0..<20 {
            let decision = policy.observe(failing(0.4), sampleRate: rate, session: 1, now: 10 + Double(tick) * 0.1)
            try require(decision == nil, "reading \(tick) after the restart decided \(String(describing: decision))")
        }
        try require(policy.isActive, "the restart is being verified")
        try require(policy.observe(delivering(0.4), sampleRate: rate, session: 1, now: 12) == nil && policy.isActive,
                    "0.4 s delivered is not yet proof")
        try require(policy.observe(delivering(0.5), sampleRate: rate, session: 1, now: 12.5) == nil
                    && policy.phase == .recovered(attempts: 1, since: 12.5), "0.5 s delivered whole proves the restart")
        try require(policy.observe(delivering(5), sampleRate: rate, session: 1, now: 42.25) == nil
                    && policy.phase == .recovered(attempts: 1, since: 12.5), "the episode lasts until 30 s have passed")
        try require(policy.observe(delivering(5), sampleRate: rate, session: 1, now: 42.5) == nil && policy.phase == .watching,
                    "30 s without a sustained failure ends the episode")
        try require(policy.observe(failing(1.0, slices: 3), sampleRate: rate, session: 1, now: 50) == .restart(attempt: 1, failure: .refused(status: -10863)),
                    "after the episode, a new failure starts again from the first restart")
    }

    /// Restarts that do not work: 0, 2 and 8 s apart, then giving up; a failure soon after a restart that worked uses
    /// the same budget.
    static func policyBacksOffAndGivesUp() throws {
        var policy = CaptureRecoveryPolicy()
        var now = 100.0
        try require(policy.observe(failing(1), sampleRate: rate, session: 7, now: now) == .restart(attempt: 1, failure: .refused(status: -10863)), "first restart")
        // Its IO fails again for a second: that attempt failed; the next waits 2 s.
        now += 1
        try require(policy.observe(failing(1), sampleRate: rate, session: 7, now: now) == nil
                    && policy.phase == .waiting(attempt: 2, due: now + 2, failure: .refused(status: -10863), delivered: 0),
                    "a restart failing again waits 2 s for the next: \(policy.phase)")
        try require(policy.observe(failing(2.9), sampleRate: rate, session: 7, now: now + 1.9) == nil, "not before its time")
        now += 2
        try require(policy.observe(failing(3), sampleRate: rate, session: 7, now: now) == .restart(attempt: 2, failure: .refused(status: -10863)), "second restart after 2 s")
        // It cannot open the device: the third waits 8 s.
        try require(policy.restartFailed(now: now) == nil
                    && policy.phase == .waiting(attempt: 3, due: now + 8, failure: .refused(status: -10863), delivered: 0),
                    "a restart that cannot open waits 8 s for the next: \(policy.phase)")
        try require(policy.observe(CaptureHealthReading(), sampleRate: rate, session: 7, now: now + 7.9) == nil, "a closed IO has not come back")
        now += 8
        try require(policy.observe(CaptureHealthReading(), sampleRate: rate, session: 7, now: now) == .restart(attempt: 3, failure: .refused(status: -10863)), "third restart after 8 s")
        // It delivers nothing at all for 3 s: that one failed too, and the budget is spent.
        try require(policy.observe(CaptureHealthReading(), sampleRate: rate, session: 7, now: now + 2.9) == nil, "still within the verification time")
        try require(policy.observe(CaptureHealthReading(), sampleRate: rate, session: 7, now: now + 3) == .giveUp(attempts: 3, failure: .refused(status: -10863))
                    && policy.phase == .watching, "three restarts that did not work: give up")

        // A restart that worked, then a failure within 30 s: the next restart of the same episode, 2 s later.
        policy = CaptureRecoveryPolicy()
        _ = policy.observe(failing(1), sampleRate: rate, session: 8, now: 0)
        _ = policy.observe(delivering(1), sampleRate: rate, session: 8, now: 1)
        try require(policy.phase == .recovered(attempts: 1, since: 1), "the first restart worked")
        try require(policy.observe(failing(1, delivered: 48_000), sampleRate: rate, session: 8, now: 20) == nil
                    && policy.phase == .waiting(attempt: 2, due: 22, failure: .refused(status: -10863), delivered: 48_000),
                    "a failure within the episode waits for the episode's next restart: \(policy.phase)")
        // The device comes back by itself before then: no restart, the episode goes on.
        try require(policy.observe(delivering(1.1), sampleRate: rate, session: 8, now: 21) == nil
                    && policy.phase == .recovered(attempts: 1, since: 21), "a capture that comes back by itself cancels the pending restart")
        // The budget used stays used: after a third restart that worked, the next failure gives up at once.
        policy = CaptureRecoveryPolicy()
        _ = policy.observe(failing(1), sampleRate: rate, session: 9, now: 0)
        _ = policy.restartFailed(now: 0)
        _ = policy.observe(CaptureHealthReading(), sampleRate: rate, session: 9, now: 2)
        _ = policy.restartFailed(now: 2)
        _ = policy.observe(CaptureHealthReading(), sampleRate: rate, session: 9, now: 10)
        _ = policy.observe(delivering(1), sampleRate: rate, session: 9, now: 11)
        try require(policy.phase == .recovered(attempts: 3, since: 11), "the third restart worked: \(policy.phase)")
        try require(policy.observe(failing(1), sampleRate: rate, session: 9, now: 20) == .giveUp(attempts: 3, failure: .refused(status: -10863)),
                    "a failure within the episode after its last restart gives up")
    }

    /// A decision belongs to its capture session: another session (a pause, a stop, another source, a configuration
    /// change) ends the episode, so a pending restart never reaches it; a session recovery made itself carries on.
    static func policyBelongsToItsSession() throws {
        var policy = CaptureRecoveryPolicy()
        _ = policy.observe(failing(1), sampleRate: rate, session: 3, now: 0)
        _ = policy.observe(failing(1), sampleRate: rate, session: 3, now: 1)
        try require(policy.phase == .waiting(attempt: 2, due: 3, failure: .refused(status: -10863), delivered: 0), "a restart is pending")
        try require(policy.observe(failing(0.5), sampleRate: rate, session: 4, now: 5) == nil && policy.phase == .watching && policy.session == 4,
                    "another session ends the episode: the pending restart is gone")
        try require(policy.observe(failing(1), sampleRate: rate, session: 4, now: 6) == .restart(attempt: 1, failure: .refused(status: -10863)),
                    "the new session has its whole budget")
        policy.adopt(session: 5)
        try require(policy.observe(delivering(1), sampleRate: rate, session: 5, now: 7) == nil && policy.phase == .recovered(attempts: 1, since: 7),
                    "a session the restart made carries the episode on")
        policy.reset()
        try require(policy.phase == .watching && policy.session == nil && !policy.isActive, "a reset forgets the episode")
    }

    /// Slices too long for the storage: each restart asks for storage for the newest largest slice.
    static func policySizesStorageFromTheNewestRun() throws {
        var policy = CaptureRecoveryPolicy()
        try require(policy.observe(failing(1, failures: CAPTURE_FAILURE_OVERSIZE, largest: 8_192), sampleRate: rate, session: 1, now: 0)
                    == .restart(attempt: 1, failure: .capacity(largest: 8_192)), "oversize slices restart with storage for them")
        try require(policy.observe(failing(1, failures: CAPTURE_FAILURE_OVERSIZE, largest: 12_000), sampleRate: rate, session: 1, now: 1) == nil,
                    "still too long after the restart: that attempt failed")
        _ = policy.observe(failing(2, failures: CAPTURE_FAILURE_OVERSIZE, largest: 16_000), sampleRate: rate, session: 1, now: 2)
        try require(policy.observe(failing(3, failures: CAPTURE_FAILURE_OVERSIZE, largest: 16_000), sampleRate: rate, session: 1, now: 3)
                    == .restart(attempt: 2, failure: .capacity(largest: 16_000)), "the next restart sizes for the newest slices")
        try require(CaptureRecoveryPolicy.Failure.capacity(largest: 16_000).minimumFrames == 16_000
                    && CaptureRecoveryPolicy.Failure.refused(status: -1).minimumFrames == 0, "storage follows the failure")
    }
}
