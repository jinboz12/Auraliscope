import AnalysisCore
import AudioToolbox
import Foundation

/// Which speaker each channel of a device or a file feeds, as its Core Audio channel labels say: a device's speaker
/// configuration (Audio MIDI Setup ▸ Configure Speakers, the device's preferred channel layout) or a file's channel
/// layout (a WAV file's channel mask, a CAF or AIFF layout).
struct SpeakerMap: Equatable {
    /// Per channel, in the device's or file's order: its role (`Role`), or nil for a channel without one (no label, a
    /// speaker no layout of Auraliscope has, such as Lc or Cs, or a role an earlier channel already feeds).
    var roles: [Int?]

    init(roles: [Int?]) { self.roles = roles }

    /// The roles `labels` describe (`ChannelLabels.roles`), nil when they are a driver's placeholder for a channel
    /// layout nobody set (`ChannelLabels.isPlaceholder`).
    init?(labels: [AudioChannelLabel]) {
        guard !labels.isEmpty, !ChannelLabels.isPlaceholder(labels) else { return nil }
        roles = ChannelLabels.roles(labels)
    }

    var described: [Int] { roles.compactMap { $0 } }
    /// Whether the labels describe a speaker configuration rather than a plain stereo pair: three roles or more.
    var configured: Bool { described.count >= 3 }
    /// Whether every channel has a role of its own (a file is read by its labels only then).
    var complete: Bool { !roles.isEmpty && roles.allSatisfy { $0 != nil } }
    /// The smallest of Auraliscope's layouts that holds every role described.
    var layout: SpeakerLayout? { SpeakerLayout.containing(described) }
    /// The configuration's name: the layout's when the roles are exactly its roles ("9.1.6"), else how many speakers.
    var name: String {
        if let layout, Set(layout.roles) == Set(described) { return layout.name }
        return L("%d speakers", described.count)
    }

    /// Each role of `layout` from the channel the labels give it, among the first `channels`; −1 for a role they do
    /// not describe (it is left unrouted rather than guessed).
    func routing(for layout: SpeakerLayout, channels: Int) -> [Int32] {
        var routing = [Int32](repeating: -1, count: Role.count)
        for (channel, role) in roles.enumerated() where channel < channels {
            if let role, layout.contains(role) { routing[role] = Int32(channel) }
        }
        return routing
    }
}

enum ChannelLabels {
    /// Each label's role, read in the context of the whole set:
    /// - Left surround is the side surround (Ls/Lss), unless a side surround of its own (Left surround direct, Left side
    ///   surround) is also there: then it is the rear one (Lrs), as in a WAV file's back-left channel.
    /// - Rear surround left (and Left back surround) is the rear surround.
    /// - Top front (vertical height), top middle (and top surround) and top rear are the three height pairs; a top
    ///   middle pair alone (Audio MIDI Setup's 5.1.2 and 7.1.2, Core Audio's Atmos x.x.2) is Auraliscope's x.x.2 pair,
    ///   which is drawn at the top front.
    /// - The LFE is the screen LFE, else LFE 2.
    /// A role only once: a second channel with the same role gets none.
    static func roles(_ labels: [AudioChannelLabel]) -> [Int?] {
        let present = Set(labels)
        func any(_ list: [AudioChannelLabel]) -> Bool { list.contains(where: present.contains) }
        let sides = any([kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect,
                         kAudioChannelLabel_LeftSideSurround, kAudioChannelLabel_RightSideSurround])
        let frontOrRearTop = any([kAudioChannelLabel_LeftTopFront, kAudioChannelLabel_RightTopFront, kAudioChannelLabel_TopBackLeft,
                                  kAudioChannelLabel_TopBackRight, kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_RightTopRear])
        let screenLFE = present.contains(kAudioChannelLabel_LFEScreen)
        var taken = Set<Int>()
        return labels.map { label -> Int? in
            let role: Int?
            switch label {
            case kAudioChannelLabel_Left: role = Role.left
            case kAudioChannelLabel_Right: role = Role.right
            case kAudioChannelLabel_Center: role = Role.center
            case kAudioChannelLabel_LFEScreen: role = Role.lfe
            case kAudioChannelLabel_LFE2: role = screenLFE ? nil : Role.lfe
            case kAudioChannelLabel_LeftSurround: role = sides ? Role.leftRearSurround : Role.leftSurround
            case kAudioChannelLabel_RightSurround: role = sides ? Role.rightRearSurround : Role.rightSurround
            case kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_LeftSideSurround: role = Role.leftSurround
            case kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RightSideSurround: role = Role.rightSurround
            case kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_LeftBackSurround: role = Role.leftRearSurround
            case kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_RightBackSurround: role = Role.rightRearSurround
            case kAudioChannelLabel_LeftWide: role = Role.leftWide
            case kAudioChannelLabel_RightWide: role = Role.rightWide
            case kAudioChannelLabel_LeftTopFront: role = Role.leftTopFront
            case kAudioChannelLabel_RightTopFront: role = Role.rightTopFront
            case kAudioChannelLabel_LeftTopMiddle, kAudioChannelLabel_LeftTopSurround:
                role = frontOrRearTop ? Role.leftTopMiddle : Role.leftTopFront
            case kAudioChannelLabel_RightTopMiddle, kAudioChannelLabel_RightTopSurround:
                role = frontOrRearTop ? Role.rightTopMiddle : Role.rightTopFront
            case kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_LeftTopRear: role = Role.leftTopRear
            case kAudioChannelLabel_TopBackRight, kAudioChannelLabel_RightTopRear: role = Role.rightTopRear
            default: role = nil
            }
            guard let role, taken.insert(role).inserted else { return nil }
            return role
        }
    }

