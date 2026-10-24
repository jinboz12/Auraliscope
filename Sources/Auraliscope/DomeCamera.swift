import SwiftUI
import simd

/// SwiftUI interpolates a pose (the dome's labels glide with it, `DomeLabels`).
extension DomePose {
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(turn, elevation), zoom) }
        set { turn = newValue.first.first; elevation = newValue.first.second; zoom = newValue.second }
    }
}

/// The Immersive dome's camera, as the panel's drag, pinch, scroll wheel, menus and settings set it. One shared object,
/// so a drag re-renders only the dome's labels, which observe it, and the canvas, which reads it every frame; the choice
/// is saved to the defaults when an interaction ends, not on every event. Picking a view, resetting and double-clicking
/// glide there (`glide`, matched by `DomeScene`'s own spring); dragging, pinching and scrolling follow the hand.
@MainActor
final class DomeCamera: ObservableObject {
    static let shared = DomeCamera()
    /// The glide's spring: the labels' SwiftUI animation and the canvas' critically damped step share its response.
    nonisolated static let response = 0.45
    static let glide = Animation.spring(response: response, dampingFraction: 1)

    struct Settings: Equatable {
        var view: DomeView
        var yaw: Double
        var pitch: Double
        var zoom: Double
    }

    struct State: Equatable {
        var settings: Settings
        /// The settings' pose, its turn continuous with the one shown before.
        var pose: DomePose
    }

    @Published private(set) var state: State
    /// The view alone, for the menus that pick it: published only when the view changes, so a drag leaves them be.
    let choice: DomeViewChoice
    /// Counts the changes made to glide; the canvas glides to a new pose when this has moved and follows otherwise.
    private(set) var glides = 0
    private var dragStart: (yaw: Double, pitch: Double)?
    private var pinchStart: Double?
    private var pendingSave: DispatchWorkItem?

