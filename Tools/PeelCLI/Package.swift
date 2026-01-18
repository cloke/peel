// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PeelCLI",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "peel-mcp", targets: ["PeelCLI"])
  ],
  targets: [
    .executableTarget(
      name: "PeelCLI",
      path: "Sources/PeelCLI"
    )
  ]
)
