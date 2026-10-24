import Foundation

/// One saved Dock spectrum slot, displayed as the original panel or Multi-FFT. A presentation change never
/// rewrites the saved order/width. Old layouts containing both kinds keep the original spectrum's position.
enum DockSpectrumPolicy {
    static let legacy = "spectrum"
    static let multi = "multiFFT"

    static func canonical(_ panels: [String]) -> [String] {
        let hasLegacy = panels.contains(legacy)
        var seen = Set<String>()
        return panels.compactMap { panel in
            if panel == multi && hasLegacy { return nil }
            let slot = panel == multi ? legacy : panel
            return seen.insert(slot).inserted ? slot : nil
        }
    }
    static func displayed(_ panels: [String], useMultiFFT: Bool) -> [String] {
        canonical(panels).map { $0 == legacy && useMultiFFT ? multi : $0 }
    }
    static func savedSlot(_ panel: String) -> String { panel == multi ? legacy : panel }
    static func canonicalShares(_ shares: [String: Double]) -> [String: Double] {
        var result = shares
        if result[legacy] == nil { result[legacy] = result[multi] }
        result.removeValue(forKey: multi)
        return result
    }
    static func displayedShares(_ shares: [String: Double], useMultiFFT: Bool) -> [String: Double] {
        var result = canonicalShares(shares)
        if useMultiFFT, let width = result.removeValue(forKey: legacy) { result[multi] = width }
        return result
    }
}

/// The split between Multi-FFT and the original analyser stack. Minima shrink proportionally only when the
/// window cannot contain them; the requested share survives temporary small sizes and hidden panels.
struct MultiFFTStackLayout {
    static let defaultShare = 0.5
    let room: Double
    let top: Double
    let bottom: Double
    private let minimumTop: Double
    private let maximumTop: Double

    init(height: Double, share: Double, gap: Double) {
        room = max(0, height.isFinite ? height-max(0,gap) : 0)
        let scale = min(1,room/240)
        minimumTop = 100*scale
        maximumTop = max(minimumTop,room-140*scale)
        let share = share.isFinite ? min(1,max(0,share)) : Self.defaultShare
        top = min(maximumTop,max(minimumTop,room*share))
        bottom = max(0,room-top)
    }
    func dragging(to height: Double) -> Double {
        guard room > 0, height.isFinite else { return Self.defaultShare }
        return min(maximumTop,max(minimumTop,height))/room
    }
}
