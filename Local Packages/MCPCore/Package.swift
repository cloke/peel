// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "MCPCore",
  platforms: [.macOS("26"), .iOS("26")],
  products: [
    .library(
      name: "MCPCore",
      targets: ["MCPCore"]),
  ],
  dependencies: [],
  targets: [
    .target(
      name: "MCPCore",
      dependencies: []
    ),
    .testTarget(
      name: "MCPCoreTests",
      dependencies: ["MCPCore"]),
  ]
)
