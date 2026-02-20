// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PeelAgent",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "peel", targets: ["PeelAgent"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
  ],
  targets: [
    .executableTarget(
      name: "PeelAgent",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/PeelAgent"
    )
  ]
)
