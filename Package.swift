// swift-tools-version: 6.0
import PackageDescription
import Foundation

let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Resources/Info.plist").path

let package = Package(
    name: "Auraliscope",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AudioRing", publicHeadersPath: "include", linkerSettings: [.linkedFramework("AudioToolbox")]),
        .executableTarget(name: "Auraliscope", dependencies: ["AudioRing"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                                        "-Xlinker", "__info_plist", "-Xlinker", infoPlist])])
    ],
    swiftLanguageModes: [.v5]
)
