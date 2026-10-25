// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Pier",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "Pier",
      path: "Sources/Pier",
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "PierTests",
      dependencies: ["Pier"],
      path: "Tests/PierTests"
    ),
  ]
)
