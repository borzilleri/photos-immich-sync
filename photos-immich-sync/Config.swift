import Foundation
import Yams

let DEFAULT_CONFIG_PATH = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent(".config/photos-immich-sync/photos-immich-sync.yaml")
  .absoluteString


struct AppConfig: Codable {
  var enableUpdateCheck: Bool
  var immich: ImmichConfig
  var photos: PhotosConfig

  var exportOnly: Bool

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    immich = try container.decode(ImmichConfig.self, forKey: .immich)
    photos = try container.decodeIfPresent(PhotosConfig.self, forKey: .photos) ?? PhotosConfig()

    exportOnly = try container.decodeIfPresent(Bool.self, forKey: .exportOnly) ?? false
    enableUpdateCheck = try container.decodeIfPresent(Bool.self, forKey: .enableUpdateCheck) ?? true
  }

  static func load(fromFile path: String) throws -> AppConfig {
    let fileURL: URL
    if let u = URL(string: path), u.isFileURL {
      fileURL = u
    } else {
      fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: false)
    }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw NSError(
        domain: APP_NAME, code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Config file not found: \(fileURL.path)"])
    }
    let decoder = YAMLDecoder()
    let contents = try String(contentsOf: fileURL, encoding: .utf8)
    return try decoder.decode(AppConfig.self, from: contents)
  }
}

private let IMMICH_ID_CHECK_BATCH_SIZE: Int = 5_000
struct ImmichConfig: Codable {
  var api: ImmichApiConfig
  var assets: ImmichAssetConfig
  var tags: ImmichTagConfig
  var albums: ImmichAlbumConfig

  /// Private Options
  var idCheckBatchSize: Int

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    api = try container.decode(ImmichApiConfig.self, forKey: .api)
    assets = try container.decodeIfPresent(ImmichAssetConfig.self, forKey: .assets) ?? ImmichAssetConfig()
    tags = try container.decodeIfPresent(ImmichTagConfig.self, forKey: .tags) ?? ImmichTagConfig()
    albums = try container.decodeIfPresent(ImmichAlbumConfig.self, forKey: .albums) ?? ImmichAlbumConfig()

    idCheckBatchSize = try container.decodeIfPresent(Int.self, forKey: .idCheckBatchSize) ?? IMMICH_ID_CHECK_BATCH_SIZE
  }
}

private func validateInt(name: String, codingPath: [any CodingKey], value: Int, min: Int?) throws {
  if let min, value < min {
    throw DecodingError.dataCorrupted(
      .init(
        codingPath: codingPath,
        debugDescription: "\(name) must be at least \(min), was \(value)"))
  }
}

private let IMMICH_CLIENT_CONCURRENT_REQUESTS: Int = 32
private let IMMICH_CLIENT_RETRY_ATTEMPTS = 3
private let IMMICH_CLIENT_REQUEST_TIMEOUT_SECONDS: Int = 0
private let IMMICH_CLIENT_CONNECT_TIMEOUT_SECONDS: Int = 30
private let IMMICH_CLIENT_IDLE_TIMEOUT_SECONDS: Int = 300
struct ImmichApiConfig: Codable {
  var url: String
  var apiKey: String
  var maxConcurrentRequests: Int
  var retryAttempts: Int
  var requestTimeoutSeconds: Int
  var connectTimeoutSeconds: Int
  var connectionIdleTimeoutSeconds: Int

  var requestTimeout: Duration? { requestTimeoutSeconds == 0 ? nil : .seconds(requestTimeoutSeconds) }
  var connectTimeout: Duration { .seconds(connectTimeoutSeconds) }
  var connectionIdleTimeout: Duration? { connectionIdleTimeoutSeconds == 0 ? nil : .seconds(connectionIdleTimeoutSeconds) }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    url = try c.decode(String.self, forKey: .url)
    apiKey = try c.decode(String.self, forKey: .apiKey)
    maxConcurrentRequests =
      try c.decodeIfPresent(Int.self, forKey: .maxConcurrentRequests) ?? IMMICH_CLIENT_CONCURRENT_REQUESTS
    retryAttempts = try c.decodeIfPresent(Int.self, forKey: .retryAttempts) ?? IMMICH_CLIENT_RETRY_ATTEMPTS
    requestTimeoutSeconds =
      try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? IMMICH_CLIENT_REQUEST_TIMEOUT_SECONDS
    connectTimeoutSeconds =
      try c.decodeIfPresent(Int.self, forKey: .connectTimeoutSeconds) ?? IMMICH_CLIENT_CONNECT_TIMEOUT_SECONDS
    connectionIdleTimeoutSeconds =
      try c.decodeIfPresent(Int.self, forKey: .connectionIdleTimeoutSeconds) ?? IMMICH_CLIENT_IDLE_TIMEOUT_SECONDS
    try validateInt(name: "immich.client.retryAttempts", codingPath: c.codingPath, value: retryAttempts, min: 1)
    try validateInt(name: "immich.client.maxConcurrentRequests", codingPath: c.codingPath, value: maxConcurrentRequests, min: 1)
    try validateInt(name: "immich.client.requestTimeoutSeconds", codingPath: c.codingPath, value: requestTimeoutSeconds, min: 0)
    try validateInt(name: "immich.client.connectTimeoutSeconds", codingPath: c.codingPath, value: connectTimeoutSeconds, min: 1)
    try validateInt(name: "immich.client.connectionIdleTimeoutSeconds", codingPath: c.codingPath, value: connectionIdleTimeoutSeconds, min: 0)
  }
}

