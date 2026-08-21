import AsyncHTTPClient
import Foundation
import NIOHTTP2
import OpenAPIRuntime

// Retriable low-level transport errors
private let RETRYABLE_HTTP_CLIENT_ERRORS: [HTTPClientError] = [.deadlineExceeded, .readTimeout, .writeTimeout]
private let RETRYABLE_HTTP2_ERROR_CODES: [HTTP2ErrorCode] = [
  .cancel, .refusedStream, .enhanceYourCalm, .internalError, .connectError,
]

/// Shared HTTP retry machinery for the Immich and metadata API clients
enum RetryPolicy {
  /// Whether a failed API call is worth retrying. Transient transport failures, rate
  /// limiting (429), and server errors (5xx, status 0) are retryable; cancellation,
  /// decoding failures, pagination faults, and other 4xx responses are not.
  static func isRetryable(_ error: Error) -> Bool {
    var error = error
    // Unwrap OpenAPI Client Errors into their underlying error.
    while let clientError = error as? ClientError {
      error = clientError.underlyingError
    }
    if error is CancellationError { return false }
    if error is DecodingError { return false }
    if error is TimeoutError { return true }
    if let httpErr = error as? HTTPClientError, RETRYABLE_HTTP_CLIENT_ERRORS.contains(httpErr) { return true }
    if let streamClosed = error as? NIOHTTP2Errors.StreamClosed,
      RETRYABLE_HTTP2_ERROR_CODES.contains(streamClosed.errorCode)
    {
      return true
    }
    if let status = unknownResponseStatus(error) {
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

  private static func unknownResponseStatus(_ error: Error) -> Int? {
    unknownResponse(error)?.status
  }

  private static func unknownResponse(_ error: Error) -> (status: Int, body: String)? {
    if let immich = error as? ImmichApiError, case .unknown(let status, let body) = immich {
      return (status, body)
    }
    if let metadata = error as? MetadataApiError, case .unknown(let status, let body) = metadata {
      return (status, body)
    }
    return nil
  }

  private static func logFinalFailure(_ operation: String, error: Error, log: CategoryLog) {
    if error is CancellationError || Task.isCancelled {
      log.debug("\(operation) cancelled")
      return
    }
    if let (status, body) = unknownResponse(error) {
      log.error("Error response from \(operation): \(status) - \(body)")
    } else {
      log.error("Error from \(operation).", cause: error)
    }
  }

  /// Runs `work` up to `attempts` times, sleeping `min(attempt, 5)` seconds between
  /// retryable failures. `label` names the API in retry log lines; the final failure
  /// is logged to `log` once before the error is rethrown.
  static func withRetry<T>(
    _ operation: String,
    label: String,
    attempts: Int,
    log: CategoryLog,
    sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    _ work: () async throws -> T
  ) async throws -> T {
    for attempt in 1...attempts {
      do {
        return try await work()
      } catch {
        if !isRetryable(error) || attempt == attempts {
          logFinalFailure(operation, error: error, log: log)
          throw error
        }
        let waitSeconds = min(attempt, 5)
        log.info(
          "\(label) attempt \(attempt)/\(attempts) failed for \(operation); retrying after ~\(waitSeconds) seconds",
          cause: error
        )
        try await sleep(.seconds(waitSeconds))
      }
    }
    preconditionFailure("unreachable: RetryPolicy.withRetry")
  }
}
