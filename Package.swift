// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SendSyncChat",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "SendSyncChat", targets: ["SendSyncChat"]),
    ],
    targets: [
        .target(name: "SendSyncChat"),
        .testTarget(name: "SendSyncChatTests", dependencies: ["SendSyncChat"]),
    ]
)
