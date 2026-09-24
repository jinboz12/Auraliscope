import AppKit
import SwiftUI

/// Native menu images preserve the exact swatch colors in both the menu and selected item. Theme names are
/// proper names and stay in English; only the accessibility label follows the language.
struct ThemePicker: NSViewRepresentable {
    @Binding var selection: String
    @ObservedObject private var l10n = Localizer.shared

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        for palette in Theme.Palette.allCases {
            button.addItem(withTitle: palette.title)
            let item = button.lastItem!
            item.representedObject = palette.rawValue
            item.toolTip = palette.hexLabel
            item.image = swatch(palette.accent)
        }
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        let selected = Theme.Palette(rawValue: selection) ?? .sage
        button.selectItem(at: Theme.Palette.allCases.firstIndex(of: selected)!)
        button.toolTip = "\(selected.title) · \(selected.hexLabel)"
        button.setAccessibilityLabel(L("Color theme"))
        button.setAccessibilityValue("\(selected.title), \(selected.hexLabel)")
    }

    private func swatch(_ rgb: Theme.RGB) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor(srgbRed: CGFloat(rgb.r), green: CGFloat(rgb.g), blue: CGFloat(rgb.b), alpha: 1).setFill()
            path.fill()
            // Resolved when the menu draws, so the rim suits the light or dark menu it sits in.
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
        @objc func select(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? String else { return }
            selection.wrappedValue = value
        }
    }
}