    /// Whether `labels` are a driver's placeholder rather than a configuration: label n on channel n for more channels
    /// than a 5.1 has (Pro Tools Audio Bridge, for one, reports this for every scope nobody configured). Up to six
    /// channels the same labels are a real L R C LFE Ls Rs.
    static func isPlaceholder(_ labels: [AudioChannelLabel]) -> Bool {
        labels.count > 6 && labels.enumerated().allSatisfy { $0.element == AudioChannelLabel($0.offset + 1) }
    }

    /// The labels of `layout` (`size` bytes), one per channel: its channel descriptions, or those of its layout tag or
    /// channel bitmap as Core Audio expands them. Empty when it describes none.
    static func labels(_ layout: UnsafePointer<AudioChannelLayout>, size: Int) -> [AudioChannelLabel] {
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions { return descriptions(layout, size: size) }
        // A tag or a bitmap: Core Audio's own expansion into descriptions.
        var bitmap = layout.pointee.mChannelBitmap
        var tagValue = tag
        let bitmapped = tag == kAudioChannelLayoutTag_UseChannelBitmap
        let property = bitmapped ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
        var expandedSize: UInt32 = 0
        let specifierSize = UInt32(MemoryLayout<UInt32>.size)
        let status = bitmapped
            ? AudioFormatGetPropertyInfo(property, specifierSize, &bitmap, &expandedSize)
            : AudioFormatGetPropertyInfo(property, specifierSize, &tagValue, &expandedSize)
        guard status == noErr, expandedSize >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(expandedSize), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        let read = bitmapped
            ? AudioFormatGetProperty(property, specifierSize, &bitmap, &expandedSize, raw)
            : AudioFormatGetProperty(property, specifierSize, &tagValue, &expandedSize, raw)
        // The expansion keeps the tag and fills in the descriptions.
        guard read == noErr else { return [] }
        return descriptions(raw.assumingMemoryBound(to: AudioChannelLayout.self), size: Int(expandedSize))
    }

    /// The labels of `layout`'s channel descriptions, whatever its tag says.
    private static func descriptions(_ layout: UnsafePointer<AudioChannelLayout>, size: Int) -> [AudioChannelLabel] {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions) ?? 12
        guard count > 0, offset + count * MemoryLayout<AudioChannelDescription>.stride <= size else { return [] }
        let first = (UnsafeRawPointer(layout) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return UnsafeBufferPointer(start: first, count: count).map(\.mChannelLabel)
    }
}