private let IMMICH_SYNC_OVERWRITE_INFO: Bool = true
private let IMMICH_SYNC_DELETE: Bool = true
private let IMMICH_SYNC_FORCE_DELETE: Bool = true
private let IMMICH_SYNC_DOWNLOAD_CONCURRENCY: Int = 500
public struct ImmichAssetConfig: Codable {
  var overwriteInfo: Bool
  var delete: Bool
  var forceDelete: Bool
  /// Governs maximum concurrent downloaded assets, during asset sync stage.
  var maxConcurrentDownloads: Int

  public init() {
    overwriteInfo = IMMICH_SYNC_OVERWRITE_INFO
    maxConcurrentDownloads = IMMICH_SYNC_DOWNLOAD_CONCURRENCY
    delete = IMMICH_SYNC_DELETE
    forceDelete = IMMICH_SYNC_FORCE_DELETE
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    overwriteInfo = try c.decodeIfPresent(Bool.self, forKey: .overwriteInfo) ?? IMMICH_SYNC_OVERWRITE_INFO
    maxConcurrentDownloads =
      try c.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? IMMICH_SYNC_DOWNLOAD_CONCURRENCY
    forceDelete = try c.decodeIfPresent(Bool.self, forKey: .forceDelete) ?? IMMICH_SYNC_FORCE_DELETE
    delete = try c.decodeIfPresent(Bool.self, forKey: .delete) ?? IMMICH_SYNC_DELETE
    try Self.validate(
      maxConcurrentDownloads: maxConcurrentDownloads,
      codingPath: c.codingPath)
  }

  private static func validate(
    maxConcurrentDownloads: Int,
    codingPath: [any CodingKey]
  ) throws {
    if maxConcurrentDownloads < 1 {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: codingPath,
          debugDescription:
            "immich.sync.maxConcurrentDownloads must be at least 1, got \(maxConcurrentDownloads)"))
    }
  }
}

private let IMMICH_TAG_ENABLED: Bool = false
private let IMMICH_TAG_DELETE: Bool = true
private let IMMICH_TAG_PARENT: String = "🍎"
private let IMMICH_TAG_PRIMARY_ONLY: Bool = true
struct ImmichTagConfig: Codable {
  var enabled: Bool
  var delete: Bool
  var parentTag: String
  var stackPrimaryOnly: Bool

  public init() {
    enabled = IMMICH_TAG_ENABLED
    delete = IMMICH_TAG_DELETE
    parentTag = IMMICH_TAG_PARENT
    stackPrimaryOnly = IMMICH_TAG_PRIMARY_ONLY
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? IMMICH_TAG_ENABLED
    delete = try c.decodeIfPresent(Bool.self, forKey: .delete) ?? IMMICH_TAG_DELETE
    parentTag = try c.decodeIfPresent(String.self, forKey: .parentTag) ?? IMMICH_TAG_PARENT
    stackPrimaryOnly = try c.decodeIfPresent(Bool.self, forKey: .stackPrimaryOnly) ?? IMMICH_TAG_PRIMARY_ONLY
  }
}

private let IMMICH_ALBUM_ENABLED: Bool = true
private let IMMICH_ALBUM_DELETE: Bool = true
private let IMMICH_ALBUM_SEPARATOR: String = " / "
private let IMMICH_ALBUM_CREATE_EMPTY: Bool = false
private let IMMICH_ALBUM_PRIMARY_ONLY: Bool = true
private let IMMICH_ALBUM_TRACK: Bool = true
struct ImmichAlbumConfig: Codable {
  var enabled: Bool
  var delete: Bool
  var pathSeparator: String
  var createEmpty: Bool
  var stackPrimaryOnly: Bool

  init() {
    enabled = IMMICH_ALBUM_ENABLED
    delete = IMMICH_ALBUM_DELETE
    pathSeparator = IMMICH_ALBUM_SEPARATOR
    createEmpty = IMMICH_ALBUM_CREATE_EMPTY
    stackPrimaryOnly = IMMICH_ALBUM_PRIMARY_ONLY
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? IMMICH_ALBUM_ENABLED
    delete = try c.decodeIfPresent(Bool.self, forKey: .delete) ?? IMMICH_ALBUM_DELETE
    pathSeparator = try c.decodeIfPresent(String.self, forKey: .pathSeparator) ?? IMMICH_ALBUM_SEPARATOR
    createEmpty = try c.decodeIfPresent(Bool.self, forKey: .createEmpty) ?? IMMICH_ALBUM_CREATE_EMPTY
    stackPrimaryOnly = try c.decodeIfPresent(Bool.self, forKey: .stackPrimaryOnly) ?? IMMICH_ALBUM_PRIMARY_ONLY
  }
}

