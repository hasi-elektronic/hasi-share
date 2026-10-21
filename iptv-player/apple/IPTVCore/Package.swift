// swift-tools-version:6.0
import PackageDescription

// IPTVCore: platform-independent models, parsers, connection and business logic
// shared by the iPhone/iPad and Apple TV apps. Builds on Apple platforms (CryptoKit,
// system zlib) and on Linux (swift-crypto, system zlib) so it can be tested in Docker.
let package = Package(
    name: "IPTVCore",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "IPTVCore", targets: ["IPTVCore"]),
    ],
    dependencies: [
        // Only linked on non-Apple platforms; Apple builds use CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        // Thin C shim over the system zlib (libz ships with every Apple SDK and Linux distro).
        .target(
            name: "CZlib",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "IPTVCore",
            dependencies: [
                "CZlib",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "IPTVCoreTests",
            dependencies: ["IPTVCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
