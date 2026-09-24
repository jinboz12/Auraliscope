import Foundation

/// What the incoming programme is: a single channel, a plain L/R pair, or Spatial (the multichannel layout
/// chosen in Settings). The DSP-side detector only decides Stereo ↔ Spatial; Mono comes from the routing
/// (a single routed input) or from pinning it.
enum ChannelFormat: Int, CaseIterable {
    case stereo = 0
    case spatial = 1
    case mono = 2
}

/// User preference: follow the detector, or pin one format.
enum FormatMode: String, CaseIterable, Identifiable {
    case auto, mono, stereo, spatial

    init(_ format: ChannelFormat) {
        switch format {
        case .mono: self = .mono
        case .stereo: self = .stereo
        case .spatial: self = .spatial
        }
    }

    var id: String { rawValue }
    var fixed: ChannelFormat? {
        switch self {
        case .auto: return nil
        case .mono: return .mono
        case .stereo: return .stereo
        case .spatial: return .spatial
        }
    }
}

/// Hysteresis detector for Stereo ↔ Spatial, fed at 30 Hz (every other DSP tick) with per-role RMS over 1/30 s.
///
/// Evidence is programme on any positional channel other than L and R (centre, surrounds, wides, heights). LFE is not
/// evidence: bass management and FIR crossovers often derive it from a stereo source.
/// - Enter Spatial quickly: evidence above −60 dBFS (and within 40 dB of the louder front) for 150 ms.
/// - Leave Spatial promptly: 2.5 s of front-only programme, evidence below −64 dBFS or 45 dB under the fronts.
///   A stray blip on an extended channel only rolls the countdown back a little instead of restarting it.
/// - Between the two thresholds nothing changes, and silence on every channel freezes the state,
///   so fades, pauses and quiet passages never flip the display.
struct FormatDetector {
    static let evidenceRoles = Role.evidence
    static let enterLevel: Float = -60
    static let enterRelative: Float = 40
    static let exitLevel: Float = -64
    static let exitRelative: Float = 45
    static let programmeLevel: Float = -60
    static let attack: Float = 0.15
    static let release: Float = 2.5
    /// While counting down, each second of evidence takes this many seconds off the countdown.
    static let releaseRecovery: Float = 4

    private(set) var format: ChannelFormat
    /// False when no evidence channel is routed: the programme can only be stereo.
    let canDetectSpatial: Bool
    private var armed: Float = 0
    private var releasing: Float = 0

    init(initial: ChannelFormat = .stereo, canDetectSpatial: Bool = true) {
        self.canDetectSpatial = canDetectSpatial
        format = canDetectSpatial && initial == .spatial ? .spatial : .stereo
    }

    /// `rms` holds linear RMS values in role order (see `Role`); missing trailing roles count as silent.
    @discardableResult
    mutating func update(rms: [Float], deltaTime: Float) -> ChannelFormat {
        guard canDetectSpatial, rms.count >= 2 else { return format }
        let dt = max(0, min(0.25, deltaTime))
        let front = max(Self.decibels(rms[0]), Self.decibels(rms[1]))
        var loudest: Float = 0
        for role in Self.evidenceRoles where role < rms.count { loudest = max(loudest, rms[role]) }
        let evidence = Self.decibels(loudest)
        let present = evidence > Self.enterLevel && evidence > front - Self.enterRelative
        let absent = evidence < Self.exitLevel || evidence < front - Self.exitRelative
        switch format {
        case .stereo, .mono:
            // Integrate rather than count consecutive ticks, so isolated clicks decay away.
            if present { armed += dt } else if absent { armed = max(0, armed - dt) }
            if armed >= Self.attack {
                format = .spatial
                armed = 0
                releasing = 0
            }
        case .spatial:
            if present {
                // Sustained spatial programme pins the countdown at zero; an isolated click barely moves it.
                releasing = max(0, releasing - dt * Self.releaseRecovery)
            } else if absent && front > Self.programmeLevel {
                releasing += dt
            }
            if releasing >= Self.release {
                format = .stereo
                armed = 0
                releasing = 0
            }
        }
        return format
    }

    private static func decibels(_ amplitude: Float) -> Float {
        amplitude > 0.000001 ? 20 * log10(amplitude) : -120
    }
}
