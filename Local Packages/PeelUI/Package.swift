// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "PeelUI",
  platforms: [.macOS("26")],
  products: [
    .library(
      name: "PeelUI",
      targets: ["PeelUI"]),
  ],
  dependencies: [],
  targets: [
    .target(
      name: "PeelUI",
      dependencies: []),
    .testTarget(
      name: "PeelUITests",
      dependencies: ["PeelUI"]),
  ]
)
