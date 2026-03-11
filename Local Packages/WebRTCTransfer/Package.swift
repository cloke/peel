// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "WebRTCTransfer",
  platforms: [.macOS("26"), .iOS("26")],
  products: [
    .library(
      name: "WebRTCTransfer",
      targets: ["WebRTCTransfer"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/stasel/WebRTC.git", from: "141.0.0"),
  ],
  targets: [
    .target(
      name: "WebRTCTransfer",
      dependencies: ["WebRTC"]
    ),
  ]
)
