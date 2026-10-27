import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Photos

public enum MetadataApiError: Error {
  case invalidServerURL(String)
  case unknown(statusCode: Int, body: String)
  case invalidPagination(String)
  case healthCheckFailed(String)
}

/// A single `field:value` filter. Multiple filters passed to `lookup` are ANDed together server-side.
public struct MetadataFilter: Sendable {
  public let field: String
  public let value: String

  public init(field: MetadataField, value: String) {
    self.field = field.rawValue
    self.value = value
  }
}

public enum MetadataField: String, Sendable {
  case phAssetCloudIdentifier
  case phAssetLocalIdentifier
  case burstIdentifier
  case resourceType
  case originalFilename
}

public struct AssetMetadataValue: Decodable, Sendable {
  public let phAssetCloudIdentifier: String?
  public let phAssetLocalIdentifier: String?
  public let burstIdentifier: String?
  public let resourceType: String?
  public let originalFilename: String?

  public func matchesBundle(_ bundle: AssetBundle, type: AssetType) -> Bool {
    guard resourceType == type.rawValue else {
      return false
    }
    if let cloudIdentifier = bundle.cloudIdentifier, let phAssetCloudIdentifier {
      return phAssetCloudIdentifier == cloudIdentifier
    }
    return phAssetLocalIdentifier == bundle.localIdentifier
  }

  public func assetIdentifier() -> String? {
    guard let type = AssetType.allCases.first(where: {$0.rawValue == resourceType}) else {
      return nil
    }
    if let localId = phAssetLocalIdentifier {
      return type.assetIdentifier(id: localId)
    }
    return nil
  }
}

public struct MetadataEntry: Decodable, Sendable {
  public let assetId: String
  public let value: AssetMetadataValue
}

private struct MetadataPage: Decodable {
  let items: [MetadataEntry]
  let limit: Int
  let offset: Int
  let total: Int
}

final public class MetadataApiClient: Sendable {
  private static let MAX_BODY = 8 * 1024 * 1024
  private static let PAGE_SIZE = 1000
  private static let MAX_PAGES = 10_000
  private static let decoder = JSONDecoder()

