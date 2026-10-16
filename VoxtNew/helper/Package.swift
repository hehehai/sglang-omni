// swift-tools-version:6.0
import Foundation
import PackageDescription

// auralink-helper: the small Swift process Auralink.app runs beside its Go
// UI, for what Go (MyGo, purego, no cgo) cannot do well: microphone capture
// (AVAudioEngine), the global hotkey event tap (CGEventTap, which must decide
// synchronously whether to swallow a key), text in and out of the app in
// front (Accessibility, the clipboard, posted keys) and browser URLs
// (Accessibility). JSON lines over stdin/stdout: helper
// protocol 1 (docs/helper-protocol.md).
//
// No third-party dependencies; `swift build -c release` takes seconds
// (scripts/build-helper.sh). AuralinkHelperKit holds the pure logic (the
// wire types, the hotkey recognizer, PCM framing, the app list), so
// `swift test` covers it without permissions, against helper/Fixtures.

/// The helper's own Info.plist, linked into the binary: it names the
/// helper (and its version) when it runs outside Auralink.app.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "AuralinkHelper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "auralink-helper", targets: ["AuralinkHelper"]),
    ],
    targets: [
        .target(
            name: "AuralinkHelperKit",
            path: "Sources/AuralinkHelperKit"
        ),
        .executableTarget(
            name: "AuralinkHelper",
            dependencies: ["AuralinkHelperKit"],
            path: "Sources/AuralinkHelper",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]
        ),
        .testTarget(
            name: "AuralinkHelperKitTests",
            dependencies: ["AuralinkHelperKit"],
            path: "Tests/AuralinkHelperKitTests"
        ),
    ]
)
