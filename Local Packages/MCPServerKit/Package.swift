// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MCPServerKit",
  platforms: [.macOS("26"), .iOS("26")],
  products: [
    .library(name: "MCPServerKit", targets: ["MCPServerKit"])
  ],
  dependencies: [
    // For local development, use: .package(path: "../MCPCore")
    .package(url: "https://github.com/crunchybananas/MCPCore.git", from: "1.0.0")
  ],
  targets: [
    .target(
      name: "MCPServerKit",
      dependencies: ["MCPCore"]
    ),
    .testTarget(
      name: "MCPServerKitTests",
      dependencies: ["MCPServerKit"]
    )
  ]
)
