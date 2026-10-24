import AnalysisCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The speaker layout editor (a window of its own, from the Soundstage panel's settings): where each speaker of a
/// channel format sits, for the Immersive soundstage and its analysis (locally and in a DAW plugin of build 98 or
/// later). Every change takes effect at once, so the dome follows the edit. The standard placements are never edited
/// in place: the first change makes a layout of its own for the format.
struct SpeakerLayoutEditor: View {
    static let windowID = "speakerLayout"
    @ObservedObject var model: MeterModel
    @ObservedObject private var store = SpeakerLayoutStore.shared
    @ObservedObject private var l10n = Localizer.shared
    @State private var format: SpeakerLayout
    @State private var preview = LayoutPreview.Face.top
    @State private var notes: [String] = []
    @State private var renaming: String?

    init(model: MeterModel) {
        self.model = model
        _format = State(initialValue: SpeakerLayoutStore.shared.editing ?? model.shownLayout)
    }

    private var active: SpeakerConfiguration? { store.configuration(for: format) }
    private var shown: SpeakerConfiguration { active ?? .standard(format) }

    var body: some View {
        // Laid out as a Settings page (`SettingsMetrics`): the same text column, gutters and cards over the same sky.
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                PageTitle(L("Speaker Layout"))
                    .padding(.leading, SettingsMetrics.inset)
                    .padding(.bottom, -6)
                layoutSection
                speakersSection
                previewSection
                fileSection
                ForEach(Array((notes + shown.problems(for: format)).enumerated()), id: \.offset) { _, note in
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.ochre)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SettingsMetrics.inset)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.gutter).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OverlayScrollers())
        }
        .frame(minWidth: 560, minHeight: 520)
        .background { WindowBackdrop() }
        // Like Settings: above a floating meter, and never reopened on its own at launch (restored alone, it would
        // stand in for the meter window).
        .background(UtilityWindowProbe(title: L("Speaker Layout")))
        // The format asked for when the window opens (the scene's view is made at launch, before any request) and
        // whenever it is asked for again while open.
        .onAppear {
            if let wanted = store.editing { format = wanted }
        }
        .onChange(of: store.editing) { wanted in
            if let wanted { format = wanted }
        }
    }

    // MARK: Layout

    private var layoutSection: some View {
        SettingsSection(title: L("LAYOUT")) {
            SettingsRow(title: L("Channel format")) {
                Picker(L("Channel format"), selection: $format) {
                    ForEach(SpeakerLayout.allCases) { Text(verbatim: $0.name).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow(title: L("Layout")) {
                HStack(spacing: 8) {
                    Picker(L("Layout"), selection: Binding(get: { active?.id }, set: { store.select($0, for: format) })) {
                        Text(L("Standard %@", format.name)).tag(UUID?.none)
                        ForEach(store.layouts(for: format)) { c in Text(verbatim: c.name).tag(Optional(c.id)) }
                    }
                    .labelsHidden().fixedSize()
                    Button { store.duplicate(shown, name: L("%@ copy", shown.name)) } label: { Label(L("Duplicate"), systemImage: "plus.square.on.square") }.glassButton()
                    if let active {
                        Button { renaming = active.name } label: { Label(L("Rename…"), systemImage: "pencil") }.glassButton()
                        Button(role: .destructive) { store.delete(active.id) } label: { Label(L("Delete"), systemImage: "trash") }.glassButton()
                    }
                }
            }
            if let name = renaming, let active {
                SettingsRow(title: L("Name")) {
                    HStack(spacing: 8) {
                        TextField(L("Name"), text: Binding(get: { renaming ?? name }, set: { renaming = $0 }))
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                            .onSubmit { commitName(active) }
                        Button { commitName(active) } label: { Label(L("Done"), systemImage: "checkmark") }.glassButton(prominent: true)
                    }
                }
            }
            SettingsRow(title: L("Radiant body places sound by")) {
                GlassSegments(label: L("Radiant body places sound by"),
                              options: SpeakerConfiguration.Mapping.allCases.map { ($0, mappingTitle($0), mappingTitle($0)) },
                              selection: shown.mapping, select: { mapping in edit { $0.mapping = mapping } })
            }
            note(shown.mapping == .positions
                 ? L("Speaker positions: each frequency at the centre of gravity of the speakers' positions in meters, weighted by its amplitude in each. It shows how the feeds share the signal out over this layout; it is not a measured source position or distance. Every included speaker needs its distance. The Level body keeps the speakers' directions: its radius is the level.")
                 : L("Speaker directions: each frequency at the centre of gravity of the speakers' directions, weighted by its amplitude in each, every speaker on the unit sphere (as in build 97). The radius is part of that average, not a distance."))
        }
    }

    private func mappingTitle(_ mapping: SpeakerConfiguration.Mapping) -> String {
        mapping == .positions ? L("Speaker positions") : L("Speaker directions")
    }

    private func commitName(_ configuration: SpeakerConfiguration) {
        var c = configuration
        let trimmed = (renaming ?? c.name).trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { c.name = trimmed }
        store.save(c)
        renaming = nil
    }

    // MARK: Speakers

    private var speakersSection: some View {
        SettingsSection(title: L("SPEAKERS")) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(L("Speaker")).frame(width: 64, alignment: .leading)
                    Text(L("Azimuth")).frame(width: 92, alignment: .trailing)
                    Text(L("Elevation")).frame(width: 92, alignment: .trailing)
                    Text(L("Distance")).frame(width: 104, alignment: .trailing)
                    Text(L("Included")).frame(width: 64, alignment: .center)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
                .padding(.vertical, 8)
                ForEach(format.speakers, id: \.role) { speaker in
                    if speaker.group == .lfe {
                        HStack(spacing: 10) {
                            Text(verbatim: speaker.name).frame(width: 64, alignment: .leading)
                            Text(L("No direction: shown as the arc around the listener, never placed."))
                                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 28)
                    } else {
                        row(speaker)
                    }
                }
            }
            note(L("Azimuth in degrees clockwise from the front (left is negative), elevation in degrees up from the ear plane (below it negative), distance in meters from the listening position; leave the distance empty when it is not known. Routing (which input feeds which speaker) stays in Settings ▸ Channels."))
        }
    }

    private func row(_ speaker: Speaker) -> some View {
        let s = shown.speaker(speaker.role) ?? SpeakerConfiguration.standard(format).speaker(speaker.role)!
        let name = SpatialGeometry.roleNames[speaker.role]
        return HStack(spacing: 10) {
            Text(verbatim: speaker.name).font(.system(size: 13, weight: .medium)).frame(width: 64, alignment: .leading)
            number(s.azimuth, unit: "°") { value in update(name) { $0.azimuth = Self.wrap(value) } }
            number(s.elevation, unit: "°") { value in update(name) { $0.elevation = min(90, max(-90, value)) } }
            distance(s.distance) { value in update(name) { $0.distance = value } }
            Toggle(L("Included"), isOn: Binding(get: { s.included }, set: { on in update(name) { $0.included = on } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini).frame(width: 64)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30)
    }

    private static func wrap(_ azimuth: Double) -> Double {
        var a = azimuth.truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a <= -180 { a += 360 }
        return a
    }

    private func number(_ value: Double, unit: String, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 3) {
            TextField("", value: Binding(get: { value }, set: { if $0.isFinite { set($0) } }),
                      format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 70)
            Text(verbatim: unit).font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 12, alignment: .leading)
        }
        .frame(width: 92, alignment: .trailing)
    }

    private func distance(_ value: Double?, set: @escaping (Double?) -> Void) -> some View {
        HStack(spacing: 3) {
            TextField(L("unknown"), text: Binding(get: { value.map { String(format: "%.2f", $0) } ?? "" }, set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                if trimmed.isEmpty { set(nil) }
                else if let d = Double(trimmed), d.isFinite { set(min(SpatialGeometry.distanceRange.upperBound, max(SpatialGeometry.distanceRange.lowerBound, d))) }
            }))
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 78)
            Text(verbatim: "m").font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 12, alignment: .leading)
        }
        .frame(width: 104, alignment: .trailing)
    }

    /// Changes the shown layout: the standard placements become a layout of their own first.
    private func edit(_ change: (inout SpeakerConfiguration) -> Void) {
        var c = active ?? {
            var fresh = SpeakerConfiguration.standard(format)
            fresh.name = L("Custom %@", format.name)
            return fresh
        }()
        change(&c)
        let saved = store.save(c)
        if active == nil { store.select(saved.id, for: format) }
        notes = []
    }

    private func update(_ role: String, _ change: @escaping (inout SpeakerConfiguration.Speaker) -> Void) {
        edit { c in
            if let index = c.speakers.firstIndex(where: { $0.role == role }) { change(&c.speakers[index]) }
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        SettingsSection(title: L("PREVIEW")) {
            VStack(alignment: .leading, spacing: 10) {
                GlassSegments(label: L("Preview"), options: LayoutPreview.Face.allCases.map { ($0, $0.title, $0.title) },
                              selection: preview, select: { preview = $0 })
                LayoutPreview(layout: format, configuration: shown, view: preview)
                    .frame(height: 260)
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: File

    private var fileSection: some View {
        SettingsSection(title: L("EDIT")) {
            SettingsRow(title: L("Mirror")) {
                HStack(spacing: 8) {
                    Button { edit { $0 = $0.mirrored(from: true) } } label: { Label(L("Left to right"), systemImage: "arrow.right") }.glassButton()
                    Button { edit { $0 = $0.mirrored(from: false) } } label: { Label(L("Right to left"), systemImage: "arrow.left") }.glassButton()
                }
            }
            SettingsRow(title: L("Standard placements")) {
                Button {
                    edit { c in
                        let standard = SpeakerConfiguration.standard(format)
                        c.speakers = standard.speakers
                        c.mapping = .directions
                    }
                } label: {
                    Label(L("Restore"), systemImage: "arrow.counterclockwise")
                }
                .glassButton()
            }
            SettingsRow(title: L("File")) {
                HStack(spacing: 8) {
                    Button { importLayout() } label: { Label(L("Import…"), systemImage: "square.and.arrow.down") }.glassButton()
                    Button { exportLayout() } label: { Label(L("Export…"), systemImage: "square.and.arrow.up") }.glassButton()
                }
            }
            note(L("A layout file is JSON: the channel format, the mapping and each speaker's role, azimuth, elevation and distance (null when unknown), in the listener's frame (x right, y front, z up)."))
        }
    }

    private func importLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (configuration, notes) = try store.importLayout(from: url)
            if let layout = SpeakerLayout(rawValue: configuration.channelFormat) { format = layout }
            self.notes = notes
        } catch {
            notes = ["\(error)"]
        }
    }

    private func exportLayout() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = shown.name.replacingOccurrences(of: "/", with: "-") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(shown, to: url) } catch { notes = ["\(error)"] }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
    }
}

