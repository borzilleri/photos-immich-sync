import Foundation
import Testing
import Yams

@testable import PhotosImmichSyncCore

private let MINIMAL_YAML = """
  immich:
    api:
      url: "http://immich.local:2283"
      metadataApiUrl: "http://immich.local:8788"
      apiKey: "test-key"
  """

private func decodeConfig(_ yaml: String = MINIMAL_YAML) throws -> AppConfig {
  try YAMLDecoder().decode(AppConfig.self, from: yaml)
}

/// Runs `work` and returns the `DecodingError.dataCorrupted` debug description,
/// or nil if nothing (or something else) was thrown.
private func dataCorruptedMessage(_ work: () throws -> Any) -> String? {
  do {
    _ = try work()
    return nil
  } catch let DecodingError.dataCorrupted(context) {
    return context.debugDescription
  } catch {
    return nil
  }
}

@Suite struct ConfigTests {
  // MARK: Defaults

  @Test func minimalConfigAppliesAllDefaults() throws {
    let config = try decodeConfig()
    #expect(config.enableUpdateCheck == true)
    #expect(config.exportOnly == false)

    #expect(config.immich.api.maxConcurrentRequests == 32)
    #expect(config.immich.api.retryAttempts == 3)
    #expect(config.immich.api.requestTimeoutSeconds == 0)
    #expect(config.immich.api.connectTimeoutSeconds == 30)
    #expect(config.immich.api.connectionIdleTimeoutSeconds == 300)

    #expect(config.immich.assets.overwriteInfo == true)
    #expect(config.immich.assets.delete == true)
    #expect(config.immich.assets.forceDelete == true)
    #expect(config.immich.assets.maxConcurrentDownloads == 500)

    #expect(config.immich.tags.enabled == false)
    #expect(config.immich.tags.delete == true)
    #expect(config.immich.tags.parentTag == "🍎")
    #expect(config.immich.tags.stackPrimaryOnly == true)

    #expect(config.immich.albums.enabled == true)
    #expect(config.immich.albums.delete == true)
    #expect(config.immich.albums.pathSeparator == " / ")
    #expect(config.immich.albums.createEmpty == false)
    #expect(config.immich.albums.stackPrimaryOnly == true)

    #expect(config.photos.export.includeBursts == BurstType.none)
    #expect(config.photos.export.includeTitleCaption == false)
    #expect(config.photos.export.exportConcurrency == 1_000)
    #expect(config.photos.export.includeHidden == false)
    #expect(config.photos.export.fetchLimit == nil)
    #expect(config.photos.export.oldestFirst == false)

    #expect(config.photos.download.timeoutSeconds == 300)
    #expect(config.photos.download.retryAttempts == 3)
  }

  @Test func computedTimeoutsMapZeroToNil() throws {
    let defaults = try makeApiConfig()
    #expect(defaults.requestTimeout == nil)  // requestTimeoutSeconds defaults to 0
    #expect(defaults.connectTimeout == .seconds(30))
    #expect(defaults.connectionIdleTimeout == .seconds(300))

    let tuned = try makeApiConfig(extraYaml: "requestTimeoutSeconds: 5\nconnectionIdleTimeoutSeconds: 0")
    #expect(tuned.requestTimeout == .seconds(5))
    #expect(tuned.connectionIdleTimeout == nil)
  }

  @Test func retryConfigMapsDownloadSettings() throws {
    let config = try decodeConfig(
      MINIMAL_YAML + """

        photos:
          download:
            timeoutSeconds: 60
            retryAttempts: 5
        """)
    let retry = config.photos.download.retryConfig
    #expect(retry.maxAttempts == 5)
    #expect(retry.timeout == .seconds(60))
  }

  @Test func explicitOverridesAreHonored() throws {
    let config = try decodeConfig(
      MINIMAL_YAML + """

        enableUpdateCheck: false
        exportOnly: true
        """)
    #expect(config.enableUpdateCheck == false)
    #expect(config.exportOnly == true)
  }

  // MARK: Required fields

  @Test func missingImmichSectionFails() {
    #expect(throws: DecodingError.self) { try decodeConfig("exportOnly: true") }
  }

