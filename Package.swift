// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FocusBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FocusBar", targets: ["FocusBar"])
    ],
    targets: [
        .executableTarget(name: "FocusBar")
    ]
)
