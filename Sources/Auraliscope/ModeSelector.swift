import AnalysisCore
import SwiftUI

extension FormatMode {
    /// Name in Settings and menus, in the current language (立体声, 스테레오…).
    var title: String {
        switch self {
        case .auto: return L("Auto")
        case .mono: return L("Mono")
        case .stereo: return L("Stereo")
        // Every multichannel and object-based layout up to 9.1.6, not one product's format.
        case .spatial: return L("Immersive")
        }
    }
}

extension ChannelFormat {
    /// Name on the meter window, in the current language.
    var title: String { FormatMode(self).title }

    /// Name in tooltips and accessibility text, in the current language.
    var localizedName: String { title }

    /// The selector's label.
    var shortTitle: String { title }

    /// Segment order in the selector, narrowest programme first; Mono only when enabled (`MeterModel.selectorFormats`).
    static let selectorOrder: [ChannelFormat] = [.mono, .stereo, .spatial]
}

/// Top-bar monitoring mode: Mono | Stereo | Immersive on a recessed track, the mode in use a raised plate that
/// slides between them (`GlassSegments`), plus the AUTO switch. Choosing a segment pins that mode; AUTO hands
/// control back to the detector. Each segment is sized to its label in every language, so nothing is cropped.
struct ModeSelector: View {
    static let height: CGFloat = 28

    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    /// The toolbar sits outside the meter view, so it follows palette and appearance changes itself.
    @ObservedObject private var theme = ThemeSettings.shared

    var body: some View {
        let formats = model.selectorFormats
        HStack(spacing: 8) {
            GlassSegments(label: L("Monitoring mode"),
                          options: formats.map { ($0, $0.shortTitle, $0.localizedName) },
                          selection: model.format, select: { model.pin($0) }, large: true)
                .help(help(for: model.format))
            AutoToggle(auto: model.formatMode == .auto, detected: model.automaticFormat) {
                model.toggleAuto()
            }
        }
        .id(theme.signature)
    }

    private func help(for format: ChannelFormat) -> String {
        switch format {
        case .mono: return L("Monitor in Mono: one channel, read from the input routed to L")
        case .stereo: return L("Monitor in Stereo: L and R lead; other channels recede")
        case .spatial:
            if model.layoutFromPlugin { return L("Monitor in Immersive: every channel of the DAW plugin's %@ bus.", model.shownLayoutName) }
            return L("Monitor in Immersive: every channel of %@. Change the format in Settings ▸ Channels.", model.speakerLayout.name)
        }
    }
}

/// AUTO: the system switch with its label, so it is the Liquid Glass switch on macOS 26 (the knob turns to glass
/// while pressed or dragged) and the classic switch before it; clicking the label flips it, as beside any macOS
/// switch. It sits on a track like the segments'; while the detector drives the mode it is lit as a chosen segment
/// is (a glowing cream key on dark, a glowing white one on light), so AUTO reads as on at the same glance as Stereo | Immersive.
private struct AutoToggle: View {
    let auto: Bool
    let detected: ChannelFormat
    let action: () -> Void
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        // A toolbar hides a toggle's own label, so the title stands beside the switch and flips it too.
        HStack(spacing: 7) {
            Toggle(L("Auto mode"), isOn: Binding(get: { auto }, set: { if $0 != auto { action() } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.sage)
            Text(L("AUTO"))
                .font(.system(size: 9, weight: auto ? .bold : .semibold).width(.expanded))
                .tracking(l10n.tracking(Tracking.eyebrow))
                .foregroundStyle(auto ? Theme.onLit : Theme.secondary)
                .fixedSize()
                .onTapGesture(perform: action)
                .accessibilityHidden(true)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: ModeSelector.height - 4)
        .background {
            // The chosen segment's lit plate (`GlassSegments`), inside the same track.
            if auto {
                Capsule(style: .continuous).fill(Theme.lit)
                    .shadow(color: Theme.litHalo, radius: 6)
                    .shadow(color: .black.opacity(Theme.dark ? 0.0 : 0.14), radius: 2, y: 1)
                    .transition(.opacity)
            }
        }
        .padding(2)
        .background { DockTrack(radius: ModeSelector.height / 2) }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: auto)
        .accessibilityLabel(L("Auto mode"))
        .help(L("Auto: Mono when a single input is routed. Otherwise Immersive after 150 ms above −60 dBFS on any channel but L, R and LFE, and back to Stereo after 2.5 s of front-only programme. Silence holds the mode; LFE alone never switches it. Detected now: %@.", detected.localizedName))
    }
}
