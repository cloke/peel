// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Github",
  platforms: [.macOS(.v11)],
  products: [
    // Products define the executables and libraries a package produces, and make them visible to other packages.
    .library(
      name: "Github",
      targets: ["Github"]),
  ],
  dependencies: [
    // Dependencies declare other packages that this package depends on.
    .package(name: "Kingfisher", url: "https://github.com/onevcat/Kingfisher.git", from: "6.0.0"),
    .package(name: "Alamofire", url: "https://github.com/Alamofire/Alamofire.git", from: "5.4.3"),
    .package(name: "OAuthSwift", url: "https://github.com/OAuthSwift/OAuthSwift.git", .upToNextMajor(from: "2.2.0")),
    .package(name: "CrunchyCommon", path: "../CrunchyCommon"),
    .package(name: "Git", path: "../Git")

  ],
  targets: [
    // Targets are the basic building blocks of a package. A target can define a module or a test suite.
    // Targets can depend on other targets in this package, and on products in packages this package depends on.
    .target(
      name: "Github",
      dependencies: ["Kingfisher", "Alamofire", "OAuthSwift", "CrunchyCommon", "Git"]),
    .testTarget(
      name: "GithubTests",
      dependencies: ["Github"]),
  ]
)
