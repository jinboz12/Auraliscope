import Combine
import Foundation

/// Whether this launch checks for updates by itself. Every normal launch does, once, whatever was checked before;
/// a launch made by a script or a test does not reach the network: a QA bundle, any command-line flag except the
/// plugin's `--bridge-launch` (self-tests, snapshots, previews, file analysis, capture checks, `--demo`), or
/// `AURALISCOPE_NO_UPDATE_CHECK` in the environment.
enum UpdateLaunchPolicy {
    static let interactiveFlags: Set<String> = ["--bridge-launch"]

    static func allows(arguments: [String], bundleID: String?, environment: [String: String]) -> Bool {
        guard bundleID?.hasSuffix(".QA") != true, environment["AURALISCOPE_NO_UPDATE_CHECK"] == nil,
              environment["XCTestConfigurationFilePath"] == nil else { return false }
        return !arguments.dropFirst().contains { $0.hasPrefix("--") && !interactiveFlags.contains($0) }
    }

    static var allowsThisLaunch: Bool {
        allows(arguments: CommandLine.arguments, bundleID: Bundle.main.bundleIdentifier,
               environment: ProcessInfo.processInfo.environment)
    }
}

/// One update check at a time, started by the launch or by Check for Updates…, through the existing client and channel.
/// A check the launch started is quiet: it reports nothing unless an update exists, which it offers as `notice` (never
/// downloaded or installed by itself). A manual request while it runs joins it and is then answered like any manual
/// check, failures included.
@MainActor
final class GitHubUpdateChecker: ObservableObject {
    static let shared = GitHubUpdateChecker()

    enum Origin { case automatic, manual }
    /// Why a check failed, for the message shown after a manual check.
    enum Failure: Equatable { case unavailable, rateLimited, invalidResponse, connection }
    enum State: Equatable { case idle, checking, finished(GitHubUpdateResult), failed(Failure) }
    struct Identity: Equatable {
        var version: String
        var build: Int
        var label: String
        static var running: Identity {
            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? "2.0"
            return Identity(version: version, build: Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
                            label: info["AuraliscopeVersionLabel"] as? String ?? version)
        }
    }
    typealias Fetch = @Sendable (_ identity: Identity, _ includePrereleases: Bool) async throws -> GitHubUpdateResult

    @Published private(set) var state = State.idle
    /// An update the launch check found, until dismissed for this launch.
    @Published private(set) var notice: GitHubReleaseUpdate?
    /// Network checks started, for the checks of this type.
    private(set) var started = 0
    private var origin = Origin.manual
    private var task: Task<Void, Never>?
    private var launchHandled = false
    private let fetch: Fetch
    private let identity: () -> Identity
    private let includePrereleases: () -> Bool
    private let log: (String) -> Void

    init(fetch: @escaping Fetch = GitHubUpdateChecker.liveFetch,
         identity: @escaping () -> Identity = { .running },
         includePrereleases: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: GitHubUpdateCatalog.prereleaseKey) },
         log: @escaping (String) -> Void = { DiagnosticLog.event($0) }) {
        self.fetch = fetch
        self.identity = identity
        self.includePrereleases = includePrereleases
        self.log = log
    }

    nonisolated static let liveFetch: Fetch = { identity, prereleases in
        try await GitHubUpdateClient().check(version: identity.version, build: identity.build, includePrereleases: prereleases,
                                             currentIsPrerelease: GitHubUpdateCatalog.isPrereleaseLabel(identity.label))
    }

    var checking: Bool { state == .checking }

    /// The launch's own check, once per process however often windows appear, `delay` seconds after launch so it never
    /// competes with the first window, audio start or the welcome. A check made before it (by hand) counts as it.
    func checkAtLaunch(allowed: Bool = UpdateLaunchPolicy.allowsThisLaunch, delay: Double = 4) {
        guard !launchHandled else { return }
        launchHandled = true
        guard allowed else { return }
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, self.started == 0 else { return }
            self.check(.automatic)
        }
    }

    func check(_ requested: Origin = .manual) {
        if checking {
            if requested == .manual { origin = .manual }
            return
        }
        origin = requested
        state = .checking
        started += 1
        let identity = identity(), prereleases = includePrereleases(), fetch = fetch
        task = Task { [weak self] in
            let outcome: Result<GitHubUpdateResult, Error>
            do { outcome = .success(try await fetch(identity, prereleases)) } catch { outcome = .failure(error) }
            guard !Task.isCancelled, let self else { return }
            self.finish(outcome)
        }
    }

    private func finish(_ outcome: Result<GitHubUpdateResult, Error>) {
        let automatic = origin == .automatic
        switch outcome {
        case .success(let result):
            state = .finished(result)
            if case .available(let release) = result {
                log("Update check: \(release.title) available\(automatic ? " (at launch)" : "")")
                if automatic { notice = release }
            } else if automatic {
                log("Update check at launch: up to date")
            }
        case .failure(let error):
            let failure: Failure
            switch error {
            case GitHubUpdateError.unavailable: failure = .unavailable
            case GitHubUpdateError.rateLimited: failure = .rateLimited
            case GitHubUpdateError.invalidResponse: failure = .invalidResponse
            default: failure = .connection
            }
            log("Update check\(automatic ? " at launch" : "") failed: \(error)")
            // The launch's check stays silent when it fails; Check for Updates… says why.
            state = automatic ? .idle : .failed(failure)
        }
    }

    func dismissNotice() { notice = nil }

    /// A result from the other channel no longer answers; the next check uses the new one.
    func channelChanged() {
        task?.cancel(); task = nil
        state = .idle
        notice = nil
    }
}
