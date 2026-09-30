// swift-tools-version: 6.0
import PackageDescription
import Foundation

// DAW Bridge prototype branch: the binary carries the "Auraliscope Labs" test identity (1.3dev,
// com.jinboz.SoundMeterJBZ.Labs), so it never shares preferences, logs or TCC grants with Auraliscope.
// Resources/Info.plist (the release identity) is left as it is.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Bridge/App/Info.plist").path

let package = Package(
    name: "Auraliscope",
    platforms: [.macOS(.v13)],
    targets: [
        // The shared analysis core: every measurement Auraliscope makes, with no UI, Core Audio or AppKit. The app
        // runs it on its DSP queue for devices and system audio; the Bridge plugins compile the same sources into
        // their own analysis thread (Bridge/scripts/build-plugins.sh).
        .target(name: "AnalysisKernels", publicHeadersPath: "include"),
        .target(name: "AnalysisCore", dependencies: ["AnalysisKernels"]),
        .target(name: "AudioRing", dependencies: ["AnalysisKernels"], publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("AudioToolbox")]),
        // Receiving end of the DAW Bridge transport (the plugins build the same protocol header themselves).
        .target(name: "BridgeTransport", publicHeadersPath: "include"),
        .executableTarget(name: "Auraliscope", dependencies: ["AnalysisCore", "AudioRing", "BridgeTransport"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                                        "-Xlinker", "__info_plist", "-Xlinker", infoPlist])])
    ],
    swiftLanguageModes: [.v5]
)
