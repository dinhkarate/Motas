// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Motas",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MotasCore", targets: ["MotasCore"]),
        .executable(name: "MotasPrototype", targets: ["MotasApp"]),
    ],
    targets: [
        .target(
            name: "MotasCore",
            path: "Sources/MotasCore"
        ),
        .executableTarget(
            name: "MotasApp",
            dependencies: ["MotasCore"],
            path: "Sources/MotasApp",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "MotasCoreTests",
            dependencies: ["MotasCore"],
            path: "Tests/MotasCoreTests"
        ),
    ]
)
