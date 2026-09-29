import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Authorization for direct input capture. Output taps request System Audio Recording separately on start; macOS
/// offers no public way to read that permission, so only this one is shown. Checked at launch, whenever the app
/// becomes active and after each request, so the indicator never shows a stale state.
@MainActor
final class AudioPermission: ObservableObject {
    static let shared = AudioPermission()
    @Published private(set) var status = AVCaptureDevice.authorizationStatus(for: .audio)
    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    var granted: Bool { status == .authorized }
    func refresh() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphone != status { status = microphone }
    }
    /// Checks it at launch and records it in the diagnostic log.
    func checkAtLaunch() {
        refresh()
        DiagnosticLog.event("Privacy: microphone \(Self.logName(status))")
    }
    func request() {
        refresh()
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        } else if !granted {
            openSettings()
        }
    }
    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
    var statusText: String {
        switch status {
        case .authorized: return L("Allowed")
        case .notDetermined: return L("Not requested")
        case .denied: return L("Denied")
        case .restricted: return L("Restricted")
        @unknown default: return L("Unavailable")
        }
    }

    private static func logName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "allowed"
        case .notDetermined: return "not requested"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unavailable"
        }
    }
}

struct PermissionControl: View {
    @ObservedObject private var permission = AudioPermission.shared
    @ObservedObject private var l10n = Localizer.shared
    var body: some View {
        HStack(spacing: 10) {
            Text(permission.statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(permission.granted ? Theme.sage : Theme.ochre)
            Toggle(L("Microphone access"), isOn: Binding(
                get: { permission.granted },
                set: { enabled in
                    if enabled { permission.request() } else { permission.openSettings() }
                }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            Button { permission.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .glassIconButton().help(L("Check again"))
        }
    }
}
