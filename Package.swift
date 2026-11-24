// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SidecarAuto",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SidecarCore"),
        .executableTarget(name: "SidecarAuto", dependencies: ["SidecarCore"]),
        .testTarget(name: "SidecarCoreTests", dependencies: ["SidecarCore"]),
    ],
    swiftLanguageModes: [.v5]
)
