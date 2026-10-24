import Foundation

/// Public release metadata only. No account, credential, installer execution or dependency on UI/DSP state.
struct GitHubReleaseUpdate: Equatable, Sendable {
    let title: String
    let tag: String
    let version: [Int]
    let build: Int?
    let releaseURL: URL
    let installerURL: URL?
    var prerelease = false
}

enum GitHubUpdateResult: Equatable, Sendable {
    case available(GitHubReleaseUpdate)
    case noNewerRelease(GitHubReleaseUpdate)
}

enum GitHubUpdateError: Error, Equatable {
    case unavailable, rateLimited, invalidResponse, server(Int)
}

enum GitHubUpdateCatalog {
    static let repository = "jinboz12/Auraliscope"
    static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// The newest releases, pre-releases included, for the opt-in pre-release channel.
    static let listEndpoint = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
    static let prereleaseKey = "updates.includePrereleases"
    static func endpoint(includePrereleases: Bool) -> URL { includePrereleases ? listEndpoint : endpoint }

    private struct Release: Decodable {
        let tag_name: String
        let name: String?
        let html_url: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let state: String?
    }

    static func version(_ text: String) -> [Int]? {
        guard text.count <= 128 else { return nil }
        let pattern = #"^[vV]?([0-9]+(?:\.[0-9]+){0,2})(.*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let suffixRange = Range(match.range(at: 2), in: text) else { return nil }
        let suffix = text[suffixRange].lowercased()
        guard suffix.isEmpty || ["-", "+", "rc", "beta", "alpha"].contains(where: { suffix.hasPrefix($0) }) else { return nil }
        let fields = text[numberRange].split(separator: ".")
        let values = fields.compactMap { Int($0) }
        guard fields.count == values.count, values.allSatisfy({ (0...999999).contains($0) }) else { return nil }
        return values + Array(repeating: 0, count: 3-values.count)
    }

    private static func build(_ text: String) -> Int? {
        let pattern = #"(?i)(?:^|[^a-z0-9])build[\s._+\-]*([0-9]+)(?:$|[^0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let value = Int(text[range]), value > 0 else { return nil }
        return value
    }

    /// The app's installer package. GitHub stores an uploaded "Auraliscope 2.0 build 118.pkg" as
    /// "Auraliscope.2.0.build.118.pkg", so a space, dot, dash or underscore may follow the name. Plugin-only packages
    /// ("Auraliscope Bridge …") are not the app installer.
    static func isAppInstaller(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".pkg"), lower.hasPrefix("auraliscope"),
              let separator = lower.dropFirst("auraliscope".count).first, " ._-".contains(separator) else { return false }
        return !lower.dropFirst("auraliscope".count + 1).hasPrefix("bridge")
    }

    /// Repository-scoped HTTPS links only, even when remote metadata contains malformed or unexpected URLs.
    static func officialURL(_ text: String, download: Bool) -> URL? {
        guard let url = URL(string: text), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", c.host?.lowercased() == "github.com",
              c.user == nil, c.password == nil, c.port == nil || c.port == 443 else { return nil }
        let prefix = "/\(repository)/releases/" + (download ? "download/" : "tag/")
        guard c.path.lowercased().hasPrefix(prefix.lowercased()), c.path.count > prefix.count else { return nil }
        return url
    }

    /// The stable channel reads `/releases/latest` (one release, never a pre-release). The pre-release channel reads
    /// the release list and offers the newest verifiable release of either kind; a list entry that fails verification
    /// is skipped rather than failing the whole check.
    static func evaluate(_ data: Data, currentVersion: String, currentBuild: Int,
                         includePrereleases: Bool = false) throws -> GitHubUpdateResult {
        guard data.count <= 2_000_000, let current = version(currentVersion) else { throw GitHubUpdateError.invalidResponse }
        let update: GitHubReleaseUpdate
        if includePrereleases {
            guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { throw GitHubUpdateError.invalidResponse }
            // Higher version, then higher build; on a tie the final release outranks its pre-release.
            func rank(_ u: GitHubReleaseUpdate) -> [Int] { u.version + [u.build ?? -1, u.prerelease ? 0 : 1] }
            guard let newest = releases.compactMap({ try? verified($0, allowPrerelease: true) })
                .max(by: { rank($0).lexicographicallyPrecedes(rank($1)) }) else { throw GitHubUpdateError.invalidResponse }
            update = newest
        } else {
            guard let release = try? JSONDecoder().decode(Release.self, from: data) else { throw GitHubUpdateError.invalidResponse }
            update = try verified(release, allowPrerelease: false)
        }
        let newerVersion = current.lexicographicallyPrecedes(update.version)
        let newerBuild = update.version == current && update.build.map { $0 > currentBuild } == true
        return newerVersion || newerBuild ? .available(update) : .noNewerRelease(update)
    }

    private static func verified(_ release: Release, allowPrerelease: Bool) throws -> GitHubReleaseUpdate {
        guard !release.draft, allowPrerelease || !release.prerelease, let published = version(release.tag_name),
              let page = officialURL(release.html_url, download: false) else { throw GitHubUpdateError.invalidResponse }
        let packages = release.assets.filter {
            isAppInstaller($0.name) && ($0.state == nil || $0.state == "uploaded")
        }
        let explicitBuilds = Set([build(release.tag_name), release.name.flatMap(build)].compactMap { $0 })
        guard explicitBuilds.count < 2 else { throw GitHubUpdateError.invalidResponse }
        let publishedBuild = explicitBuilds.first ?? packages.compactMap { build($0.name) }.max()
        let installer = packages.first { publishedBuild == nil || build($0.name) == publishedBuild }
            .flatMap { officialURL($0.browser_download_url, download: true) }
        let title = String((release.name?.isEmpty == false ? release.name! : release.tag_name)
            .replacingOccurrences(of: "\n", with: " ").prefix(200))
        return GitHubReleaseUpdate(title: title, tag: release.tag_name, version: published, build: publishedBuild,
                                   releaseURL: page, installerURL: installer, prerelease: release.prerelease)
    }
}

struct GitHubUpdateClient {
    let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: config)
        }
    }
    func check(version: String, build: Int, includePrereleases: Bool = false) async throws -> GitHubUpdateResult {
        var request = URLRequest(url: GitHubUpdateCatalog.endpoint(includePrereleases: includePrereleases), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Auraliscope/\(version) (build \(build))", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GitHubUpdateError.invalidResponse }
        switch response.statusCode {
        case 200: return try GitHubUpdateCatalog.evaluate(data, currentVersion: version, currentBuild: build,
                                                          includePrereleases: includePrereleases)
        case 404: throw GitHubUpdateError.unavailable
        case 403, 429: throw GitHubUpdateError.rateLimited
        default: throw GitHubUpdateError.server(response.statusCode)
        }
    }
}
