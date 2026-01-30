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
    // Export CSQLite separately so apps can link it directly
    .library(
      name: "CSQLite",
      targets: ["CSQLite"]),
  ],
  dependencies: [],
  targets: [
    // Custom SQLite compiled with extension loading support
    .target(
      name: "CSQLite",
      path: "Sources/CSQLite",
      sources: ["sqlite3.c"],
      publicHeadersPath: "include",
      cSettings: [
        // Enable extension loading - this is the key feature
        .define("SQLITE_ENABLE_LOAD_EXTENSION"),
        // Performance optimizations
        .define("SQLITE_ENABLE_FTS5"),
        .define("SQLITE_ENABLE_RTREE"),
        .define("SQLITE_ENABLE_JSON1"),
        .define("SQLITE_THREADSAFE", to: "2"),
        .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
        .define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
        .define("SQLITE_LIKE_DOESNT_MATCH_BLOBS"),
        .define("SQLITE_OMIT_DEPRECATED"),
        .define("SQLITE_OMIT_SHARED_CACHE"),
        .define("SQLITE_USE_ALLOCA"),
        .define("SQLITE_ENABLE_COLUMN_METADATA"),
      ],
      linkerSettings: [
        // Force all symbols to be exported (prevents dead-stripping)
        .linkedLibrary("z"),  // zlib for compression
      ]
    ),
    .target(
      name: "MCPCore",
      dependencies: ["CSQLite"]
    ),
    .testTarget(
      name: "MCPCoreTests",
      dependencies: ["MCPCore"]),
  ]
)
