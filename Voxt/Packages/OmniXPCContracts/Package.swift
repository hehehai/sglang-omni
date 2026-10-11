// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OmniXPCContracts",
    products: [.library(name: "OmniXPCContracts", targets: ["OmniXPCContracts"])],
    targets: [
        .target(name: "OmniXPCContracts"),
        .testTarget(name: "OmniXPCContractsTests", dependencies: ["OmniXPCContracts"]),
    ]
)
