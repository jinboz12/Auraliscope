import AudioRing

/// When a device capture that keeps failing is restarted, how often, and when to give up (P0-1). A plain value with no
/// clock or device of its own: the model feeds it at the readout rate with what the capture's IO callback saw
/// (`CaptureHealthReading`), the capture session and the time, and carries out what it decides (`MeterModel`'s
/// `superviseCapture`).
///
/// A failure is sustained when one run of failed callbacks has lost `sustainedAudio` seconds of audio over at least
/// `sustainedSlices` callbacks. Measured in audio lost rather than in readout ticks, it holds when ticks are late (a
/// hidden app's timers may be coalesced). A sustained failure opens an episode: up to `backoff.count` restarts, the first
/// after `backoff[0]`, each later one `backoff[n]` after the one before failed. A restart works once its IO has
/// delivered `verifiedAudio` seconds whole and is not failing, within `verifyTimeout`; delivering silence counts, since
/// it is the capture that is checked, not the signal. The episode ends `episodeReset` after a restart that worked, with
/// no sustained failure meanwhile, and its restarts are available again; when they are spent, the model stops capture
/// and waits for the person.
///
/// Every decision belongs to one capture session. A session the policy did not make (a pause, a stop, another source, a
/// device configuration change, a person's start) ends the episode at the next reading, so no restart decided for one
/// capture ever reaches another.
struct CaptureRecoveryPolicy {
    struct Thresholds: Equatable {
        var sustainedAudio = 1.0
        var sustainedSlices: UInt64 = 3
        var backoff: [Double] = [0, 2, 8]
        var verifiedAudio = 0.5
        var verifyTimeout = 3.0
        var episodeReset = 30.0
    }

    /// What failed, as the run's failure bits tell it.
    enum Failure: Equatable {
        /// The device refused slices (`AudioUnitRender`'s status), as every slice is while its rate differs from the
        /// capture's.
        case refused(status: Int32)
        /// Slices or deliveries longer than the storage: the next IO needs storage for `largest` frames.
        case capacity(largest: UInt32)

        /// The storage the next IO needs, in frames per slice (0: as the device's IO buffer gives it).
        var minimumFrames: UInt32 {
            if case let .capacity(largest) = self { return largest }
            return 0
        }

        /// In the status line's words.
        var text: String {
            switch self {
            // As Core Audio prints it: no digit grouping.
            case let .refused(status): return L("the device refused audio (OSStatus %@)", String(status))
            case .capacity: return L("the device delivered more audio per cycle than the capture holds")
            }
        }

        /// For the diagnostic log, in English.
        var logDescription: String {
            switch self {
            case let .refused(status): return "refused, OSStatus \(status)"
            case let .capacity(largest): return "slices of up to \(largest) frames, longer than the storage"
            }
        }
    }

    enum Phase: Equatable {
        /// No episode.
        case watching
        /// Restart number `attempt` is due at `due`. `delivered` is what the IO had delivered when the wait began: more
        /// since, and not failing, means it came back by itself.
        case waiting(attempt: Int, due: Double, failure: Failure, delivered: UInt64)
        /// Restart number `attempt` was made at `started`; its IO has yet to deliver.
        case verifying(attempt: Int, started: Double, failure: Failure)
        /// The episode's last restart, number `attempts`, worked at `since`.
        case recovered(attempts: Int, since: Double)
    }

    enum Decision: Equatable {
        /// Make restart number `attempt` now, with storage for the failure's slices.
        case restart(attempt: Int, failure: Failure)
        /// The episode's restarts are spent: stop capture and wait for the person.
        case giveUp(attempts: Int, failure: Failure)
    }

    var thresholds = Thresholds()
    private(set) var phase = Phase.watching
    /// The capture session the phase belongs to.
    private(set) var session: UInt64?

    /// While an episode holds the capture (a restart pending or being verified), only it restarts that capture.
    var isActive: Bool {
        switch phase {
        case .waiting, .verifying: return true
        case .watching, .recovered: return false
        }
    }