  @Test(arguments: ["url", "metadataApiUrl", "apiKey"])
  func missingRequiredApiFieldFails(missing: String) throws {
    let fields = [
      "url": #"url: "http://a""#,
      "metadataApiUrl": #"metadataApiUrl: "http://b""#,
      "apiKey": #"apiKey: "k""#,
    ]
    let body = fields.filter { $0.key != missing }.values.map { "    \($0)" }.joined(separator: "\n")
    #expect(throws: DecodingError.self) {
      try decodeConfig("immich:\n  api:\n\(body)")
    }
  }

  // MARK: Unknown-key rejection

  @Test func unknownRootKeyIsRejectedWithLocationAndAllowedKeys() {
    let message = dataCorruptedMessage { try decodeConfig(MINIMAL_YAML + "\nbogusKey: 1") }
    #expect(message != nil)
    #expect(message?.contains("config root") == true)
    #expect(message?.contains("bogusKey") == true)
    #expect(message?.contains("Allowed keys:") == true)
    #expect(message?.contains("enableUpdateCheck") == true)
  }

  @Test func unknownNestedKeyReportsItsPath() {
    let message = dataCorruptedMessage {
      try decodeConfig(
        """
        immich:
          api:
            url: "http://a"
            metadataApiUrl: "http://b"
            apiKey: "k"
            bogus: true
        """)
    }
    #expect(message?.contains("'immich.api'") == true)
    #expect(message?.contains("bogus") == true)
  }

  // MARK: Validation boundaries

  @Test(arguments: [
    ("retryAttempts: 0", "immich.client.retryAttempts"),
    ("maxConcurrentRequests: 0", "immich.client.maxConcurrentRequests"),
    ("requestTimeoutSeconds: -1", "immich.client.requestTimeoutSeconds"),
    ("connectTimeoutSeconds: 0", "immich.client.connectTimeoutSeconds"),
    ("connectionIdleTimeoutSeconds: -1", "immich.client.connectionIdleTimeoutSeconds"),
  ])
  func apiIntBoundariesAreEnforced(override: String, expectedName: String) {
    let message = dataCorruptedMessage { try makeApiConfig(extraYaml: override) }
    #expect(message?.contains(expectedName) == true)
    #expect(message?.contains("must be at least") == true)
  }

  @Test func requestTimeoutZeroIsAllowed() throws {
    _ = try makeApiConfig(extraYaml: "requestTimeoutSeconds: 0")
  }

  @Test func assetDownloadConcurrencyBoundary() {
    let message = dataCorruptedMessage {
      try decodeConfig(
        MINIMAL_YAML + """

            assets:
              maxConcurrentDownloads: 0
          """)
    }
    #expect(message?.contains("maxConcurrentDownloads must be at least 1") == true)
  }

  @Test(arguments: [
    ("retryAttempts: 0", "retry.maxAttempts"),
    ("timeoutSeconds: 0", "retry.timeoutSeconds"),
  ])
  func downloadBoundariesAreEnforced(override: String, expectedFragment: String) {
    let message = dataCorruptedMessage {
      try decodeConfig(
        MINIMAL_YAML + """

          photos:
            download:
              \(override)
          """)
    }
    #expect(message?.contains(expectedFragment) == true)
  }

  // MARK: BurstType

  @Test(arguments: [("all", BurstType.all), ("none", .none), ("selected", .selected)])
  func burstTypeDecodesRawValues(raw: String, expected: BurstType) throws {
    let config = try decodeConfig(
      MINIMAL_YAML + """

        photos:
          export:
            includeBursts: "\(raw)"
        """)
    #expect(config.photos.export.includeBursts == expected)
  }

  @Test func invalidBurstTypeFails() {
    #expect(throws: DecodingError.self) {
      try decodeConfig(
        MINIMAL_YAML + """

          photos:
            export:
              includeBursts: "sometimes"
          """)
    }
  }

  // MARK: AppConfig.load path handling

  @Test func loadAcceptsPlainPathAndFileURL() throws {
    let dir = try makeTempTestDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.yaml")
    try MINIMAL_YAML.write(to: file, atomically: true, encoding: .utf8)

    let fromPath = try AppConfig.load(fromFile: file.path)
    #expect(fromPath.immich.api.url == "http://immich.local:2283")

    let fromURLString = try AppConfig.load(fromFile: file.absoluteString)
    #expect(fromURLString.immich.api.apiKey == "test-key")
  }

  @Test func loadFailsClearlyWhenFileIsMissing() {
    #expect(throws: (any Error).self) {
      try AppConfig.load(fromFile: "/nonexistent/photos-immich-sync-test.yaml")
    }
  }
}
