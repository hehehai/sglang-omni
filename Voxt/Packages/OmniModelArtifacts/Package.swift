// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OmniModelArtifacts",
    platforms: [.macOS(.v10_15)],
    products: [.library(name: "OmniModelArtifacts", targets: ["OmniModelArtifacts"])],
    targets: [
        .target(name: "OmniModelArtifacts"),
        .testTarget(name: "OmniModelArtifactsTests", dependencies: ["OmniModelArtifacts"]),
    ]
)
