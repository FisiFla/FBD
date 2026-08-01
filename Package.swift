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
                ])
            ]
        ),
        // Menu-bar app (LSUIElement). Bundle assembled by `make app`.
        .executableTarget(
            name: "FBD",
            dependencies: ["FBDCore"],
            exclude: ["Resources"] // Info.plist copied into the bundle by `make app`
        ),
        // Command-line interface.
        .executableTarget(name: "fbdcli", dependencies: ["FBDCore"]),
        .testTarget(name: "FBDCoreTests", dependencies: ["FBDCore"]),
    ]
)
