// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PeelSkills",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "gh-issue-sync", targets: ["GHIssueSync"]),
    .executable(name: "roadmap-audit", targets: ["RoadmapAudit"]),
    .executable(name: "pattern-audit", targets: ["PatternAudit"]),
    .executable(name: "file-rewrite", targets: ["FileRewrite"]),
    .executable(name: "translation-validator", targets: ["TranslationValidator"]),
    .executable(name: "pii-scrubber", targets: ["PIIScrubber"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(url: "https://github.com/jpsim/Yams", from: "5.0.0")
  ],
  targets: [
    .executableTarget(
      name: "GHIssueSync",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Yams", package: "Yams")
      ],
      path: "Sources/GHIssueSync"
    ),
    .executableTarget(
      name: "RoadmapAudit",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Yams", package: "Yams")
      ],
      path: "Sources/RoadmapAudit"
    ),
    .executableTarget(
      name: "PatternAudit",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      path: "Sources/PatternAudit"
    ),
    .executableTarget(
      name: "FileRewrite",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      path: "Sources/FileRewrite"
    ),
    .executableTarget(
      name: "TranslationValidator",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Yams", package: "Yams")
      ],
      path: "Sources/TranslationValidator"
    ),
    .executableTarget(
      name: "PIIScrubber",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Yams", package: "Yams")
      ],
      path: "Sources/PIIScrubber"
    )
  ]
)
