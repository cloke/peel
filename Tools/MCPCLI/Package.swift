// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MCPCLI",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "mcp-server", targets: ["MCPCLI"])
  ],
  targets: [
    .executableTarget(
      name: "MCPCLI",
      path: "Sources/MCPCLI"
    )
  ]
)
