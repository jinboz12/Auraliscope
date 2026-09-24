import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Authorization for direct input capture. Output taps request System Audio Recording separately on start.
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
    func refresh() { status = AVCaptureDevice.authorizationStatus(for: .audio) }
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
                .buttonStyle(.borderless).help(L("Check again"))
        }
    }
}