struct PhotosConfig: Codable {
  var export: PhotosExportConfig
  var download: PhotosDownloadConfig

  init() {
    export = PhotosExportConfig()
    download = PhotosDownloadConfig()
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.export = try container.decodeIfPresent(PhotosExportConfig.self, forKey: .export) ?? PhotosExportConfig()
    self.download =
      try container.decodeIfPresent(PhotosDownloadConfig.self, forKey: .download) ?? PhotosDownloadConfig()
  }
}

private let PHOTOS_EXPORT_INCLUDE_TITLE_CAPTION: Bool = false
private let PHOTOS_EXPORT_BURSTS: BurstType = .none
private let PHOTOS_EXPORT_EXPORT_CONCURRENCY: Int = 1_000
private let PHOTOS_EXPORT_INCLUDE_HIDDEN_DEFAULT: Bool = false
private let PHOTOS_EXPORT_FETCH_LIMIT: Int? = nil
private let PHOTOS_EXPORT_OLDEST_FIRST: Bool = false
public struct PhotosExportConfig: Codable {
  var includeBursts: BurstType
  var includeTitleCaption: Bool
  /// Governs concurrency of calls to PhotoKit during asset export.
  var exportConcurrency: Int

  /// Private Options
  var includeHidden: Bool
  var fetchLimit: Int?
  var oldestFirst: Bool

  init() {
    includeBursts = PHOTOS_EXPORT_BURSTS
    includeTitleCaption = PHOTOS_EXPORT_INCLUDE_TITLE_CAPTION
    exportConcurrency = PHOTOS_EXPORT_EXPORT_CONCURRENCY
    includeHidden = PHOTOS_EXPORT_INCLUDE_HIDDEN_DEFAULT
    fetchLimit = PHOTOS_EXPORT_FETCH_LIMIT
    oldestFirst = PHOTOS_EXPORT_OLDEST_FIRST
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.includeHidden =
      try container.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? PHOTOS_EXPORT_INCLUDE_HIDDEN_DEFAULT
    self.fetchLimit = try container.decodeIfPresent(Int.self, forKey: .fetchLimit) ?? PHOTOS_EXPORT_FETCH_LIMIT
    self.oldestFirst = try container.decodeIfPresent(Bool.self, forKey: .oldestFirst) ?? PHOTOS_EXPORT_OLDEST_FIRST
    self.includeTitleCaption =
      try container.decodeIfPresent(Bool.self, forKey: .includeTitleCaption) ?? PHOTOS_EXPORT_INCLUDE_TITLE_CAPTION
    self.includeBursts = try container.decodeIfPresent(BurstType.self, forKey: .includeBursts) ?? PHOTOS_EXPORT_BURSTS
    self.exportConcurrency =
      try container.decodeIfPresent(Int.self, forKey: .exportConcurrency) ?? PHOTOS_EXPORT_EXPORT_CONCURRENCY
  }
}

private let PHOTOS_DOWNLOAD_TIMEOUT_SECONDS: Int = 300
private let PHOTOS_DOWNLOAD_RETRY_ATTEMPTS: Int = 3
struct PhotosDownloadConfig: Codable {
  var timeoutSeconds: Int
  var retryAttempts: Int

  var retryConfig: RetryConfig { .init(maxAttempts: retryAttempts, timeout: .seconds(timeoutSeconds)) }

  public init() {
    timeoutSeconds = PHOTOS_DOWNLOAD_TIMEOUT_SECONDS
    retryAttempts = PHOTOS_DOWNLOAD_RETRY_ATTEMPTS
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.timeoutSeconds =
      try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? PHOTOS_DOWNLOAD_TIMEOUT_SECONDS
    self.retryAttempts =
      try container.decodeIfPresent(Int.self, forKey: .retryAttempts) ?? PHOTOS_DOWNLOAD_RETRY_ATTEMPTS
    try Self.validate(retryAttempts: retryAttempts, timeoutSeconds: timeoutSeconds, codingPath: container.codingPath)
  }

  private static func validate(
    retryAttempts: Int, timeoutSeconds: Int, codingPath: [any CodingKey]
  ) throws {
    if retryAttempts < 1 {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: codingPath,
          debugDescription: "retry.maxAttempts must be at least 1, got \(retryAttempts)"))
    }
    if timeoutSeconds < 1 {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: codingPath,
          debugDescription: "retry.timeoutSeconds must be at least 1, got \(timeoutSeconds)"))
    }
  }
}
