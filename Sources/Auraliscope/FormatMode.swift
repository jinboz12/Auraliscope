import AnalysisCore
import Foundation

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