  // Query VALUES are percent-encoded against RFC 3986 unreserved characters only, so
  // reserved characters in cloud ids (`:`, `+`, `/`, `=`, …) never break query parsing.
  private static let queryValueAllowed: CharacterSet = {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "-._~")
    return set
  }()

  private static let log = Log.forCategory("MetadataAPI")

  /// Executes one HTTP request. Production uses the owned AsyncHTTPClient; tests
  /// inject a stub.
  typealias HTTPExecutor = @Sendable (HTTPClientRequest, NIODeadline) async throws -> HTTPClientResponse

  private let baseURLString: String
  private let apiKey: String
  private let executor: HTTPExecutor
  private let backoffSleep: @Sendable (Duration) async throws -> Void
  private let limiter: AsyncSemaphore
  private let requestTimeout: TimeAmount?
  private let retryAttempts: Int
  /// The HTTPClient this instance built (and must shut down). Nil for mock-backed clients.
  private let ownedHTTPClient: HTTPClient?

  public convenience init(_ config: ImmichApiConfig) throws {
    // Validate before creating the HTTPClient: an orphaned, never-shut-down
    // HTTPClient crashes on deinit.
    _ = try Self.validateAndNormalizeURL(config.metadataApiUrl)

    let httpClient = HTTPClient.make(for: config)

    try self.init(
      config,
      executor: { request, deadline in
        try await httpClient.execute(request, deadline: deadline)
      },
      ownedHTTPClient: httpClient)
  }

  /// Test Constructor, allows injecting mocked dependencies
  init(
    _ config: ImmichApiConfig,
    executor: @escaping HTTPExecutor,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    ownedHTTPClient: HTTPClient? = nil
  ) throws {
    self.baseURLString = try Self.validateAndNormalizeURL(config.metadataApiUrl)
    self.apiKey = config.apiKey
    self.retryAttempts = max(1, config.retryAttempts)
    self.executor = executor
    self.backoffSleep = sleep
    self.ownedHTTPClient = ownedHTTPClient
    self.limiter = AsyncSemaphore(maxConcurrentTasks: max(1, config.maxConcurrentRequests))
    self.requestTimeout = config.requestTimeout.map({ $0.toTimeAmount() })
  }

  /// Validates the configured metadata API URL and normalizes away trailing slashes
  /// so paths join cleanly.
  static func validateAndNormalizeURL(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let baseURL = URL(string: trimmed),
      let scheme = baseURL.scheme,
      scheme == "http" || scheme == "https",
      baseURL.host != nil
    else {
      throw MetadataApiError.invalidServerURL(raw)
    }
    var normalized = trimmed
    while normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized
  }

  // MARK: - Public API

  /// Releases the underlying HTTPClient's resources.
  /// Should be called when a run finishes, and must be called before the class deinits
  public func shutdown() async {
    await ownedHTTPClient?.shutdownQuietly(log: Self.log)
  }

  public func checkHealth() async -> Bool {
    do {
      _ = try await execute(path: "/health", query: [])
      return true
    } catch {
      Self.log.debug("Metadata API health check failed: \(error)")
      return false
    }
  }

  func lookup(filters: [MetadataFilter]) async throws -> [MetadataEntry] {
    try await fetchAllPages(#function, filters: filters)
  }

  func lookup(field: MetadataField, value: String) async throws -> [MetadataEntry] {
    try await lookup(filters: [MetadataFilter(field: field, value: value)])
  }

  func enumerateManaged() async throws -> [MetadataEntry] {
    try await fetchAllPages(#function, filters: [])
  }

  // MARK: - Request plumbing

  private func fetchAllPages(_ operation: String, filters: [MetadataFilter]) async throws -> [MetadataEntry] {
    var all: [MetadataEntry] = []
    var offset = 0
    var pagesFetched = 0
    while true {
      let page = try await withRetry(operation) {
        try await self.getMetadataPage(filters: filters, offset: offset)
      }
      all.append(contentsOf: page.items)
      if page.items.isEmpty || all.count >= page.total { break }
      pagesFetched += 1
      guard pagesFetched < Self.MAX_PAGES else {
        throw MetadataApiError.invalidPagination("Exceeded max page count (\(Self.MAX_PAGES)); aborting")
      }
      offset = all.count
    }
    return all
  }

  private func getMetadataPage(filters: [MetadataFilter], offset: Int) async throws -> MetadataPage {
    var query = [URLQueryItem(name: "key", value: IMMICH_DEVICE_ID)]
    query += filters.map { URLQueryItem(name: "filter", value: "\($0.field):\($0.value)") }
    query.append(URLQueryItem(name: "limit", value: String(Self.PAGE_SIZE)))
    query.append(URLQueryItem(name: "offset", value: String(offset)))
    let body = try await execute(path: "/metadata", query: query)
    return try Self.decoder.decode(MetadataPage.self, from: Data(body.readableBytesView))
  }

  private func execute(path: String, query: [URLQueryItem]) async throws -> ByteBuffer {
    let urlString = try Self.makeURL(base: baseURLString, path: path, query: query)
    var request = HTTPClientRequest(url: urlString)
    request.headers.add(name: "x-api-key", value: apiKey)
    let deadline: NIODeadline = requestTimeout.map { .now() + $0 } ?? .distantFuture
    return try await limiter.withSlot {
      let response = try await self.executor(request, deadline)
      let status = Int(response.status.code)
      let body = try await response.body.collect(upTo: Self.MAX_BODY)
      guard (200..<300).contains(status) else {
        throw MetadataApiError.unknown(statusCode: status, body: String(buffer: body))
      }
      return body
    }
  }

  static func makeURL(base: String, path: String, query: [URLQueryItem]) throws -> String {
    guard var components = URLComponents(string: base + path) else {
      throw MetadataApiError.invalidServerURL(base + path)
    }
    if !query.isEmpty {
      components.percentEncodedQueryItems = query.map {
        URLQueryItem(
          name: $0.name,
          value: $0.value?.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed))
      }
    }
    guard let url = components.string else {
      throw MetadataApiError.invalidServerURL(base + path)
    }
    return url
  }

  // MARK: - Retry

  private func withRetry<T>(_ operation: String, _ work: () async throws -> T) async throws -> T {
    try await RetryPolicy.withRetry(
      operation, label: "Metadata API", attempts: retryAttempts, log: Self.log,
      sleep: backoffSleep, work)
  }
}