/// A small drawing of a speaker layout seen from above, from behind the listener (front) or from the right (side):
/// the listener, the speakers where the layout puts them (in meters with the positions mapping, else on the unit
/// circle), and a scale.
struct LayoutPreview: View {
    enum Face: String, CaseIterable {
        case top, front, side
        var title: String {
            switch self {
            case .top: return L("Top")
            case .front: return L("Front")
            case .side: return L("Side")
            }
        }
    }
    let layout: SpeakerLayout
    let configuration: SpeakerConfiguration
    let view: Face
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let geometry = SpatialGeometry(placements: configuration.placements(for: layout), mapping: configuration.mapping.spatial,
                                       roles: layout.roles)
        let extent = geometry.extent(roles: layout.roles)
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = min(size.width, size.height) / 2 * 0.78 / extent
            // Screen coordinates of a point (x right, y front, z up).
            func screen(_ p: SIMD3<Double>) -> CGPoint {
                switch view {
                case .top: return CGPoint(x: centre.x + p.x * scale, y: centre.y - p.y * scale)
                case .front: return CGPoint(x: centre.x + p.x * scale, y: centre.y - p.z * scale)
                case .side: return CGPoint(x: centre.x + p.y * scale, y: centre.y - p.z * scale)
                }
            }
            let ink = Theme.ink
            // The scale: rings (top) or lines (front, side) at every meter, or the unit circle for directions.
            let rings = geometry.mapping == .positions ? DomeScene.meterRings(extent) : [1.0]
            for r in rings {
                if view == .top {
                    let rect = CGRect(x: centre.x - r * scale, y: centre.y - r * scale, width: 2 * r * scale, height: 2 * r * scale)
                    context.stroke(Path(ellipseIn: rect), with: .color(ink.opacity(0.14)), lineWidth: 0.75)
                } else {
                    var arc = Path()
                    arc.addArc(center: centre, radius: r * scale, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                    context.stroke(arc, with: .color(ink.opacity(0.10)), lineWidth: 0.6)
                }
                if geometry.mapping == .positions {
                    context.draw(Text(verbatim: r.rounded() == r ? "\(Int(r)) m" : String(format: "%.1f m", r)).font(.system(size: 9))
                        .foregroundColor(Theme.tertiary), at: CGPoint(x: centre.x + r * scale + 14, y: centre.y + 7))
                }
            }
            // The ear plane in the front and side views.
            if view != .top {
                var line = Path()
                line.move(to: CGPoint(x: 8, y: centre.y))
                line.addLine(to: CGPoint(x: size.width - 8, y: centre.y))
                context.stroke(line, with: .color(ink.opacity(0.22)), lineWidth: 0.75)
            }
            // The listener and the front.
            context.fill(Path(ellipseIn: CGRect(x: centre.x - 3, y: centre.y - 3, width: 6, height: 6)), with: .color(ink.opacity(0.8)))
            let front = view == .top ? CGPoint(x: centre.x, y: centre.y - 1.12 * extent * scale)
                : (view == .side ? CGPoint(x: centre.x + 1.12 * extent * scale, y: centre.y - 10) : nil) ?? .zero
            if view != .front {
                context.draw(Text(L("FRONT")).font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.tertiary), at: front)
            }
            // The speakers, nearer ones last; left out ones hollow.
            let speakers = layout.speakers.filter { $0.group != .lfe }
            for speaker in speakers {
                let placement = geometry.placements[speaker.role]
                let u = SpeakerGeometry.direction(azimuth: placement.azimuth, elevation: placement.elevation)
                let p = geometry.mapping == .positions ? u * (placement.distance ?? extent) : u
                let at = screen(p)
                let dot = CGRect(x: at.x - 4, y: at.y - 4, width: 8, height: 8)
                if placement.included {
                    context.fill(Path(ellipseIn: dot), with: .color(Theme.sage))
                } else {
                    context.stroke(Path(ellipseIn: dot), with: .color(Theme.tertiary), lineWidth: 1)
                }
                context.draw(Text(verbatim: speaker.name).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.secondary),
                             at: CGPoint(x: at.x, y: at.y - 11))
            }
        }
        .accessibilityLabel(L("Speaker layout preview"))
    }
}
