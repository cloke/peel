// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Git",
  platforms: [.macOS("26"), .iOS("26")],
  products: [
    // Products define the executables and libraries a package produces, and make them visible to other packages.
    .library(
      name: "Git",
      targets: ["Git"]),
  ],
  dependencies: [
    // Dependencies declare other packages that this package depends on.
    // CrunchyCommon removed - migrated to Shared/Extensions
    .package(name: "TaskRunner", path: "../../../TaskRunner")
  ],
  targets: [
    // Targets are the basic building blocks of a package. A target can define a module or a test suite.
    // Targets can depend on other targets in this package, and on products in packages this package depends on.
    .target(
      name: "Git",
      dependencies: ["TaskRunner"]
    ),
    
    .testTarget(
      name: "GitTests",
      dependencies: ["Git"]),
  ]
)
