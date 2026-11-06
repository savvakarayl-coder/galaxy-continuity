// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GalaxyContinuity",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "GalaxyContinuity",
            targets: ["GalaxyContinuity"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "GalaxyContinuity",
            dependencies: [],
            path: "Sources/GalaxyContinuity"
        )
    ]
)
