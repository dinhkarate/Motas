// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Motas",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MotasCore", targets: ["MotasCore"]),
        .executable(name: "Motas", targets: ["MotasMain"]),
        .executable(name: "MotasGallery", targets: ["MotasGallery"]),
    ],
    targets: [
        .target(
            name: "MotasCore",
            path: "Sources/MotasCore"
        ),
        .target(
            name: "MotasAppKit",
            dependencies: ["MotasCore"],
            path: "Sources/MotasAppKit",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "MotasMain",
            dependencies: ["MotasAppKit"],
            path: "Sources/MotasMain"
        ),
        .executableTarget(
            name: "MotasGallery",
            dependencies: ["MotasCore", "MotasAppKit"],
            path: "Sources/MotasGallery"
        ),

        .testTarget(
            name: "MotasCoreTests",
            dependencies: ["MotasCore"],
            path: "Tests/MotasCoreTests"
        ),
    ]
)
