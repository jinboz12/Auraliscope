import SwiftUI

/// How the status bar presents the meter's state: a tone for its dot and text, and at most one next step. The status
/// text itself stays `MeterStatus.text`; the diagnostic log keeps the technical detail.
enum StatusTone: Equatable {
    /// Measuring (a device, a DAW plugin streaming, the demo).
    case live
    /// Not measuring, by choice (paused, standby).
    case quiet
    /// Waiting for something, or measuring with a caveat: a source to choose, a plugin to connect or return, capture
    /// being restarted.
    case attention
    /// Stopped by a failure the person has to act on: access refused, capture given up, an analyzer that could not start.
    case alarm
}

/// The one action the status bar offers for a state, where one helps.
enum StatusAction: Equatable {
    case resume, chooseSource, chooseInsert, openPrivacy, tryAgain

    var title: String {
        switch self {
        case .resume: return L("Resume")
        case .chooseSource: return L("Choose Source…")
        case .chooseInsert: return L("Choose Insert…")
        case .openPrivacy: return L("Open Privacy Settings")
        case .tryAgain: return L("Try Again")
        }
    }
}

extension MeterStatus {
    var tone: StatusTone {
        switch self {
        case .capturing, .demo: return .live
        case .paused, .standby: return .quiet
        case .chooseInput, .waitingForPermission, .noDevice, .noSelection, .recovering: return .attention
        case .permissionDenied, .ringFailed, .dspFailed, .failure: return .alarm
        case let .bridge(_, condition, _, _):
            switch condition {
            case .streaming: return .live
            case .measurementPaused: return .quiet
            default: return .attention
            }
        }
    }

    /// The next step for this state. Recovery in progress offers none: it is already acting, and its retries are bounded.
    var action: StatusAction? {
        switch self {
        case .paused: return .resume
        case .chooseInput, .noSelection, .noDevice: return .chooseSource
        case .permissionDenied: return .openPrivacy
        case .failure: return .tryAgain
        case let .bridge(_, condition, _, _):
            switch condition {
            case .unchosen, .ambiguous: return .chooseInsert
            default: return nil
            }
        default: return nil
        }
    }
}

extension StatusTone {
    var color: Color {
        switch self {
        case .live: return Theme.sage
        case .quiet: return Theme.tertiary
        case .attention: return Theme.ochre
        case .alarm: return Theme.ember
        }
    }
}

@MainActor
extension MeterModel {
    func perform(_ action: StatusAction) {
        switch action {
        case .resume, .tryAgain: if !running { toggleCapture() }
        case .chooseSource, .chooseInsert: openSettings(.audio)
        case .openPrivacy: AudioPermission.shared.openSettings()
        }
    }
}
