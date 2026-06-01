import ArgumentParser
import AsyncHTTPClient
import Foundation
import HTTPTypes
import NIOCore
import NIOHTTP2
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime
import OpenAPIURLSession
import Photos


let DATE_FMT = Date.ISO8601FormatStyle()
let DATE_FMT_WITH_FRACTIONAL_SECONDS = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
let PERMISSIONS_CORE: Set<Components.Schemas.Permission> = [
  .asset_read,
  .asset_update,
  .asset_delete,
  .asset_upload,
  .asset_copy,
  .stack_create
]
let PERMISSIONS_ALBUMS: Set<Components.Schemas.Permission> = [
  .album_create,
  .album_read,
  .album_update,
  .album_delete,
  .albumAsset_create,
  .albumAsset_delete
]
let PERMISSIONS_TAGS: Set<Components.Schemas.Permission> = [
  .tag_create,
  .tag_read,
  .tag_update,
  .tag_delete,
  .tag_asset
]

enum ImmichPermissionError: Error {
  case missingPermissions(Set<Components.Schemas.Permission>)
}

public enum ImmichApiError: Error {
  case unknown(statusCode: Int, body: String)
  case invalidPagination(reason: String)
}

public enum ImmichConfigError: Error {
  case invalidServerURL(String)
}

private struct ApiKeyMiddleware: ClientMiddleware {
  private let apiKey: String
  private let headerKey = HTTPField.Name.init("X-Api-Key")!
  init(apiKey: String) {
    self.apiKey = apiKey
  }

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next:
      @concurrent (HTTPRequest, HTTPBody?, URL) async throws -> (
        HTTPResponse, HTTPBody?
      )
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var request = request
    request.headerFields[headerKey] = apiKey
    return try await next(request, body, baseURL)
  }
}

// This custom transcoder tries to decode dates with fractional second first,
// Then fall back to trying without fractional seconds.
private struct CustomDateTranscoder: DateTranscoder {
  public func encode(_ date: Date) throws -> String {
    return DATE_FMT_WITH_FRACTIONAL_SECONDS.format(date)
  }

  public func decode(_ dateString: String) throws -> Date {
    do {
      return try DATE_FMT_WITH_FRACTIONAL_SECONDS.parse(dateString)
    } catch {
      do {
        return try DATE_FMT.parse(dateString)
      } catch {
        throw DecodingError.dataCorrupted(
          .init(codingPath: [], debugDescription: "Expected date string '\(dateString)' to be ISO8601-formatted.")
        )
      }
    }
  }
}

private struct ConcurrencyLimitMiddleware: ClientMiddleware {
  let limiter: AsyncSemaphore

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next: @concurrent (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    try await limiter.acquire()
    do {
      let result = try await next(request, body, baseURL)
      await limiter.release()
      return result
    } catch {
      await limiter.release()
      throw error
    }
  }
}

