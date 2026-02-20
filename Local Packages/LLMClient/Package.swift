// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LLMClient",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "LLMClient", targets: ["LLMClient"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "LLMClient",
      path: "Sources/LLMClient"
    ),
    .testTarget(
      name: "LLMClientTests",
      dependencies: ["LLMClient"],
      path: "Tests/LLMClientTests"
    ),
  ]
)
