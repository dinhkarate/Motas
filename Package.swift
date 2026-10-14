// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Motas",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MotasCore", targets: ["MotasCore"]),
        .library(name: "MotasUI", targets: ["MotasUI"]),
        .library(name: "MotasWidgetKit", targets: ["MotasWidgetKit"]),
        .executable(name: "Motas", targets: ["Motas"]),
        .executable(name: "MotasWidget", targets: ["MotasWidget"]),
    ],
    targets: [
        .target(name: "MotasCore", path: "Sources/MotasCore"),
        .target(name: "MotasUI", dependencies: ["MotasCore"], path: "Sources/MotasUI"),
        .target(name: "MotasWidgetKit", dependencies: ["MotasCore"], path: "Sources/MotasWidgetKit"),
        .executableTarget(name: "Motas", dependencies: ["MotasUI"], path: "Sources/Motas"),
        .executableTarget(name: "MotasWidget", dependencies: ["MotasWidgetKit"], path: "Sources/MotasWidgetExtension"),
        .executableTarget(name: "motas-render", dependencies: ["MotasUI", "MotasWidgetKit"], path: "Sources/MotasRender"),
        .testTarget(
            name: "MotasCoreTests",
            dependencies: ["MotasCore", "MotasUI"],
            path: "Tests/MotasCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
