// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YTerm",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "YTerm",
            path: "Sources/YTerm"
        ),
        .testTarget(
            name: "YTermTests",
            dependencies: ["YTerm"],
            path: "Tests/YTermTests"
        ),
    ]
)
