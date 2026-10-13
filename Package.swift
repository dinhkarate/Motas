// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Motas",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MotasCore", targets: ["MotasCore"])
    ],
    targets: [
        .target(name: "MotasCore", path: "Sources/MotasCore"),
        .testTarget(
            name: "MotasCoreTests",
            dependencies: ["MotasCore"],
            path: "Tests/MotasCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
