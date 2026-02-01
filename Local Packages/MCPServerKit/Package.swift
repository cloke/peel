// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MCPServerKit",
  platforms: [.macOS("26"), .iOS("26")],
  products: [
    .library(name: "MCPServerKit", targets: ["MCPServerKit"])
  ],
  dependencies: [
    .package(path: "../MCPCore")
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
