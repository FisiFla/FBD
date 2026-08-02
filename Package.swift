// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FBD",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FBDCore", targets: ["FBDCore"]),
        .executable(name: "FBD", targets: ["FBD"]),
        .executable(name: "fbdcli", targets: ["fbdcli"]),
    ],
    dependencies: [
        // Auto-update framework (optional; requires a signed release + appcast).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        // C shims: private-framework function declarations + CGS struct layout.
        .target(name: "CPrivateAPI", publicHeadersPath: "include"),
        // All logic: models, controllers, private-API wrappers, DDC protocol.
        .target(
            name: "FBDCore",
            dependencies: ["CPrivateAPI"],
            linkerSettings: [
                // Private frameworks are not on SPM's default library search path.
                // Direct linkage mirrors how lunar/displayplacer call these APIs.
                .unsafeFlags([
                    "-F/System/Library/PrivateFrameworks",
                    "-framework", "DisplayServices",
                    "-framework", "SkyLight",
                    "-framework", "CoreDisplay",
                    "-framework", "IOMobileFramebuffer",
                ])
            ]
        ),
        // Menu-bar app (LSUIElement). Bundle assembled by `make app`.
        .executableTarget(
            name: "FBD",
            dependencies: ["FBDCore", "FBDIntents", .product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Resources"], // Info.plist copied into the bundle by `make app`
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        // Command-line interface.
        .executableTarget(name: "fbdcli", dependencies: ["FBDCore", "FBDCLIParser"]),
        // CLI command surface + argument parser (library so it is testable).
        // Directory is `fbdcli-parser`: a case-variant of `fbdcli` would
        // alias on case-insensitive filesystems (macOS/APFS).
        .target(name: "FBDCLIParser", dependencies: ["FBDCore"], path: "Sources/fbdcli-parser"),
        .testTarget(name: "FBDCLIParserTests", dependencies: ["FBDCLIParser"]),
        // App Intents / Shortcuts (Tier 5).
        .target(name: "FBDIntents", dependencies: ["FBDCore"]),
        .testTarget(name: "FBDCoreTests", dependencies: ["FBDCore"]),
    ]
)
