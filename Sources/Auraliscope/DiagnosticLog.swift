import Foundation

/// A small plain-text log of what the app did, for support: one file per launch in the app's Logs folder
/// (`Library/Logs/Auraliscope` inside the sandbox container), the five newest kept, each capped at 256 KB. It
/// records events only (launch, device and capture changes, errors, format and mode changes, dropped audio, quit),
/// never audio or per-frame data. Writes go through a background queue, so logging never waits on the disk.
enum DiagnosticLog {
    static let keptFiles = 5
    static let maximumBytes = 256 * 1024

    /// The folder holding the log files, created on first use.
    static let folder: URL = {
        // Isolated UI/regression bundles must not rotate the user's real support logs.
        if Bundle.main.bundleIdentifier?.hasSuffix(".QA") == true {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Auraliscope-QA-Logs", isDirectory: true)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // The Auraliscope test builds run outside the sandbox, so they keep a folder of their own.
        let labs = Bundle.main.bundleIdentifier?.hasSuffix(".Labs") == true
        return library.appendingPathComponent(labs ? "Logs/Auraliscope" : "Logs/Auraliscope", isDirectory: true)
    }()

    private static let queue = DispatchQueue(label: "Auraliscope.DiagnosticLog", qos: .utility)
    private static var handle: FileHandle?
    private static var written = 0
    private static var full = false

    private static let lineTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Opens this launch's file, removes all but the newest files, and writes the header.
    static func start() {
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "log" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            // Timestamped names sort by age; make room for this launch's file.
            for old in existing.dropFirst(keptFiles - 1) { try? manager.removeItem(at: old) }
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd-HHmmss"
            let url = folder.appendingPathComponent("Auraliscope-\(stamp.string(from: Date())).log")
            guard manager.createFile(atPath: url.path, contents: nil),
                  let file = try? FileHandle(forWritingTo: url) else { return }
            handle = file
            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["AuraliscopeVersionLabel"] as? String ?? info["CFBundleShortVersionString"] as? String ?? "?"
            let build = info["CFBundleVersion"] as? String ?? "?"
            append("Auraliscope \(version) (build \(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(hardwareModel()) · \(Locale.preferredLanguages.first ?? "?")")
        }
    }

    /// Records one event line.
    static func event(_ message: String) {
        let time = Date()
        queue.async { append("\(lineTime.string(from: time)) \(message)") }
    }

    /// Flushes and closes the file; later events are dropped.
    static func finish(_ message: String) {
        event(message)
        queue.sync {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }

    private static func append(_ line: String) {
        guard let handle, !full, let data = (line + "\n").data(using: .utf8) else { return }
        if written + data.count > maximumBytes {
            full = true
            try? handle.write(contentsOf: Data("… log size limit reached; later events are not recorded\n".utf8))
            return
        }
        try? handle.write(contentsOf: data)
        written += data.count
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