    private init() {
        // The choice saved last (`DisplayOptions.stored` reads the same keys).
        let stored = DisplayOptions.stored
        let settings = Settings(view: stored.domeView, yaw: stored.domeYaw.isFinite ? stored.domeYaw : 0,
                                pitch: Self.clamp(stored.domePitch, DomeGeometry.pitchRange, DomeGeometry.defaultPitch),
                                zoom: Self.clamp(stored.domeZoom, DomeGeometry.zoomRange, 1))
        state = State(settings: settings, pose: DomePose(view: settings.view, yaw: settings.yaw, pitch: settings.pitch, zoom: settings.zoom))
        choice = DomeViewChoice(settings.view)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    var settings: Settings { state.settings }

    private func apply(_ settings: Settings, glide: Bool, save: Bool = true) {
        let pose = DomePose(view: settings.view, yaw: settings.yaw, pitch: settings.pitch, zoom: settings.zoom).near(state.pose.turn)
        let next = State(settings: settings, pose: pose)
        guard next != state else { return }
        if glide {
            glides += 1
            withAnimation(Self.glide) { state = next }
        } else {
            state = next
        }
        if choice.view != settings.view { choice.view = settings.view }
        if save { saveSoon() }
    }

    // MARK: Changes

    /// A view from the menus or the settings: glides there.
    func select(_ view: DomeView) {
        var next = settings
        next.view = view
        apply(next, glide: true)
    }

    /// Back to the default camera (double-click, Reset view): glides there.
    func reset() {
        var next = settings
        next.yaw = 0
        next.pitch = DomeGeometry.defaultPitch
        next.zoom = 1
        apply(next, glide: true)
    }

    /// Drag across to turn, up and down to raise or lower the camera. Front and Isometric carry on in the Dome view from
    /// their camera, Top turns, Side stays.
    func drag(translation: CGSize) {
        var next = settings
        guard next.view != .side else { return }
        if dragStart == nil {
            if let camera = next.view.camera, next.view != .top {
                next.yaw = camera.yaw
                next.pitch = Self.clamp(camera.pitch, DomeGeometry.pitchRange, DomeGeometry.defaultPitch)
                next.view = .perspective
            }
            dragStart = (next.yaw, next.pitch)
        }
        guard let start = dragStart else { return }
        next.yaw = (start.yaw + Double(translation.width) * 0.5).truncatingRemainder(dividingBy: 360)
        if next.view == .perspective {
            next.pitch = Self.clamp(start.pitch + Double(translation.height) * 0.35, DomeGeometry.pitchRange, DomeGeometry.defaultPitch)
        }
        apply(next, glide: false, save: false)
    }

    func endDrag() {
        dragStart = nil
        save()
    }

    /// A pinch over the dome: zooms from where the pinch began.
    func pinch(scale: CGFloat) {
        let start = pinchStart ?? settings.zoom
        pinchStart = start
        var next = settings
        next.zoom = Self.clamp(start * Double(scale), DomeGeometry.zoomRange, 1)
        apply(next, glide: false, save: false)
    }

    func endPinch() {
        pinchStart = nil
        save()
    }

    /// The scroll wheel or two fingers over the dome: zooms by `exp(delta)`; saved a moment after the last step. A
    /// mouse wheel's notches glide (`smooth`), two fingers follow at once.
    func scroll(delta: Double, smooth: Bool = false) {
        var next = settings
        next.zoom = Self.clamp(settings.zoom * exp(delta), DomeGeometry.zoomRange, 1)
        apply(next, glide: smooth)
    }

    /// The settings' zoom slider.
    func setZoom(_ zoom: Double) {
        var next = settings
        next.zoom = Self.clamp(zoom, DomeGeometry.zoomRange, 1)
        apply(next, glide: false)
    }

    /// `--test-dome-orbit`: a drag's camera step, without the gesture.
    func orbit(yaw: Double, pitch: Double) {
        var next = settings
        next.view = .perspective
        next.yaw = yaw.truncatingRemainder(dividingBy: 360)
        next.pitch = Self.clamp(pitch, DomeGeometry.pitchRange, DomeGeometry.defaultPitch)
        apply(next, glide: false, save: false)
    }

    // MARK: Saving

    private func saveSoon() {
        // A diagnostic snapshot's camera moves (`--snapshot-view-switch`) are never kept.
        guard !Diagnostics.snapshotRequested else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Writes the camera to the defaults (the panels' choices are kept there), once per interaction.
    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard !Diagnostics.snapshotRequested else { return }
        let d = UserDefaults.standard, s = settings
        if d.string(forKey: DomeView.key) != s.view.rawValue { d.set(s.view.rawValue, forKey: DomeView.key) }
        if d.double(forKey: DisplayOptions.domeYawKey) != s.yaw || d.object(forKey: DisplayOptions.domeYawKey) == nil {
            d.set(s.yaw, forKey: DisplayOptions.domeYawKey)
        }
        if d.double(forKey: DisplayOptions.domePitchKey) != s.pitch || d.object(forKey: DisplayOptions.domePitchKey) == nil {
            d.set(s.pitch, forKey: DisplayOptions.domePitchKey)
        }
        if d.double(forKey: DisplayOptions.domeZoomKey) != s.zoom || d.object(forKey: DisplayOptions.domeZoomKey) == nil {
            d.set(s.zoom, forKey: DisplayOptions.domeZoomKey)
        }
    }

    /// The canvas' copy for this frame: the settings, the pose and the glide count.
    func apply(to options: inout DisplayOptions) {
        let s = settings
        options.domeView = s.view
        options.domeYaw = s.yaw
        options.domePitch = s.pitch
        options.domeZoom = s.zoom
        options.domePose = state.pose
        options.domeGlides = glides
    }
}

/// The dome's view, for the menus that pick it (`DomeCamera.choice`).
@MainActor
final class DomeViewChoice: ObservableObject {
    @Published var view: DomeView
    init(_ view: DomeView) { self.view = view }
}

/// The canvas' side of a glide (`DomeScene`): a critically damped step per pose component toward its target with
/// `DomeCamera.response`, as SwiftUI's spring moves the labels. A target that moves without a new glide is followed at
/// once (the hand is on the camera).
struct DomePoseSpring {
    private(set) var pose: DomePose?
    private var velocity = SIMD3<Double>.zero
    private var glides = -1
    private var gliding = false
    /// The pose the current glide heads for.
    private var aim: DomePose?

    mutating func step(target: DomePose, glides: Int, dt: Double) -> DomePose {
        guard let current = pose, dt >= 0 else { return snap(target, glides) }
        if glides != self.glides {
            self.glides = glides
            gliding = true
            aim = target
        } else if !gliding || target != aim {
            // Nothing to glide to, or the hand took the camera mid-glide.
            gliding = false
            return snap(target, glides)
        }
        let goal = target.near(current.turn)
        let omega = 2 * Double.pi / DomeCamera.response
        let value = SIMD3(current.turn, current.elevation, current.zoom), aim = SIMD3(goal.turn, goal.elevation, goal.zoom)
        let displacement = value - aim
        let factor = exp(-omega * dt)
        let impulse = velocity + omega * displacement
        let next = aim + (displacement + impulse * dt) * factor
        velocity = (velocity - omega * impulse * dt) * factor
        let difference = next - aim
        if abs(difference.x) < 0.01 && abs(difference.y) < 0.01 && abs(difference.z) < 0.0005 && simd_length(velocity) < 0.05 {
            gliding = false
            return snap(goal, glides)
        }
        let result = DomePose(turn: next.x, elevation: next.y, zoom: next.z)
        pose = result
        return result
    }

    private mutating func snap(_ target: DomePose, _ glides: Int) -> DomePose {
        self.glides = glides
        velocity = .zero
        let result = pose.map { target.near($0.turn) } ?? target
        pose = result
        return result
    }
}
