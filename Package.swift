// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenMeter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TokenMeter", targets: ["TokenMeter"])
    ],
    targets: [
        .target(name: "TokenMeterCore"),
        .executableTarget(
            name: "TokenMeter",
            dependencies: ["TokenMeterCore"]
        ),
        .testTarget(
            name: "TokenMeterCoreTests",
            dependencies: ["TokenMeterCore"]
        )
    ]
)
