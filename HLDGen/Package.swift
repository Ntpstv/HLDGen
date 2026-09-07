// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HLDGen",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "hldgen", path: "Sources/HLDGen")
    ]
)
