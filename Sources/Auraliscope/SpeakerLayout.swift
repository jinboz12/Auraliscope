import AnalysisCore
import Foundation

enum SpeakerGroup { case front, surround, lfe, height }

struct Speaker: Equatable {
    let role: Int
    let name: String
    let group: SpeakerGroup
    /// Degrees clockwise from front; nil for the non-directional LFE.
    let azimuth: Double?
}

/// The multichannel format shown in Spatial mode, chosen in Settings → Channels. Stereo mode always shows L/R.
enum SpeakerLayout: String, CaseIterable, Identifiable {
    case lcr = "3.0", quad = "4.0", s50 = "5.0", s51 = "5.1", s512 = "5.1.2", s514 = "5.1.4"
    case s70 = "7.0", s71 = "7.1", s712 = "7.1.2", s714 = "7.1.4", s716 = "7.1.6"
    case s914 = "9.1.4", s916 = "9.1.6"

    static let standard = SpeakerLayout.s512
    var id: String { rawValue }
    var name: String { rawValue }

    /// Roles in the conventional SMPTE / ITU-R BS.2051 channel order, which is also the default routing:
    /// input 1 feeds the first role, input 2 the second, and so on.
    var roles: [Int] {
        let bed51 = [Role.left, Role.right, Role.center, Role.lfe, Role.leftSurround, Role.rightSurround]
        let bed71 = bed51 + [Role.leftRearSurround, Role.rightRearSurround]
        let bed91 = bed71 + [Role.leftWide, Role.rightWide]
        let top2 = [Role.leftTopFront, Role.rightTopFront]
        let top4 = top2 + [Role.leftTopRear, Role.rightTopRear]
        let top6 = top2 + [Role.leftTopMiddle, Role.rightTopMiddle, Role.leftTopRear, Role.rightTopRear]
        switch self {
        case .lcr: return [Role.left, Role.right, Role.center]
        case .quad: return [Role.left, Role.right, Role.leftSurround, Role.rightSurround]
        case .s50: return [Role.left, Role.right, Role.center, Role.leftSurround, Role.rightSurround]
        case .s51: return bed51
        case .s512: return bed51 + top2
        case .s514: return bed51 + top4
        case .s70: return bed71.filter { $0 != Role.lfe }
        case .s71: return bed71
        case .s712: return bed71 + top2
        case .s714: return bed71 + top4
        case .s716: return bed71 + top6
        case .s914: return bed91 + top4
        case .s916: return bed91 + top6
        }
    }

    var channelCount: Int { roles.count }
    var hasLFE: Bool { roles.contains(Role.lfe) }
    var heightCount: Int { speakers.filter { $0.group == .height }.count }
    /// Side surrounds sit at ±110° in 5.x and quad, at ±90° once rear surrounds join them.
    private var sideAzimuth: Double { roles.contains(Role.leftRearSurround) ? 90 : 110 }

    func contains(_ role: Int) -> Bool { roles.contains(role) }

    /// The layout with the fewest channels that holds every one of `roles` (9.1.6 holds all 16), the first in
    /// `allCases` order among equals; nil only for roles outside `Role`.
    static func containing(_ roles: [Int]) -> SpeakerLayout? {
        allCases.filter { layout in roles.allSatisfy(layout.contains) }.min { $0.channelCount < $1.channelCount }
    }

    /// Display order for meters and waveform lanes: front (with wides), LFE, surrounds, then heights.
    var speakers: [Speaker] { Self.speakerTable[self]! }

    /// Built once: layouts are read on every display frame.
    private static let speakerTable = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.buildSpeakers()) })

    private func buildSpeakers() -> [Speaker] {
        let all = (0..<Role.count).compactMap { role -> Speaker? in
            guard contains(role) else { return nil }
            return Self.speaker(role, side: sideAzimuth)
        }
        let order: [SpeakerGroup] = [.front, .lfe, .surround, .height]
        return order.flatMap { group in all.filter { $0.group == group } }
    }

    /// Groups present in this layout, in display order.
    var groups: [SpeakerGroup] {
        [SpeakerGroup.front, .lfe, .surround, .height].filter { group in speakers.contains { $0.group == group } }
    }

    /// Positions come from the analysis' own table (`SpeakerGeometry`), so the spatial field and the speakers drawn
    /// around it agree.
    private static func speaker(_ role: Int, side: Double) -> Speaker {
        let azimuth = SpeakerGeometry.azimuth(role: role, sidesAtNinety: side == 90)
        switch role {
        case Role.left: return Speaker(role: role, name: "L", group: .front, azimuth: azimuth)
        case Role.right: return Speaker(role: role, name: "R", group: .front, azimuth: azimuth)
        case Role.center: return Speaker(role: role, name: "C", group: .front, azimuth: azimuth)
        case Role.lfe: return Speaker(role: role, name: "LFE", group: .lfe, azimuth: nil)
        case Role.leftSurround: return Speaker(role: role, name: side == 90 ? "Lss" : "Ls", group: .surround, azimuth: azimuth)
        case Role.rightSurround: return Speaker(role: role, name: side == 90 ? "Rss" : "Rs", group: .surround, azimuth: azimuth)
        case Role.leftTopFront: return Speaker(role: role, name: "Ltf", group: .height, azimuth: azimuth)
        case Role.rightTopFront: return Speaker(role: role, name: "Rtf", group: .height, azimuth: azimuth)
        case Role.leftRearSurround: return Speaker(role: role, name: "Lrs", group: .surround, azimuth: azimuth)
        case Role.rightRearSurround: return Speaker(role: role, name: "Rrs", group: .surround, azimuth: azimuth)
        case Role.leftWide: return Speaker(role: role, name: "Lw", group: .front, azimuth: azimuth)
        case Role.rightWide: return Speaker(role: role, name: "Rw", group: .front, azimuth: azimuth)
        case Role.leftTopMiddle: return Speaker(role: role, name: "Ltm", group: .height, azimuth: azimuth)
        case Role.rightTopMiddle: return Speaker(role: role, name: "Rtm", group: .height, azimuth: azimuth)
        case Role.leftTopRear: return Speaker(role: role, name: "Ltr", group: .height, azimuth: azimuth)
        default: return Speaker(role: role, name: "Rtr", group: .height, azimuth: azimuth)
        }
    }

    /// Whether this layout's side surrounds sit at ±90° (`SpeakerGeometry`).
    var sidesAtNinety: Bool { sideAzimuth == 90 }

    /// Name of a role inside this layout (used by routing and labels).
    func name(of role: Int) -> String { Self.speaker(role, side: sideAzimuth).name }
}
