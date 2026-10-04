// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SendSyncChat",
    // macOS is here only so the package builds under `swift test` on a Mac.
    // Without it SwiftPM targets macOS 10.13, where `@Published` and the rest
    // of Combine's property wrappers are unavailable, and every setter in
    // ChatSession fails to compile. Nothing ships for macOS.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "SendSyncChat", targets: ["SendSyncChat"]),
    ],
    targets: [
        .target(name: "SendSyncChat"),
        .testTarget(name: "SendSyncChatTests", dependencies: ["SendSyncChat"]),
    ]
)
