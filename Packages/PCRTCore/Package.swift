// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "PCRTCore",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(name: "PCRTCore", type: .static, targets: ["PCRTCore"])
    ],
    targets: [
        .target(name: "PCRTCore"),
        .testTarget(name: "PCRTCoreTests", dependencies: ["PCRTCore"])
    ]
)
