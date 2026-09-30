import AnalysisCore
import Foundation

// The analysis core has no localized text; the band switchers' words live with the app.
extension StereoBands.Resolution {
    /// A group's label: its lower edge, or "Full band".
    func label(_ group: Int) -> String { self == .overall ? L("Full band") : StereoBands.label(groups[group][0]) }
    /// The switcher's segment: "Full band", "3 bands", "5 bands" (multiband meters name their split by the
    /// number of bands, and a meter that does not split reads full band).
    var title: String { self == .overall ? L("Full band") : L("%d bands", count) }
}
