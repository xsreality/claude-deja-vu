// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DejaVu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DejaVu", path: "Sources/DejaVu"),
    ]
)
