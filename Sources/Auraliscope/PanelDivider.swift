import AppKit
import SwiftUI

/// Draggable splitter between two neighbouring panels: `.vertical` sits between stacked rows (row-resize),
/// `.horizontal` between side-by-side columns (column-resize).
///
/// It is an AppKit view rather than a SwiftUI gesture for three reasons: the window is movable by its
/// background, and only `mouseDownCanMoveWindow = false` reliably keeps a drag here from moving the window;
/// cursor rects give the resize cursor on hover without flicker; and hover/drag feedback lives on its own
/// layers, so the handle animates without SwiftUI view state (see the note on `@State` in MeterModel).
struct PanelDivider: NSViewRepresentable {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    /// Current size of the panel before the divider (above it, or to its left); a drag starts from it.
    let leading: CGFloat
    /// Called continuously during a drag with the requested size of the leading panel.
    let onResize: (CGFloat) -> Void
    /// Double-click: restore this divider's default position.
    let onReset: () -> Void
    /// Names the divider for the diagnostics (which strip gap it is).
    var identifier: String? = nil
    /// Redraws the tooltip and accessibility label when the language changes.
    @ObservedObject private var l10n = Localizer.shared

    func makeNSView(context: Context) -> PanelDividerView {
        let view = PanelDividerView(axis: axis)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PanelDividerView, context: Context) {
        view.leading = leading
        view.onResize = onResize
        view.onReset = onReset
        view.identifier = identifier.map { NSUserInterfaceItemIdentifier(rawValue: $0) }
        view.setAccessibilityLabel(L("Resize panels"))
        view.toolTip = L("Drag to resize · double-click to reset")
    }
}

final class PanelDividerView: NSView {
    let axis: PanelDivider.Axis
    var leading: CGFloat = 0
    var onResize: (CGFloat) -> Void = { _ in }
    var onReset: () -> Void = {}

    private let grip = CALayer()
    private var hovering = false { didSet { if hovering != oldValue { restyle() } } }
    private var dragging = false { didSet { if dragging != oldValue { restyle() } } }
    private var dragStart: CGFloat = 0
    private var dragStartLeading: CGFloat = 0
    private var cursorPushed = false

    private var cursor: NSCursor {
        if #available(macOS 15, *) { return axis == .vertical ? .rowResize : .columnResize }
        return axis == .vertical ? .resizeUpDown : .resizeLeftRight
    }

    init(axis: PanelDivider.Axis) {
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(grip)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityOrientation(axis == .vertical ? .horizontal : .vertical)
        restyle(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeGrip()
        CATransaction.commit()
    }

    /// A short capsule centred in the strip; it lengthens while dragging.
    private func placeGrip() {
        let length: CGFloat = dragging ? 56 : 36
        let thickness: CGFloat = 3
        grip.cornerRadius = thickness / 2
        switch axis {
        case .vertical:
            grip.frame = CGRect(x: (bounds.width - length) / 2, y: (bounds.height - thickness) / 2, width: length, height: thickness)
        case .horizontal:
            grip.frame = CGRect(x: (bounds.width - thickness) / 2, y: (bounds.height - length) / 2, width: thickness, height: length)
        }
    }

    private func restyle(animated: Bool = true) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.15 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setDisableActions(!animated)
        // Hidden at rest, so the gutters between cards stay clean; the pointer brings a grip up, and a drag lights
        // it in the accent.
        let rgb = dragging ? Theme.sageRGB : Theme.inkRGB
        let alpha: CGFloat = dragging ? 1 : (hovering ? 0.22 : 0)
        grip.backgroundColor = rgb.cgColor(alpha)
        placeGrip()
        CATransaction.commit()
    }

    // MARK: Cursor and hover

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways`: the meter usually floats beside a DAW that has focus, and the grips should still appear.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // MARK: Drag

    /// Pointer position along the drag axis, growing toward the trailing panel.
    private func position(_ event: NSEvent) -> CGFloat {
        // Window coordinates grow upward, so a downward drag is a negative y change.
        axis == .vertical ? -event.locationInWindow.y : event.locationInWindow.x
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset()
            return
        }
        dragStart = position(event)
        dragStartLeading = leading
        dragging = true
        // Keep the resize cursor while the pointer leaves the strip mid-drag.
        if !cursorPushed {
            cursor.push()
            cursorPushed = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        onResize(dragStartLeading + position(event) - dragStart)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Accessibility: VoiceOver increment/decrement nudges the boundary.

    override func accessibilityPerformIncrement() -> Bool {
        onResize(leading + 16)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onResize(leading - 16)
        return true
    }
}
