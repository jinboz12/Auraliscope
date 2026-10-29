import Foundation

/// The launch's update check: release ordering from a pre-release to its final release, which launches may check,
/// once per launch, joined manual requests, and silent failures. Every check runs against an injected fetch: no
/// network.
enum UpdateLaunchChecks {
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
    }

    static func release(tag: String, name: String, asset: String, prerelease: Bool = false) -> Data {
        let object: [String: Any] = ["tag_name": tag, "name": name,
            "html_url": "https://github.com/jinboz12/Auraliscope/releases/tag/\(tag)", "draft": false, "prerelease": prerelease,
            "assets": [["name": asset, "state": "uploaded",
                        "browser_download_url": "https://github.com/jinboz12/Auraliscope/releases/download/\(tag)/\(asset)"]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func offered(_ data: Data, build: Int = 120, label: String = "2.0 rc 3", prereleases: Bool = false) throws -> Bool {
        let list = prereleases ? "[\(String(decoding: data, as: UTF8.self))]".data(using: .utf8)! : data
        if case .available = try GitHubUpdateCatalog.evaluate(list, currentVersion: "2.0", currentBuild: build,
                                                             includePrereleases: prereleases,
                                                             currentIsPrerelease: GitHubUpdateCatalog.isPrereleaseLabel(label)) { return true }
        return false
    }

    @MainActor
    static func run() async throws {
        // Labels.
        for label in ["2.0 rc 3", "2.0 RC3", "2.0 beta", "2.1 beta 2", "2.0-alpha1"] {
            try check(GitHubUpdateCatalog.isPrereleaseLabel(label), "pre-release label not recognised: \(label)")
        }
        for label in ["2.0", "2.0.1", "Auraliscope 2.0", "2.0 (build 121)", "2.0 orchestra"] {
            try check(!GitHubUpdateCatalog.isPrereleaseLabel(label), "final label taken for a pre-release: \(label)")
        }
        // RC to stable, on the stable channel (`/releases/latest`).
        let final = release(tag: "v2.0", name: "Auraliscope 2.0", asset: "Auraliscope 2.0.pkg")
        try check(try offered(final), "2.0 rc 3 (120) not offered the final 2.0 that names no build")
        try check(try offered(release(tag: "v2.0", name: "Auraliscope 2.0 (Build 121)", asset: "Auraliscope 2.0 build 121.pkg")),
                  "final 2.0 build 121 not offered to rc 3 build 120")
        try check(try offered(release(tag: "v2.0", name: "Auraliscope 2.0 (Build 120)", asset: "Auraliscope 2.0 build 120.pkg")),
                  "final 2.0 of the same build not offered to its rc")
        try check(!(try offered(release(tag: "v2.0", name: "Auraliscope 2.0 (Build 118)", asset: "Auraliscope 2.0 build 118.pkg"))),
                  "an older-build final 2.0 offered to rc 3 build 120")
        try check(!(try offered(final, build: 121, label: "2.0")), "the final 2.0 offered to itself")
        try check(!(try offered(final, build: 121, label: "2.0")) && (try offered(release(tag: "v2.0.1", name: "Auraliscope 2.0.1",
                  asset: "Auraliscope 2.0.1.pkg"), build: 121, label: "2.0")), "stable to stable ordering changed")
        // The pre-release channel: the final release beats its own release candidates at the same version.
        let rc4 = release(tag: "v2.0-rc4", name: "Auraliscope 2.0 rc 4 (Build 121)", asset: "Auraliscope 2.0 rc 4 build 121.pkg",
                          prerelease: true)
        try check(try offered(rc4, prereleases: true), "rc 4 not offered to rc 3 on the pre-release channel")
        try check(!(try offered(release(tag: "v2.0-rc3", name: "Auraliscope 2.0 rc 3 (Build 120)",
                                         asset: "Auraliscope 2.0 rc 3 build 120.pkg", prerelease: true), prereleases: true)),
                  "the running rc offered to itself")
        try check(try offered(final, prereleases: true), "final 2.0 not offered on the pre-release channel")
        print("PASS: pre-release labels; rc 3 → final 2.0 with and without a build, same or newer build, never an older build or itself; stable and pre-release channels")

        // Which launches check.
        let id = "com.jinboz.SoundMeterJBZ"
        try check(UpdateLaunchPolicy.allows(arguments: ["/A"], bundleID: id, environment: [:]), "a normal launch does not check")
        try check(UpdateLaunchPolicy.allows(arguments: ["/A", "-NSDocumentRevisionsDebugMode", "YES"], bundleID: id, environment: [:]),
                  "a defaults argument stopped the check")
        try check(UpdateLaunchPolicy.allows(arguments: ["/A", "--bridge-launch"], bundleID: id, environment: [:]),
                  "a launch by the plugin does not check")
        for flags in [["--demo"], ["--test-model-lifecycle"], ["--snapshot"], ["--analyze-file", "x.wav"], ["--capture-selftest", "141"],
                      ["--render-preview"], ["--diagnostic"], ["--check-shaders"]] {
            try check(!UpdateLaunchPolicy.allows(arguments: ["/A"] + flags, bundleID: id, environment: [:]), "\(flags[0]) launch checks")
        }
        try check(!UpdateLaunchPolicy.allows(arguments: ["/A"], bundleID: id + ".QA", environment: [:]), "a QA bundle checks")
        try check(!UpdateLaunchPolicy.allows(arguments: ["/A"], bundleID: id, environment: ["AURALISCOPE_NO_UPDATE_CHECK": "1"]),
                  "AURALISCOPE_NO_UPDATE_CHECK ignored")
        print("PASS: launch policy: normal and plugin launches check; QA bundles, self-tests, snapshots, previews, file analysis, capture checks, demo and the opt-out variable do not")

        // The checker, with an injected fetch.
        final class Fetches: @unchecked Sendable {
            var count = 0
            var outcome: Result<Data, Error> = .success(Data())
            var gate: CheckedContinuation<Void, Never>?
            var holding = false
        }
        let fetches = Fetches()
        let identity = GitHubUpdateChecker.Identity(version: "2.0", build: 120, label: "2.0 rc 3")
        func make(prereleases: Bool = false) -> GitHubUpdateChecker {
            GitHubUpdateChecker(fetch: { identity, include in
                fetches.count += 1
                if fetches.holding { await withCheckedContinuation { fetches.gate = $0 } }
                let data = try fetches.outcome.get()
                return try GitHubUpdateCatalog.evaluate(data, currentVersion: identity.version, currentBuild: identity.build,
                                                        includePrereleases: include,
                                                        currentIsPrerelease: GitHubUpdateCatalog.isPrereleaseLabel(identity.label))
            }, identity: { identity }, includePrereleases: { prereleases }, log: { _ in })
        }
        func settle() async { for _ in 0..<50 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }

        // Once per launch, however often it is asked for (windows appearing, activation), and never "recently checked".
        fetches.outcome = .success(final)
        var checker = make()
        checker.checkAtLaunch(allowed: true, delay: 0)
        checker.checkAtLaunch(allowed: true, delay: 0)
        await settle()
        checker.checkAtLaunch(allowed: true, delay: 0)
        await settle()
        try check(fetches.count == 1, "the launch check ran \(fetches.count) times")
        try check(checker.notice?.title == "Auraliscope 2.0", "the launch check did not offer the final release")
        checker.dismissNotice()
        try check(checker.notice == nil, "Later did not hide the offer")
        // A new launch (a new checker) checks again, whatever the previous one found.
        checker = make()
        checker.checkAtLaunch(allowed: true, delay: 0)
        await settle()
        try check(fetches.count == 2 && checker.notice != nil, "a new launch did not check again")
        // Not allowed: no request.
        checker = make()
        checker.checkAtLaunch(allowed: false, delay: 0)
        await settle()
        try check(fetches.count == 2 && checker.state == .idle, "a disallowed launch made a request")

        // Up to date: quiet.
        fetches.outcome = .success(release(tag: "v2.0", name: "Auraliscope 2.0 (Build 118)", asset: "Auraliscope 2.0 build 118.pkg"))
        checker = make()
        checker.checkAtLaunch(allowed: true, delay: 0)
        await settle()
        try check(checker.notice == nil, "an up-to-date launch check offered something")

        // Failures at launch are silent (idle, no notice); the same failure on a manual check is reported.
        for (error, expected) in [(GitHubUpdateError.rateLimited, GitHubUpdateChecker.Failure.rateLimited),
                                  (GitHubUpdateError.invalidResponse, .invalidResponse), (GitHubUpdateError.unavailable, .unavailable),
                                  (URLError(.timedOut) as Error, .connection), (URLError(.notConnectedToInternet) as Error, .connection)] as [(Error, GitHubUpdateChecker.Failure)] {
            fetches.outcome = .failure(error)
            checker = make()
            checker.checkAtLaunch(allowed: true, delay: 0)
            await settle()
            try check(checker.state == .idle && checker.notice == nil, "a failed launch check was not silent (\(error))")
            checker.check(.manual)
            await settle()
            try check(checker.state == .failed(expected), "a failed manual check was not reported (\(error))")
        }
        fetches.outcome = .success(Data("{not json".utf8))
        checker = make()
        checker.checkAtLaunch(allowed: true, delay: 0)
        await settle()
        try check(checker.state == .idle && checker.notice == nil, "a malformed response at launch was not silent")

        // A manual request during the launch check joins it: one request, answered as a manual check.
        fetches.outcome = .failure(GitHubUpdateError.rateLimited)
        fetches.holding = true
        let before = fetches.count
        checker = make()
        checker.checkAtLaunch(allowed: true, delay: 0)
        await settle()
        checker.check(.manual)
        checker.check(.manual)
        fetches.holding = false
        fetches.gate?.resume()
        await settle()
        try check(fetches.count == before + 1, "joined requests made \(fetches.count - before) requests")
        try check(checker.state == .failed(.rateLimited), "a joined manual request was not told of the failure")
        // A manual check before the launch's delay has passed counts as the launch's check.
        fetches.outcome = .success(final)
        checker = make()
        checker.check(.manual)
        await settle()
        let afterManual = fetches.count
        checker.checkAtLaunch(allowed: true, delay: 0)
        await settle()
        try check(fetches.count == afterManual && checker.notice == nil, "the launch check repeated a manual check")
        // The pre-release preference reaches the fetch.
        let asked = Fetches()
        let channel = GitHubUpdateChecker(fetch: { _, include in asked.count = include ? 1 : -1; return .noNewerRelease(GitHubReleaseUpdate(
            title: "x", tag: "v2.0", version: [2, 0, 0], build: 120, releaseURL: URL(string: "https://github.com")!, installerURL: nil)) },
            identity: { identity }, includePrereleases: { true }, log: { _ in })
        channel.check(.manual)
        await settle()
        try check(asked.count == 1, "Include pre-releases did not reach the check")
        print("PASS: update checker: once per launch, again on a new launch, quiet when up to date or failing (rate limit, malformed, unavailable, timeout, offline), manual failures reported, joined requests deduplicated, pre-release preference kept")
    }
}
