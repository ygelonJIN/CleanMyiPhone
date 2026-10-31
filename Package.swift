// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cleanmyiphone",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CleanMyiPhone",
            path: "Sources/CleanMyiPhone",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
