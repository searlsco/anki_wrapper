// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AnkiWrapper",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .tvOS(.v17),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "AnkiWrapper", targets: ["AnkiWrapper"])
  ],
  dependencies: [
    .package(url: "https://github.com/facebook/zstd.git", from: "1.5.7")
  ],
  targets: [
    .target(
      name: "AnkiWrapper",
      dependencies: [.product(name: "libzstd", package: "zstd")],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(
      name: "AnkiWrapperTests",
      dependencies: ["AnkiWrapper", .product(name: "libzstd", package: "zstd")],
      resources: [.copy("Fixtures")]
    ),
  ]
)
