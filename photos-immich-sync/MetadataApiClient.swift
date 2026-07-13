import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
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
    return phAssetLocalIdentifier == bundle.asset.localIdentifier
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

// Retriable low-level transport errors
private let RETRYABLE_HTTP_CLIENT_ERRORS: [HTTPClientError] = [.deadlineExceeded, .readTimeout, .writeTimeout]

// Global Mutable State, retained for the process lifetime so the HTTPClient is never
// shut down or deinited.
private let retainedMetadataHTTPClients = NIOLockedValueBox<[HTTPClient]>([])

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

  private let baseURLString: String
  private let apiKey: String
  private let httpClient: HTTPClient
  private let limiter: AsyncSemaphore
  private let requestTimeout: TimeAmount?
  private let retryAttempts: Int

  init(_ config: ImmichApiConfig) throws {
    let trimmed = config.metadataApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let baseURL = URL(string: trimmed),
      let scheme = baseURL.scheme,
      scheme == "http" || scheme == "https",
      baseURL.host != nil
    else {
      throw MetadataApiError.invalidServerURL(config.metadataApiUrl)
    }
    // Normalize away trailing slashes so paths join cleanly
    var normalized = trimmed
    while normalized.hasSuffix("/") { normalized.removeLast() }
    self.baseURLString = normalized
    self.apiKey = config.apiKey
    self.retryAttempts = max(1, config.retryAttempts)

    var httpConfig = HTTPClient.Configuration.singletonConfiguration
    httpConfig.timeout.connect = config.connectTimeout.toTimeAmount()
    let idleTimeout = config.connectionIdleTimeout.map({ $0.toTimeAmount() })
    httpConfig.timeout.read = idleTimeout
    httpConfig.timeout.write = idleTimeout
    httpConfig.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = max(1, config.maxConcurrentRequests)
    let httpClient = HTTPClient(
      eventLoopGroup: HTTPClient.defaultEventLoopGroup,
      configuration: httpConfig
    )
    retainedMetadataHTTPClients.withLockedValue { $0.append(httpClient) }
    self.httpClient = httpClient

    self.limiter = AsyncSemaphore(maxConcurrentTasks: max(1, config.maxConcurrentRequests))
    self.requestTimeout = config.requestTimeout.map({ $0.toTimeAmount() })
  }

  // MARK: - Public API

  func checkHealth() async -> Bool {
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
    let urlString = try makeURL(path: path, query: query)
    var request = HTTPClientRequest(url: urlString)
    request.headers.add(name: "x-api-key", value: apiKey)
    let deadline: NIODeadline = requestTimeout.map { .now() + $0 } ?? .distantFuture
    return try await limiter.withSlot {
      let response = try await self.httpClient.execute(request, deadline: deadline)
      let status = Int(response.status.code)
      let body = try await response.body.collect(upTo: Self.MAX_BODY)
      guard (200..<300).contains(status) else {
        throw MetadataApiError.unknown(statusCode: status, body: String(buffer: body))
      }
      return body
    }
  }

  private func makeURL(path: String, query: [URLQueryItem]) throws -> String {
    guard var components = URLComponents(string: baseURLString + path) else {
      throw MetadataApiError.invalidServerURL(baseURLString + path)
    }
    if !query.isEmpty {
      components.percentEncodedQueryItems = query.map {
        URLQueryItem(
          name: $0.name,
          value: $0.value?.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed))
      }
    }
    guard let url = components.string else {
      throw MetadataApiError.invalidServerURL(baseURLString + path)
    }
    return url
  }

  // MARK: - Retry

  private func withRetry<T>(_ operation: String, _ work: @escaping () async throws -> T) async throws -> T {
    for attempt in 1...retryAttempts {
      do {
        return try await work()
      } catch {
        if !Self.canRetry(error) || attempt == retryAttempts {
          logFinalFailure(operation, error: error)
          throw error
        }
        let waitSeconds = min(attempt, 5)
        Self.log.info(
          "Metadata API attempt \(attempt)/\(retryAttempts) failed for \(operation); retrying after ~\(waitSeconds) seconds",
          cause: error
        )
        try await Task.sleep(for: .seconds(waitSeconds))
      }
    }
    preconditionFailure("unreachable: withRetry")
  }

  private static func canRetry(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if error is DecodingError { return false }
    if case MetadataApiError.invalidPagination = error { return false }
    if error is TimeoutError { return true }
    if let httpErr = error as? HTTPClientError, RETRYABLE_HTTP_CLIENT_ERRORS.contains(httpErr) { return true }
    if let apiErr = error as? MetadataApiError, case .unknown(let status, _) = apiErr {
      return status == 0 || status == 429 || (500..<600).contains(status)
    }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed:
        return true
      default:
        return false
      }
    }
    return false
  }

  private func logFinalFailure(_ operation: String, error: Error) {
    if error is CancellationError || Task.isCancelled {
      Self.log.debug("\(operation) cancelled")
      return
    }
    if let apiErr = error as? MetadataApiError, case .unknown(let status, let body) = apiErr {
      Self.log.error("Error response from \(operation): \(status) - \(body)")
    } else {
      Self.log.error("Error from \(operation).", cause: error)
    }
  }
}
