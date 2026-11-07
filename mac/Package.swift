// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GalaxyContinuity",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "GalaxyContinuityKit",
            targets: ["GalaxyContinuityKit"]
        ),
        .executable(
            name: "GalaxyContinuity",
            targets: ["GalaxyContinuity"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "GalaxyContinuityKit",
            dependencies: [],
            path: "Sources/GalaxyContinuityKit"
        ),
        .executableTarget(
            name: "GalaxyContinuity",
            dependencies: [
                "GalaxyContinuityKit"
            ],
            path: "Sources/GalaxyContinuity"
        ),
        .testTarget(
            name: "GalaxyContinuityTests",
            dependencies: [
                "GalaxyContinuityKit"
            ],
            path: "Tests/GalaxyContinuityTests"
        )
    ]
)
