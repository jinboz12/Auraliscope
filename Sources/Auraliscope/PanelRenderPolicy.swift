import Foundation

/// A panel's placement, shared by the SwiftUI environment and the native drawing clients.
enum PanelContext { case grid, enlarged, window, strip }

/// Logical visibility is distinct from window visibility. Outgoing animation views can remain attached after
/// their panel was removed from a layout. A detached panel still visible in its own window must keep drawing.
enum PanelRenderPolicy {
    static func permits(context: PanelContext, hidden: Bool, detached: Bool, mainIsStrip: Bool,
                        inStrip: Bool, stripPresent: Bool, zoomMatches: Bool, zoomExpanded: Bool) -> Bool {
        switch context {
        case .grid: return !hidden && !detached && !mainIsStrip && !zoomExpanded
        case .enlarged: return !hidden && !detached && zoomMatches
        case .window: return detached
        case .strip: return stripPresent && inStrip && !detached
        }
    }

    static func physicallyVisible(windowVisible: Bool, hiddenAncestor: Bool, hasArea: Bool,
                                  transparentAncestor: Bool, held: Bool) -> Bool {
        windowVisible && !hiddenAncestor && hasArea && !transparentAncestor && !held
    }
}
