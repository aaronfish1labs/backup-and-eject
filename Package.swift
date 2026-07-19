// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "BackupAndEject",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BackupAndEjectCore",
            targets: ["BackupAndEjectCore"]
        ),
        .executable(
            name: "BackupAndEject",
            targets: ["BackupAndEject"]
        )
    ],
    targets: [
        .target(
            name: "BackupAndEjectCore"
        ),
        .executableTarget(
            name: "BackupAndEject",
            dependencies: ["BackupAndEjectCore"]
        ),
        .testTarget(
            name: "BackupAndEjectCoreTests",
            dependencies: ["BackupAndEjectCore"]
        ),
        .testTarget(
            name: "BackupAndEjectTests",
            dependencies: ["BackupAndEject"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
