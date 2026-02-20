// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PeelAgent",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "peel-agent", targets: ["PeelAgent"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(path: "../../Local Packages/LLMClient"),
  ],
  targets: [
    .executableTarget(
      name: "PeelAgent",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "LLMClient", package: "LLMClient"),
      ],
      path: "Sources/PeelAgent"
    )
  ]
)
