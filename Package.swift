// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Curfew",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CurfewKit", targets: ["CurfewKit"]),
        .executable(name: "curfew", targets: ["curfew"]),
    ],
    targets: [
        .target(
            name: "CurfewKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "curfew-menubar",
            dependencies: ["CurfewKit"],
            path: "Sources/curfew-menubar"
        ),
        .executableTarget(
            name: "curfew",
            dependencies: ["CurfewKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CurfewKitTests",
            dependencies: ["CurfewKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CurfewTests",
            dependencies: ["CurfewKit", "curfew"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
