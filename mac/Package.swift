// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GalaxyContinuity",
    platforms: [
        .macOS(.v14)
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
            path: "Tests/GalaxyContinuityTests",
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