    /// The current run's failure, once it has lasted (nil otherwise).
    func sustainedFailure(_ health: CaptureHealthReading, sampleRate: Double) -> Failure? {
        guard health.run_slices >= thresholds.sustainedSlices, sampleRate > 0,
              Double(health.run_lost_frames) / sampleRate >= thresholds.sustainedAudio else { return nil }
        return Self.failure(of: health)
    }

    static func failure(of health: CaptureHealthReading) -> Failure {
        if health.run_failures & (CAPTURE_FAILURE_OVERSIZE | CAPTURE_FAILURE_TRUNCATED) != 0 {
            return .capacity(largest: health.largest_slice)
        }
        return .refused(status: health.last_status)
    }

    /// One reading of the capture of `session`, at `now`.
    mutating func observe(_ health: CaptureHealthReading, sampleRate: Double, session: UInt64, now: Double) -> Decision? {
        if session != self.session {
            self.session = session
            phase = .watching
        }
        let failing = sustainedFailure(health, sampleRate: sampleRate)
        switch phase {
        case .watching:
            guard let failing else { return nil }
            return schedule(attempt: 1, failure: failing, now: now, health: health)
        case let .recovered(attempts, since):
            if let failing { return schedule(attempt: attempts + 1, failure: failing, now: now, health: health) }
            if now - since >= thresholds.episodeReset { phase = .watching }
            return nil
        case let .waiting(attempt, due, failure, delivered):
            if health.run_slices == 0 && health.delivered_frames > delivered {
                phase = .recovered(attempts: attempt - 1, since: now)
                return nil
            }
            // The newest run says best what the next IO needs (a buffer that grew again, for one).
            let latest = health.run_slices > 0 ? Self.failure(of: health) : failure
            guard now >= due else {
                phase = .waiting(attempt: attempt, due: due, failure: latest, delivered: delivered)
                return nil
            }
            phase = .verifying(attempt: attempt, started: now, failure: latest)
            return .restart(attempt: attempt, failure: latest)
        case let .verifying(attempt, started, failure):
            if health.run_slices == 0 && sampleRate > 0 && Double(health.delivered_frames) / sampleRate >= thresholds.verifiedAudio {
                phase = .recovered(attempts: attempt, since: now)
                return nil
            }
            guard failing != nil || now - started >= thresholds.verifyTimeout else { return nil }
            return failed(attempt: attempt, failure: failing ?? failure, now: now, delivered: health.delivered_frames)
        }
    }

    /// The restart just decided could not open the device's IO.
    mutating func restartFailed(now: Double) -> Decision? {
        guard case let .verifying(attempt, _, failure) = phase else { return nil }
        return failed(attempt: attempt, failure: failure, now: now, delivered: 0)
    }

    /// The restart just decided replaced the capture session (a fresh analysis at the device's new rate): the episode
    /// carries on with it.
    mutating func adopt(session: UInt64) { self.session = session }

    /// Forgets the episode: a person's action, or a capture recovery does not watch.
    mutating func reset() {
        phase = .watching
        session = nil
    }

    private mutating func schedule(attempt: Int, failure: Failure, now: Double, health: CaptureHealthReading) -> Decision? {
        guard attempt <= thresholds.backoff.count else {
            phase = .watching
            return .giveUp(attempts: attempt - 1, failure: failure)
        }
        let due = now + thresholds.backoff[attempt - 1]
        guard now >= due else {
            phase = .waiting(attempt: attempt, due: due, failure: failure, delivered: health.delivered_frames)
            return nil
        }
        phase = .verifying(attempt: attempt, started: now, failure: failure)
        return .restart(attempt: attempt, failure: failure)
    }

    private mutating func failed(attempt: Int, failure: Failure, now: Double, delivered: UInt64) -> Decision? {
        guard attempt < thresholds.backoff.count else {
            phase = .watching
            return .giveUp(attempts: attempt, failure: failure)
        }
        phase = .waiting(attempt: attempt + 1, due: now + thresholds.backoff[attempt], failure: failure, delivered: delivered)
        return nil
    }
}
