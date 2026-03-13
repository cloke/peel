// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "PIIScrubber",
  platforms: [
    .macOS(.v15),
  ],
  products: [
    .library(
      name: "PIIScrubber",
      targets: ["PIIScrubber"]
    ),
    .executable(
      name: "pii-scrubber",
      targets: ["PIIScrubberCLI"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
  ],
  targets: [
    .target(
      name: "PIIScrubber",
      dependencies: [
        .product(name: "Yams", package: "Yams"),
      ]
    ),
    .testTarget(
      name: "PIIScrubberTests",
      dependencies: ["PIIScrubber"]
    ),
    .executableTarget(
      name: "PIIScrubberCLI",
      dependencies: [
        "PIIScrubber",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
  ]
)
