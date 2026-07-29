// swift-tools-version: 6.1
import PackageDescription

// Match the Xcode target's language configuration: Swift 5 mode with
// MemberImportVisibility and Approachable Concurrency enabled.
let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("BareSlashRegexLiterals"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("DisableOutwardActorInference"),
  .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("InferSendableFromCaptures"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("RegionBasedIsolation"),
]

let package = Package(
  name: "PhotosImmichSyncCore",
  platforms: [.macOS("26.2")],
  products: [
    .library(name: "PhotosImmichSyncCore", targets: ["PhotosImmichSyncCore"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.10.4"),
    .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.10.1"),
    .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.2.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.32.0"),
    .package(url: "https://github.com/swift-server/swift-openapi-async-http-client", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.43.0"),
    .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
  ],
  targets: [
    .target(
      name: "PhotosImmichSyncCore",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
        .product(name: "OpenAPIAsyncHTTPClient", package: "swift-openapi-async-http-client"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOHTTP2", package: "swift-nio-http2"),
        .product(name: "Yams", package: "Yams"),
      ],
      swiftSettings: swiftSettings,
      linkerSettings: [
        .linkedFramework("Photos")
      ],
      plugins: [
        .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
      ]
    ),
    .testTarget(
      name: "PhotosImmichSyncCoreTests",
      dependencies: ["PhotosImmichSyncCore"],
      swiftSettings: swiftSettings
    ),
  ],
  swiftLanguageModes: [.v5]
)
