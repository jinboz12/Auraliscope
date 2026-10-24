import AppKit
import SwiftUI

@MainActor
extension PanelPlacement {
    func permitsDrawing(_ panel: MeterPanel, context: PanelContext) -> Bool {
        PanelRenderPolicy.permits(context: context, hidden: hidden.contains(panel), detached: detached.contains(panel),
            mainIsStrip: strip, inStrip: displayedStripPanels.contains(panel), stripPresent: strip || morph != nil,
            zoomMatches: zoom?.panel == panel, zoomExpanded: zoom?.expanded == true)
    }
}

extension NSView {
    /// Includes a hidden/transparent ancestor, clipping, minimized/occluded windows and zero-size transition views.
    var panelPhysicallyVisible: Bool {
        var transparent = false
        var ancestor: NSView? = self
        while let view = ancestor {
            if view.alphaValue <= 0.001 { transparent = true; break }
            ancestor = view.superview
        }
        return PanelRenderPolicy.physicallyVisible(windowVisible: window?.isVisible == true
                && window?.occlusionState.contains(.visible) == true,
            hiddenAncestor: isHiddenOrHasHiddenAncestor,
            hasArea: bounds.width > 0 && bounds.height > 0 && !visibleRect.isEmpty,
            transparentAncestor: transparent, held: false)
    }
}

private struct PanelDrawingActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var panelDrawingActive: Bool {
        get { self[PanelDrawingActiveKey.self] }
        set { self[PanelDrawingActiveKey.self] = newValue }
    }
}

/// Pauses SwiftUI-only plots/inspectors as well as the native Metal/VU clients. The initial picture is retained.
struct PanelTimeline<Content: View>: View {
    let interval: TimeInterval
    @ViewBuilder var content: () -> Content
    @Environment(\.panelDrawingActive) private var active
    @Environment(\.canvasesHeld) private var held
    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: !active || held)) { _ in content() }
    }
}

struct PanelRenderingScope: ViewModifier {
    let panel: MeterPanel
    @ObservedObject private var placement = PanelPlacement.shared
    @Environment(\.panelContext) private var context
    @Environment(\.canvasesHeld) private var held
    @State private var windowVisible = true
    func body(content: Content) -> some View {
        content
            .environment(\.panelDrawingActive, windowVisible && !held && placement.permitsDrawing(panel, context: context))
            .background(PanelWindowVisibility(visible: $windowVisible))
    }
}

private struct PanelWindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool
    func makeNSView(context: Context) -> Probe { Probe(changed: { visible = $0 }) }
    func updateNSView(_ view: Probe, context: Context) { view.changed = { visible = $0 }; view.note() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }
    final class Probe: NSView {
        var changed: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.note() })
                }
            }
            note()
        }
        func note() {
            let next = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
            guard next != last else { return }; last = next
            DispatchQueue.main.async { [weak self] in guard let self, self.last == next else { return }; self.changed(next) }
        }
        func stop() { for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = [] }
        deinit { stop() }
    }
}
