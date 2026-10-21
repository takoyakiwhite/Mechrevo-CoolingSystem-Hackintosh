// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wcooler",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "wcooler",
            path: "Sources/wcooler",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