/// Converts a Swift `Duration` into a NIO `TimeAmount`, saturating at `Int64.max`
/// nanoseconds so that an absurdly large timeout cannot overflow.
private func timeAmount(from duration: Duration) -> TimeAmount {
  let (seconds, attoseconds) = duration.components
  let nanosFromAtto = attoseconds / 1_000_000_000
  let (mul, mulOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
  if mulOverflow { return .nanoseconds(.max) }
  let (sum, sumOverflow) = mul.addingReportingOverflow(nanosFromAtto)
  if sumOverflow { return .nanoseconds(.max) }
  return .nanoseconds(sum)
}

// Retriable Http Error Codes
private let RETRYABLE_HTTP_CLIENT_ERRORS: [HTTPClientError] = [.deadlineExceeded, .readTimeout, .writeTimeout]
private let RETRYABLE_HTTP2_ERROR_CODES: [HTTP2ErrorCode] = [
  .cancel, .refusedStream, .enhanceYourCalm, .internalError, .connectError,
]

final public class ImmichApiClient: Sendable {
  let SEARCH_MAX_SIZE: Double = 1_000
  let SEARCH_MAX_PAGES: Int = 10_000

  private static let log = Log.forCategory("ImmichAPI")
  private let client: Client
  private let httpClient: HTTPClient
  private let retryAttempts: Int

  init(_ config: ImmichApiConfig) throws {
    let trimmed = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let baseURL = URL(string: trimmed),
      let scheme = baseURL.scheme,
      scheme == "http" || scheme == "https",
      baseURL.host != nil
    else {
      throw ImmichConfigError.invalidServerURL(config.url)
    }
    retryAttempts = max(1, config.retryAttempts)

    var httpConfig = HTTPClient.Configuration.singletonConfiguration
    httpConfig.timeout.connect = timeAmount(from: config.connectTimeout)
    let idleTimeout = config.connectionIdleTimeout.map { timeAmount(from: $0) }
    httpConfig.timeout.read = idleTimeout
    httpConfig.timeout.write = idleTimeout
    httpConfig.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = max(1, config.maxConcurrentRequests)
    let httpClient = HTTPClient(
      eventLoopGroup: HTTPClient.defaultEventLoopGroup,
      configuration: httpConfig
    )
    self.httpClient = httpClient

    let limiter = AsyncSemaphore(maxConcurrentTasks: max(1, config.maxConcurrentRequests))
    let deadline = config.requestTimeout.map { timeAmount(from: $0) } ?? .nanoseconds(.max)
    let transportConfig = AsyncHTTPClientTransport.Configuration(
      client: httpClient,
      timeout: deadline
    )
    self.client = Client(
      serverURL: baseURL,
      configuration: .init(dateTranscoder: CustomDateTranscoder()),
      transport: AsyncHTTPClientTransport(configuration: transportConfig),
      middlewares: [
        ConcurrencyLimitMiddleware(limiter: limiter),
        ApiKeyMiddleware(apiKey: config.apiKey),
      ]
    )
  }

  func shutdown() async {
    do {
      try await httpClient.shutdown().get()
    } catch {
      Self.log.warning("HTTP client shutdown failed", cause: error)
    }
  }

  private func undocumentedToError(status: Int, result: UndocumentedPayload) async throws -> ImmichApiError {
    var bodyStr = ""
    if let body = result.body {
      bodyStr = try await String(collecting: body, upTo: 2 * 1024 * 1024)
    }
    return ImmichApiError.unknown(statusCode: status, body: bodyStr)
  }

  private func logFinalFailure(_ operation: String, error: Error) {
    if error is CancellationError || Task.isCancelled {
      Self.log.debug("\(operation) cancelled")
      return
    }
    if let immich = error as? ImmichApiError, case .unknown(let status, let body) = immich {
      Self.log.error("Error response from \(operation): \(status) - \(body)")
    } else {
      Self.log.error("Error from \(operation).", cause: error)
    }
  }

  private func canRetryAfterClientFailure(_ error: Error) -> Bool {
    if error is TimeoutError { return true }
    if let httpErr = error as? HTTPClientError, RETRYABLE_HTTP_CLIENT_ERRORS.contains(httpErr) { return true }
    if let streamClosed = error as? NIOHTTP2Errors.StreamClosed, 
      RETRYABLE_HTTP2_ERROR_CODES.contains(streamClosed.errorCode)
    {
      return true
    }
    if error is CancellationError { return false }
    if error is DecodingError { return false }
    if let immich = error as? ImmichApiError, case .unknown(let status, _) = immich {
      if status == 0 { return true }
      if status == 429 { return true }
      if status >= 500 && status < 600 { return true }
      return false
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
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
      switch ns.code {
      case NSURLErrorTimedOut,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed:
        return true
      default:
        return false
      }
    }
    return false
  }

  private func withClientRetry<T>(_ operation: String, _ work: @escaping () async throws -> T) async throws -> T {
    for attempt in 1...self.retryAttempts {
      do {
        return try await work()
      } catch {
        if !canRetryAfterClientFailure(error) || attempt == self.retryAttempts {
          logFinalFailure(operation, error: error)
          throw error
        }
        let waitSeconds = min(attempt, 5)
        let backoff = Duration.seconds(waitSeconds)
        Self.log.info(
          "Immich API attempt \(attempt)/\(self.retryAttempts) failed for \(operation); retrying after ~\(waitSeconds) seconds",
          cause: error
        )
        do {
          try await Task.sleep(for: backoff)
        } catch {
          throw error
        }
      }
    }
    preconditionFailure("unreachable: withClientRetry")
  }

  func validateApiKey(config: ImmichConfig) async throws {
    try await withClientRetry(#function) {
      let response = try await self.client.getMyApiKey()
      switch response {
      case .ok(let okResponse):
        if case .json(let payload) = okResponse.body {
          let permissionSet = Set(payload.permissions)
          if !PERMISSIONS_CORE.isSubset(of: permissionSet) {
            let missing = PERMISSIONS_CORE.subtracting(permissionSet)
            Self.log.error("Missing Core permissions: \(missing.map(\.rawValue))")
            throw ImmichPermissionError.missingPermissions(missing)
          }
          if !PERMISSIONS_ALBUMS.isSubset(of: permissionSet) && config.albums.enabled {
            let missing = PERMISSIONS_ALBUMS.subtracting(permissionSet)
            Self.log.error("Album sync enabled, but missing permissions: \(missing.map(\.rawValue))")
            throw ImmichPermissionError.missingPermissions(missing)
          }
          if !PERMISSIONS_TAGS.isSubset(of: permissionSet) && config.tags.enabled {
            let missing = PERMISSIONS_TAGS.subtracting(permissionSet)
            Self.log.error("Tag sync enabled, but missing permissions: \(missing.map(\.rawValue))")
            throw ImmichPermissionError.missingPermissions(missing)
          }
        } else {
          Self.log.error("Failed to parse API Key response.")
          throw ImmichPermissionError.missingPermissions(PERMISSIONS_CORE)
        }
        return
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  public func checkServerVersion() async throws {
    try await withClientRetry(#function) {
      let response = try await self.client.getServerVersion()
      switch response {
      case .ok(let okResponse):
        if case .json(let payload) = okResponse.body {
          Self.log.progress("Successfully connected to Immich Server: \(payload.major).\(payload.minor).\(payload.patch)")
        } else {
          Self.log.progress("Successfully connected to Immich Server, but unable to parse Server Info Response.")
        }
        return
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  // MARK: Asset APIs

  func getAsset(id: String) async throws -> Components.Schemas.AssetResponseDto {
    return try await withClientRetry(#function) {
      let response = try await self.client.getAssetInfo(Operations.GetAssetInfo.Input(path: .init(id: id)))
      switch response {
      case .ok(let okResponse):
        switch okResponse.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  /* Permission: asset.upload */
  public func checkExistingAssets(_ deviceAssetIds: [String]) async throws -> [String] {
    return try await withClientRetry(#function) {
      // The OpenAPI generator often hides Body initializers; use the operation input instead
      let input = Operations.CheckExistingAssets.Input(
        body: .json(
          .init(deviceAssetIds: deviceAssetIds, deviceId: IMMICH_DEVICE_ID)
        )
      )
      let response = try await self.client.checkExistingAssets(input)
      switch response {
      case .ok(let okResponse):
        switch okResponse.body {
        case .json(let payload):
          return payload.existingIds
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func bulkUploadCheck(_ items: [Components.Schemas.AssetBulkUploadCheckItem]) async throws -> [String: Components
    .Schemas.AssetBulkUploadCheckResult]
  {
    return try await withClientRetry(#function) {
      let input = Operations.CheckBulkUpload.Input(
        body: .json(Components.Schemas.AssetBulkUploadCheckDto.init(assets: items))
      )
      let response = try await self.client.checkBulkUpload(input)
      switch response {
      case .ok(let okResult):
        switch okResult.body {
        case .json(let payload):
          return Dictionary(payload.results.map { ($0.id, $0) }) { existing, _ in
            Self.log.warning(
              "bulkUploadCheck: duplicate result id \(existing.id); keeping first"
            )
            return existing
          }
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func uploadAsset(_ data: [Components.Schemas.AssetMediaCreateDto]) async throws
    -> Components.Schemas.AssetMediaResponseDto
  {
    return try await withClientRetry(#function) {
      let body: MultipartBody<Components.Schemas.AssetMediaCreateDto> = .init(data)
      let input = Operations.UploadAsset.Input(
        body: .multipartForm(body)
      )
      let response = try await self.client.uploadAsset(input)
      switch response {
      case .ok(let okResult):
        switch okResult.body {
        case .json(let payload):
          return payload
        }
      case .created(let createdResult):
        switch createdResult.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func updateAssetInfo(id: String, data: Components.Schemas.UpdateAssetDto) async throws
    -> Components.Schemas.AssetResponseDto
  {
    return try await withClientRetry(#function) {
      let input = Operations.UpdateAsset.Input(
        path: Operations.UpdateAsset.Input.Path(id: id),
        body: .json(data)
      )
      let response = try await self.client.updateAsset(input)
      switch response {
      case .ok(let okResult):
        switch okResult.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func updateAssetMetadata(id: String, data: [Components.Schemas.AssetMetadataUpsertItemDto]) async throws -> [Components.Schemas.AssetMetadataResponseDto] {
    try await withClientRetry(#function) {
      let body = Components.Schemas.AssetMetadataUpsertDto(items: data)
      let response = try await self.client.updateAssetMetadata(.init(path: .init(id: id), body: .json(body)))
      switch response {
      case .ok(let result):
        switch result.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func copyAsset(sourceId: String, targetId: String, copyFavorite: Bool = false) async throws {
    try await withClientRetry(#function) {
      let body = Components.Schemas.AssetCopyDto.init(
        albums: true,
        favorite: copyFavorite,
        sharedLinks: true,
        sidecar: nil,
        sourceId: sourceId,
        stack: true,
        targetId: targetId,
      )
      let response = try await self.client.copyAsset(Operations.CopyAsset.Input(body: .json(body)))
      switch response {
      case .noContent:
        return
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func deleteAsset(_ id: String, force: Bool) async throws {
    return try await deleteAssets([id], force: force)
  }

  func deleteAssets(_ ids: [String], force: Bool) async throws {
    try await withClientRetry(#function) {
      let body = Components.Schemas.AssetBulkDeleteDto.init(force: force, ids: ids)
      let response = try await self.client.deleteAssets(Operations.DeleteAssets.Input(body: .json(body)))
      if case .undocumented(let status, let result) = response {
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  // MARK: Stack APIs

  func stackAssets(ids: [String]) async throws -> Components.Schemas.StackResponseDto? {
    return try await withClientRetry(#function) {
      let body = Components.Schemas.StackCreateDto(assetIds: ids)
      let response = try await self.client.createStack(Operations.CreateStack.Input(body: .json(body)))
      switch response {
      case .created(let createdResult):
        switch createdResult.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func getStack(_ id: String) async throws -> Components.Schemas.StackResponseDto {
    return try await withClientRetry(#function) {
      let response = try await self.client.getStack(Operations.GetStack.Input(path: .init(id: id)))
      switch response {
      case .ok(let okResult):
        switch okResult.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func deleteStack(_ id: String) async throws {
    try await withClientRetry(#function) {
      let response = try await self.client.deleteStack(Operations.DeleteStack.Input(path: .init(id: id)))
      switch response {
      case .noContent(_):
        return
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func deleteStacks(_ ids: [String]) async throws {
    try await withClientRetry(#function) {
      let response = try await self.client.deleteStacks(body: .json(.init(ids: ids)))
      switch response {
      case .noContent(_):
        return
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  // MARK: Search APIs

  internal func execSearchAssets(_ dto: Components.Schemas.MetadataSearchDto) async throws
    -> Components.Schemas.SearchResponseDto
  {
    return try await withClientRetry(#function) {
      let response = try await self.client.searchAssets(Operations.SearchAssets.Input(body: .json(dto)))
      switch response {
      case .ok(let okResult):
        switch okResult.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func searchByDeviceAssetId(_ id: String) async throws -> Components.Schemas.AssetResponseDto? {
    let dto = Components.Schemas.MetadataSearchDto.init(deviceAssetId: id, deviceId: IMMICH_DEVICE_ID)
    let response = try await execSearchAssets(dto)
    return response.assets.items.first
  }

  func searchAssets(_ originalDto: Components.Schemas.MetadataSearchDto) async throws -> [Components.Schemas
    .AssetResponseDto]
  {
    var items: [Components.Schemas.AssetResponseDto] = []
    var pagesFetched = 1
    var previousPage: Double = 1

    var dto = originalDto
    dto.size = SEARCH_MAX_SIZE
    dto.page = previousPage

    var result = try await execSearchAssets(dto)
    items.append(contentsOf: result.assets.items)

    while let nextPage = result.assets.nextPage {
      guard let nextPageValue = Double(nextPage) else {
        throw ImmichApiError.invalidPagination(
          reason: "Server returned non-numeric nextPage token \"\(nextPage)\"")
      }
      guard nextPageValue > previousPage else {
        throw ImmichApiError.invalidPagination(
          reason: "Server returned non-advancing nextPage \(nextPageValue) after page \(previousPage)")
      }
      pagesFetched += 1
      guard pagesFetched <= SEARCH_MAX_PAGES else {
        throw ImmichApiError.invalidPagination(
          reason: "Pagination exceeded max page count (\(SEARCH_MAX_PAGES)); aborting")
      }
      dto.page = nextPageValue
      previousPage = nextPageValue
      result = try await execSearchAssets(dto)
      items.append(contentsOf: result.assets.items)
    }
    return items
  }

  // MARK: Album APIs

  func createAlbum(_ name: String, assetIds: [String] = [], description: String? = nil) async throws -> String {
    return try await withClientRetry(#function) {
      let dto = Components.Schemas.CreateAlbumDto(albumName: name, assetIds: assetIds, description: description)
      let response = try await self.client.createAlbum(Operations.CreateAlbum.Input(body: .json(dto)))
      switch response {
      case .created(let okResult):
        switch okResult.body {
        case .json(let payload):
          return payload.id
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func getAlbum(_ id: String) async throws -> Components.Schemas.AlbumResponseDto {
    return try await withClientRetry(#function) {
      let response = try await self.client.getAlbumInfo(.init(path: .init(id: id)))
      switch response {
      case .ok(let result):
        switch result.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func listAlbums() async throws -> [Components.Schemas.AlbumResponseDto] {
    return try await withClientRetry(#function) {
      let response = try await self.client.getAllAlbums()
      switch response {
      case .ok(let result):
        switch result.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func deleteAlbum(_ id: String) async throws {
    try await withClientRetry(#function) {
      let input = Operations.DeleteAlbum.Input(path: .init(id: id))
      let response = try await self.client.deleteAlbum(input)
      if case .undocumented(let status, let result) = response {
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func addAssetsToAlbum(_ id: String, assetIds: [String]) async throws -> [Components.Schemas.BulkIdResponseDto] {
    return try await withClientRetry(#function) {
      let dto = Components.Schemas.BulkIdsDto(ids: assetIds)
      let input = Operations.AddAssetsToAlbum.Input(path: .init(id: id), body: .json(dto))
      let response = try await self.client.addAssetsToAlbum(input)
      switch response {
      case .ok(let result):
        switch result.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func removeAssetsFromAlbum(_ id: String, assetIds: [String]) async throws -> [Components.Schemas.BulkIdResponseDto] {
    return try await withClientRetry(#function) {
      let dto = Components.Schemas.BulkIdsDto(ids: assetIds)
      let input = Operations.RemoveAssetFromAlbum.Input(path: .init(id: id), body: .json(dto))
      let response = try await self.client.removeAssetFromAlbum(input)
      switch response {
      case .ok(let result):
        switch result.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func updateAlbum(_ id: String, dto: Components.Schemas.UpdateAlbumDto) async throws -> Components.Schemas.AlbumResponseDto {
    return try await withClientRetry(#function) {
      let response = try await self.client.updateAlbumInfo(path: .init(id: id), body: .json(dto))
      switch response {
      case .ok(let result):
        switch result.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  // MARK: Tag APIs

  func getAllTags() async throws -> [Components.Schemas.TagResponseDto] {
    return try await withClientRetry(#function) {
      let response = try await self.client.getAllTags()
      switch response {
      case .ok(let okResult):
        switch okResult.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func upsertTags(tags: [String]) async throws -> [Components.Schemas.TagResponseDto] {
    return try await withClientRetry(#function) {
      let dto = Components.Schemas.TagUpsertDto(tags: tags)
      let response = try await self.client.upsertTags(Operations.UpsertTags.Input(body: .json(dto)))
      switch response {
      case .ok(let okResult):
        switch okResult.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func tagAssets(tagId: String, assetIds: [String]) async throws -> [Components.Schemas.BulkIdResponseDto] {
    return try await withClientRetry(#function) {
      let input = Operations.TagAssets.Input(
        path: .init(id: tagId),
        body: .json(.init(ids: assetIds))
      )
      let response = try await self.client.tagAssets(input)
      switch response {
      case .ok(let okResult):
        switch okResult.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func untagAssets(tagId: String, assetIds: [String]) async throws -> [Components.Schemas.BulkIdResponseDto] {
    return try await withClientRetry(#function) {
      let input = Operations.UntagAssets.Input(
        path: .init(id: tagId),
        body: .json(.init(ids: assetIds))
      )
      let response = try await self.client.untagAssets(input)
      switch response {
      case .ok(let okResult):
        switch okResult.body {
        case .json(let payload):
          return payload
        }
      case .undocumented(let status, let result):
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func deleteTag(_ id: String) async throws {
    try await withClientRetry(#function) {
      let input = Operations.DeleteTag.Input(path: .init(id: id))
      let response = try await self.client.deleteTag(input)
      if case .undocumented(let status, let result) = response {
        throw try await self.undocumentedToError(status: status, result: result)
      }
    }
  }

  func generateAlbumTag(_ value: String) -> String {
    return "#\(APP_NAME):\(value)#"
  }

  func extractAlbumTagValue(_ tag: String) -> String? {
    if let match = tag.firstMatch(of: /#photos-immich-sync:(.+?)#/) {
      return "\(match.1)"
    }
    return nil
  }
}
