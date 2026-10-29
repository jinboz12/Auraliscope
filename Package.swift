// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The executable and packaged app share the public release identity.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Resources/Info.plist").path

let package = Package(
    name: "Auraliscope",
    // iOS: only the portable libraries below build for it (the iPad app, iPad/, links AuraliscopeDisplayCore); the
    // macOS application target never builds for iOS.
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "AuraliscopeDisplayCore", targets: ["AuraliscopeDisplayCore"]),
    ],
    targets: [
        // The shared analysis core: every measurement Auraliscope makes, with no UI, Core Audio or AppKit. The app
        // runs it on its DSP queue for devices and system audio; the Bridge plugins compile the same sources into
        // their own analysis thread (Bridge/scripts/build-plugins.sh).
        .target(name: "AnalysisKernels", publicHeadersPath: "include"),
        .target(name: "AnalysisCore", dependencies: ["AnalysisKernels"]),
        .target(name: "AudioRing", dependencies: ["AnalysisKernels"], publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("AudioToolbox")]),
        // What a display needs on any platform, with no UI, Core Audio capture or sockets: the local analysis session
        // (StreamAnalyzer, the plugins' own analysis), Bridge framing and the display end of protocol 3, RESULT
        // decoding into display state, and the network pairing. The iPad app (iPad/) is built on it.
        .target(name: "AuraliscopeDisplayCore", dependencies: ["AnalysisCore"]),
        // Checks of the display core (swift run DisplayCoreChecks): protocol constants against BridgeProtocol.h, framing,
        // the display session's rules, untrusted input, pairing, and the local analysis against reference signals.
        .executableTarget(name: "DisplayCoreChecks", dependencies: ["AuraliscopeDisplayCore", "AnalysisCore", "BridgeTransport"],
                          path: "Tests/DisplayCoreChecks"),
        // A network display on the Mac for automated tests of the Bridge's network carrier (Bridge/scripts/test-network.sh).
        .executableTarget(name: "BridgeNetworkProbe", dependencies: ["AuraliscopeDisplayCore"], path: "Tests/BridgeNetworkProbe"),
        // Receiving end of the DAW Bridge transport (the plugins build the same protocol header themselves).
        .target(name: "BridgeTransport", publicHeadersPath: "include"),
        .executableTarget(name: "Auraliscope", dependencies: ["AnalysisCore", "AudioRing", "BridgeTransport"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                                        "-Xlinker", "__info_plist", "-Xlinker", infoPlist])])
    ],
    swiftLanguageModes: [.v5]
)
