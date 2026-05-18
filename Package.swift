// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CryptoMenubar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CryptoMenubar",
            path: "Sources/CryptoMenubar"
        )
    ]
)
