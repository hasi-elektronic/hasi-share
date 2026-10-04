// swift-tools-version:6.0
import PackageDescription

// IPTVKit: Apple-only layer on top of IPTVCore – SQLite (system SQLite3 + FTS5) persistence,
// Keychain, StoreKit 2, licensing, account/sync, TV pairing, AVPlayer controller and the
// @Observable view models shared by the iOS and tvOS apps. Builds on macOS too so the logic
// can be unit-tested with `swift test`.
let package = Package(
    name: "IPTVKit",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "IPTVKit", targets: ["IPTVKit"]),
    ],
    dependencies: [
        .package(path: "../IPTVCore"),
    ],
    targets: [
        .target(
            name: "IPTVKit",
            dependencies: [
                .product(name: "IPTVCore", package: "IPTVCore"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "IPTVKitTests",
            dependencies: ["IPTVKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
