// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AutoSidecar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SidecarCore"),
        .executableTarget(name: "AutoSidecar", dependencies: ["SidecarCore"]),
        .testTarget(name: "SidecarCoreTests", dependencies: ["SidecarCore"]),
    ],
    swiftLanguageModes: [.v5]
)
