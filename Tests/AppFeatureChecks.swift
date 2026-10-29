import Foundation

final class UpdateMockProtocol: URLProtocol {
    static var status = 200
    static var payload = Data()
    static var failure: Error?
    static var requestSeen: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestSeen = request
        if let error = Self.failure { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct AppFeatureChecks {
    /// Windows restored or stranded off screen come back; reachable ones stay put.
    static func windowFrames() throws {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944), external = CGRect(x: 1512, y: -200, width: 2560, height: 1415)
        let main = laptop
        func on(_ f: CGRect, _ screens: [CGRect]) -> CGRect { WindowFrames.onScreen(f, visible: screens, main: main) }
        let inside = CGRect(x: 100, y: 100, width: 1280, height: 720)
        try check(on(inside, [laptop]) == inside, "a window on screen moved")
        let partly = CGRect(x: 1300, y: 100, width: 1280, height: 720)
        try check(on(partly, [laptop]) == partly, "a window with a reachable title bar moved")
        let onExternal = CGRect(x: 2000, y: 200, width: 1400, height: 1000)
        try check(on(onExternal, [laptop, external]) == onExternal, "a window on the external display moved")
        let stranded = on(onExternal, [laptop])
        try check(laptop.contains(stranded) && stranded.width == 1400 && stranded.height == 944, "a window from a removed display not brought back (\(stranded))")
        let above = on(CGRect(x: 100, y: 950, width: 1280, height: 720), [laptop])
        try check(laptop.contains(above), "a title bar above the screen left unreachable (\(above))")
        let huge = on(CGRect(x: 0, y: 0, width: 3000, height: 2000), [laptop])
        try check(laptop.contains(huge) && huge.size == laptop.size, "an oversized frame not fitted (\(huge))")
        try check(on(.zero, [laptop]) == .zero && on(inside, []) == inside, "degenerate input changed")
        print("PASS: window frames: on-screen and reachable frames kept, frames from a removed display or above the screen brought back, oversized frames fitted")
    }

    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
    }
    static func release(tag: String = "v2.0", name: String = "Auraliscope 2.0 (Build 116)",
                        asset: String = "Auraliscope 2.0 build 116.pkg", page: String? = nil,
                        download: String? = nil, prerelease: Bool = false, draft: Bool = false) -> Data {
        let object: [String: Any] = ["tag_name":tag, "name":name,
            "html_url":page ?? "https://github.com/jinboz12/Auraliscope/releases/tag/\(tag)",
            "draft":draft, "prerelease":prerelease,
            "assets":[["name":asset,"state":"uploaded","browser_download_url":download
                ?? "https://github.com/jinboz12/Auraliscope/releases/download/\(tag)/installer.pkg"]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }
    static func available(_ data: Data, version: String = "2.0", build: Int = 115) throws -> Bool {
        if case .available = try GitHubUpdateCatalog.evaluate(data, currentVersion: version, currentBuild: build) { return true }
        return false
    }
    static func main() async throws {
        setbuf(stdout, nil)
        try check(available(release()), "newer same-version build not offered")
        try check(!available(release(name:"Auraliscope 2.0 Build 91",asset:"Auraliscope 2.0 build 91.pkg")), "older published Build 91 offered over local Build 115")
        try check(!available(release(name:"Auraliscope 2.0 Build 115",asset:"Auraliscope 2.0 build 115.pkg")), "equal build offered")
        try check(available(release(tag:"v2.1",name:"Auraliscope 2.1",asset:"Auraliscope 2.1.pkg")), "newer major/minor version not offered")
        try check(available(release(tag:"v2.0.1",name:"Auraliscope 2.0.1",asset:"Auraliscope 2.0.1.pkg")), "patch version not offered")
        try check(!available(release(tag:"v1.9",name:"Auraliscope 1.9 Build 999",asset:"Auraliscope 1.9 build 999.pkg")), "old version with large build offered")
        try check(available(release(name:"Auraliscope 2.0")), "installer build fallback failed")
        try check(!available(release(name:"Auraliscope 2.0",asset:"Auraliscope 2.0.pkg")), "equal version with unknown build offered")
        for bad in [release(prerelease:true),release(draft:true),release(page:"https://example.com/releases/tag/v2.0"),
                    release(page:"http://github.com/jinboz12/Auraliscope/releases/tag/v2.0"),
                    release(page:"https://github.com/jinboz12/Auraliscope-evil/releases/tag/v2.0"),
                    release(tag:"v2.0-build.117"),Data("not json".utf8),Data(repeating:32,count:2_000_001)] {
            do { _ = try GitHubUpdateCatalog.evaluate(bad,currentVersion:"2.0",currentBuild:115); throw Failure(message:"unverified release accepted") }
            catch is GitHubUpdateError {}
        }
        for url in ["javascript:alert(1)","https://evil.example/installer.pkg","https://github.com/jinboz12/other/releases/download/v2/installer.pkg",
                    "https://github.com@evil.example/jinboz12/Auraliscope/releases/download/v2/installer.pkg"] {
            if case .available(let value) = try GitHubUpdateCatalog.evaluate(release(download:url),currentVersion:"2.0",currentBuild:115) {
                try check(value.installerURL == nil,"untrusted installer link accepted")
            } else { throw Failure(message:"valid release without safe installer should still have release-page link") }
        }
        for tag in ["v2.0", "2", "2.1.3", "2.0-rc.1+build.115"] {
            try check(GitHubUpdateCatalog.version(tag) != nil,"version not parsed: \(tag)")
        }
        for tag in ["banana","2.0.1.4","2.0/evil",String(repeating:"9",count:150)] {
            try check(GitHubUpdateCatalog.version(tag) == nil,"invalid version accepted")
        }
        print("PASS: release version/build ordering, older local-vs-GitHub builds, metadata, stable channel and repository-scoped HTTPS links")

        func list(_ items: [Data]) -> Data {
            let objects = items.map { try! JSONSerialization.jsonObject(with: $0) }
            return try! JSONSerialization.data(withJSONObject: objects)
        }
        func channel(_ data: Data, build: Int = 115) throws -> GitHubUpdateResult {
            try GitHubUpdateCatalog.evaluate(data, currentVersion: "2.0", currentBuild: build, includePrereleases: true)
        }
        let rc = release(tag:"v2.0-rc.2", name:"Auraliscope 2.0 rc 2 build 118", asset:"Auraliscope 2.0 rc 2 build 118.pkg", prerelease:true)
        let stable = release(tag:"v2.0", name:"Auraliscope 2.0 build 116", asset:"Auraliscope 2.0 build 116.pkg")
        if case .available(let u) = try channel(list([stable, rc])) { try check(u.build == 118 && u.prerelease, "newest pre-release not chosen") }
        else { throw Failure(message:"pre-release channel missed a newer pre-release") }
        if case .available(let u) = try channel(list([rc, release(tag:"v2.1",name:"Auraliscope 2.1",asset:"Auraliscope 2.1.pkg")])) {
            try check(!u.prerelease, "newer final release lost to an older pre-release")
        } else { throw Failure(message:"pre-release channel missed a newer final release") }
        if case .available = try channel(list([rc]), build: 118) { throw Failure(message:"equal pre-release build offered") }
        if case .available(let u) = try channel(list([release(draft:true), release(page:"https://example.com/x"), rc])) {
            try check(u.build == 118, "unverifiable list entries not skipped")
        } else { throw Failure(message:"valid entry lost beside invalid ones") }
        do { _ = try channel(list([release(draft:true)])); throw Failure(message:"draft-only list accepted") } catch is GitHubUpdateError {}
        do { _ = try available(rc); throw Failure(message:"stable channel accepted a pre-release") } catch is GitHubUpdateError {}
        try check(GitHubUpdateCatalog.endpoint(includePrereleases: true) == GitHubUpdateCatalog.listEndpoint
                  && GitHubUpdateCatalog.endpoint(includePrereleases: false) == GitHubUpdateCatalog.endpoint, "channel endpoints")
        // GitHub replaces spaces in uploaded asset names with dots.
        for (name, expected) in [("Auraliscope.2.0.rc.2.build.118.pkg", true), ("Auraliscope 2.0 rc 2 build 118.pkg", true),
                                 ("Auraliscope-2.0-build-118.pkg", true), ("Auraliscope_2.0_build_118.PKG", true),
                                 ("Auraliscope.Bridge.2.0.118.pkg", false), ("Auraliscope Bridge 2.0.pkg", false),
                                 ("AuraliscopeX.2.0.pkg", false), ("Auraliscope.pkg.zip", false), ("Other.2.0.pkg", false),
                                 ("Auraliscope-2.0-rc2-build118-source.tar.gz", false)] {
            try check(GitHubUpdateCatalog.isAppInstaller(name) == expected, "installer name \(name)")
        }
        let dotted = release(tag:"v2.0-rc.2", name:"Auraliscope 2.0 RC 2 (build 118)", asset:"Auraliscope.2.0.rc.2.build.118.pkg",
                             download:"https://github.com/jinboz12/Auraliscope/releases/download/v2.0-rc.2/Auraliscope.2.0.rc.2.build.118.pkg",
                             prerelease:true)
        if case .available(let u) = try channel(list([dotted]), build: 117) {
            try check(u.build == 118 && u.installerURL?.lastPathComponent == "Auraliscope.2.0.rc.2.build.118.pkg", "dotted installer not linked")
        } else { throw Failure(message:"dotted pre-release not offered") }
        if case .available(let u) = try GitHubUpdateCatalog.evaluate(release(asset:"Auraliscope.2.0.build.116.pkg"),
                                                                      currentVersion:"2.0", currentBuild:115) {
            try check(u.installerURL != nil, "stable dotted installer not linked")
        } else { throw Failure(message:"stable dotted release not offered") }
        print("PASS: opt-in pre-release channel: newest of either kind, final beats older pre-release, invalid entries skipped, stable unchanged, GitHub dotted installer names linked")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateMockProtocol.self]
        let session = URLSession(configuration:config)
        defer { session.invalidateAndCancel() }
        let client = GitHubUpdateClient(session:session)
        UpdateMockProtocol.payload = release()
        let success = try await client.check(version:"2.0",build:115)
        if case .available = success {} else { throw Failure(message:"HTTP 200 did not deliver update") }
        let request = UpdateMockProtocol.requestSeen!
        try check(request.url == GitHubUpdateCatalog.endpoint && request.value(forHTTPHeaderField:"Authorization") == nil,
                  "wrong endpoint or unexpected credentials")
        try check(request.timeoutInterval == 15 && request.httpShouldHandleCookies == false,"request timeout/cookies")
        for (status,expected) in [(404,GitHubUpdateError.unavailable),(403,.rateLimited),(429,.rateLimited),(500,.server(500))] {
            UpdateMockProtocol.status = status
            do { _ = try await client.check(version:"2.0",build:115); throw Failure(message:"HTTP \(status) reported success") }
            catch let error as GitHubUpdateError { try check(error == expected,"wrong HTTP error classification") }
        }
        UpdateMockProtocol.failure = URLError(.notConnectedToInternet)
        do { _ = try await client.check(version:"2.0",build:115); throw Failure(message:"offline reported up to date") }
        catch let error as URLError { try check(error.code == .notConnectedToInternet,"offline failure changed") }
        print("PASS: actual URLSession client through mock transport: 200, 404, 403, 429, 500, offline, anonymous headers and timeout")

        func draw(_ context: PanelContext = .grid, hidden: Bool = false, detached: Bool = false,
                  strip: Bool = false, inStrip: Bool = false, stripPresent: Bool = false,
                  zoomMatches: Bool = false, zoomExpanded: Bool = false) -> Bool {
            PanelRenderPolicy.permits(context:context,hidden:hidden,detached:detached,mainIsStrip:strip,
                inStrip:inStrip,stripPresent:stripPresent,zoomMatches:zoomMatches,zoomExpanded:zoomExpanded)
        }
        try check(draw(),"normal grid stopped")
        try check(!draw(hidden:true),"outgoing hidden grid view draws")
        try check(!draw(detached:true),"grid duplicates detached scene")
        try check(!draw(strip:true),"old main grid draws in dock")
        try check(!draw(zoomExpanded:true),"covered grid draws behind zoom")
        try check(draw(.enlarged,zoomMatches:true),"zoom target stopped")
        try check(!draw(.enlarged,zoomMatches:false),"old zoom target draws")
        try check(draw(.window,hidden:true,detached:true,strip:true),"visible detached window stopped with hidden/minimized main")
        try check(!draw(.window,detached:false),"closed detached window draws")
        try check(draw(.strip,hidden:true,inStrip:true,stripPresent:true),"visible dock panel stopped due to main hidden set")
        try check(!draw(.strip,inStrip:false,stripPresent:true),"removed dock panel still draws")
        try check(!draw(.strip,detached:true,inStrip:true,stripPresent:true),"dock duplicates detached panel")
        try check(PanelRenderPolicy.physicallyVisible(windowVisible:true,hiddenAncestor:false,hasArea:true,transparentAncestor:false,held:false),"visible view stopped")
        for i in 0..<5 {
            try check(!PanelRenderPolicy.physicallyVisible(windowVisible:i != 0,hiddenAncestor:i == 1,hasArea:i != 2,
                        transparentAncestor:i == 3,held:i == 4),"hidden/clipped/transparent/held view draws")
        }
        print("PASS: render policy covers hidden, detached, enlarged, dock, removed views, hidden ancestors, clipping, transparency and held transitions")
        let oldOrder = ["vu","spectrum","waveform","loudness"]
        let newOrder = ["vu","multiFFT","waveform","loudness"]
        try check(DockSpectrumPolicy.displayed(oldOrder,useMultiFFT:true) == newOrder,"Multi-FFT did not replace original slot in place")
        try check(DockSpectrumPolicy.displayed(oldOrder,useMultiFFT:false) == oldOrder,"disabled/unsupported Multi-FFT failed to fall back")
        try check(DockSpectrumPolicy.canonical(["multiFFT","vu","spectrum","spectrum","waveform"]) == ["vu","spectrum","waveform"],"duplicate spectrum family did not retain legacy position")
        try check(DockSpectrumPolicy.canonical(["waveform","multiFFT","vu"]) == ["waveform","spectrum","vu"],"old Multi-FFT-only layout lost its slot")
        try check(DockSpectrumPolicy.displayed(["waveform","vu"],useMultiFFT:true) == ["waveform","vu"],"enabling Beta inserted a removed dock slot")
        let inherited = DockSpectrumPolicy.displayedShares(["spectrum":0.6,"waveform":0.4],useMultiFFT:true)
        try check(inherited == ["multiFFT":0.6,"waveform":0.4],"Dock width not inherited")
        let resized = DockSpectrumPolicy.canonicalShares(["multiFFT":0.7,"waveform":0.3])
        try check(resized == ["spectrum":0.7,"waveform":0.3],"resizing new spectrum did not save original slot")
        try check(DockSpectrumPolicy.canonicalShares(["spectrum":0.6,"multiFFT":0.8])["spectrum"] == 0.6,"old width precedence changed")
        try check(DockSpectrumPolicy.savedSlot("multiFFT") == "spectrum","Dock commands do not address shared slot")
        try check(!draw(.strip,inStrip:DockSpectrumPolicy.displayed(oldOrder,useMultiFFT:true).contains("spectrum"),stripPresent:true),"replaced legacy spectrum can still draw")
        for height in [0.0,1,80,240,480,1000] {
            for share in [-1.0,0,0.2,0.5,0.9,1,2,Double.nan] {
                let split = MultiFFTStackLayout(height:height,share:share,gap:8)
                try check(split.top.isFinite && split.bottom.isFinite && split.top >= 0 && split.bottom >= 0,"invalid resize sizes")
                try check(abs(split.top+split.bottom-max(0,height-8)) < 1e-8,"resize fails to conserve panel space")
                try check((0...1).contains(split.dragging(to:-1000)) && (0...1).contains(split.dragging(to:10000)),"resize escapes allowed fraction")
            }
        }
        let split = MultiFFTStackLayout(height:608,share:0.5,gap:8)
        try check(split.top == 300 && split.bottom == 300,"initial split not balanced")
        try check(split.dragging(to:360) == 0.6,"divider resize does not change share")
        try check(split.dragging(to:-1000) == 1.0/6 && abs(split.dragging(to:10000)-460.0/600) < 1e-8,"divider minima not enforced")
        // With both legacy panels under it, the Multi-FFT leaves them their minima (180 + 10 + 120) at 1280×720.
        let short = MultiFFTStackLayout(height:520,share:0.5,gap:10,minimumBottom:310)
        try check(short.bottom >= 310 - 1e-9 && short.top >= 100 - 1e-9 && abs(short.top+short.bottom-510) < 1e-9,"Multi-FFT squeezes the panels below (\(short.top)/\(short.bottom))")
        let tiny = MultiFFTStackLayout(height:300,share:0.9,gap:10,minimumBottom:310)
        try check(tiny.top >= 0 && tiny.bottom >= 0 && abs(tiny.top+tiny.bottom-290) < 1e-9 && tiny.bottom > tiny.top,"undersized stack not shared proportionally")
        print("PASS: Dock spectrum substitution, order/deduplication, inherited/resized widths, fallback, absent slots, drawing gate and 48 split/minimum/invalid-size scenarios")

        try await UpdateLaunchChecks.run()
        try windowFrames()

        if CommandLine.arguments.contains("--live") {
            do { print("LIVE GITHUB:",try await GitHubUpdateClient().check(version:"2.0",build:115)) }
            catch { print("LIVE GITHUB: query failed (not an up-to-date verdict):",error) }
        }
    }
}
