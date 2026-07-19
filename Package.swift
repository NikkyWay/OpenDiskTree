// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "OpenDiskTree",
  defaultLocalization: "en",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "OpenDiskTreeCore", targets: ["OpenDiskTreeCore"]),
    .executable(name: "OpenDiskTree", targets: ["OpenDiskTreeApp"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(
      name: "OpenDiskTreeNative",
      publicHeadersPath: "include",
      cSettings: [.define("_DARWIN_C_SOURCE")]
    ),
    .target(
      name: "OpenDiskTreeCore",
      dependencies: ["CSQLite", "OpenDiskTreeNative"]
    ),
    .executableTarget(
      name: "OpenDiskTreeApp",
      dependencies: ["OpenDiskTreeCore"],
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "OpenDiskTreeCoreTests",
      dependencies: ["OpenDiskTreeCore"]
    ),
  ]
)
