import AsyncHTTPClient
import Foundation
import NIOHTTP2
import OpenAPIRuntime
import Testing

@testable import PhotosImmichSyncCore

private struct RandomError: Error {}

private func decodingError() -> Error {
  DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
}

@Suite struct RetryPolicyTests {
  @Test func retriesTransportFailures() {
    #expect(RetryPolicy.isRetryable(TimeoutError.timeout))
    #expect(RetryPolicy.isRetryable(HTTPClientError.deadlineExceeded))
    #expect(RetryPolicy.isRetryable(HTTPClientError.readTimeout))
    #expect(RetryPolicy.isRetryable(HTTPClientError.writeTimeout))
    #expect(RetryPolicy.isRetryable(URLError(.timedOut)))
    #expect(RetryPolicy.isRetryable(URLError(.notConnectedToInternet)))
    #expect(RetryPolicy.isRetryable(URLError(.networkConnectionLost)))
    #expect(RetryPolicy.isRetryable(URLError(.cannotConnectToHost)))
    #expect(RetryPolicy.isRetryable(URLError(.cannotFindHost)))
    #expect(RetryPolicy.isRetryable(URLError(.dnsLookupFailed)))
  }

  @Test func retriesRetryableHTTP2StreamResets() {
    #expect(RetryPolicy.isRetryable(NIOHTTP2Errors.streamClosed(streamID: 1, errorCode: .cancel)))
    #expect(RetryPolicy.isRetryable(NIOHTTP2Errors.streamClosed(streamID: 1, errorCode: .refusedStream)))
    #expect(RetryPolicy.isRetryable(NIOHTTP2Errors.streamClosed(streamID: 1, errorCode: .enhanceYourCalm)))
    #expect(!RetryPolicy.isRetryable(NIOHTTP2Errors.streamClosed(streamID: 1, errorCode: .protocolError)))
  }

  @Test func retriesRateLimitAndServerStatusesFromBothClients() {
    for status in [0, 429, 500, 503] {
      #expect(RetryPolicy.isRetryable(ImmichApiError.unknown(statusCode: status, body: "")), "immich \(status)")
      #expect(RetryPolicy.isRetryable(MetadataApiError.unknown(statusCode: status, body: "")), "metadata \(status)")
    }
  }

  @Test func doesNotRetryClientSideOrPermanentFailures() {
    #expect(!RetryPolicy.isRetryable(CancellationError()))
    #expect(!RetryPolicy.isRetryable(decodingError()))
    #expect(!RetryPolicy.isRetryable(ImmichApiError.unknown(statusCode: 400, body: "")))
    #expect(!RetryPolicy.isRetryable(ImmichApiError.unknown(statusCode: 404, body: "")))
    #expect(!RetryPolicy.isRetryable(MetadataApiError.unknown(statusCode: 404, body: "")))
    #expect(!RetryPolicy.isRetryable(ImmichApiError.invalidPagination(reason: "x")))
    #expect(!RetryPolicy.isRetryable(MetadataApiError.invalidPagination("stuck page")))
    #expect(!RetryPolicy.isRetryable(URLError(.badURL)))
    #expect(!RetryPolicy.isRetryable(HTTPClientError.remoteConnectionClosed))
    #expect(!RetryPolicy.isRetryable(RandomError()))
  }

  @Test func unwrapsNestedOpenAPIClientErrors() {
    func wrap(_ error: Error) -> ClientError {
      ClientError(
        operationID: "op", operationInput: "input",
        causeDescription: "test", underlyingError: error)
    }
    #expect(RetryPolicy.isRetryable(wrap(TimeoutError.timeout)))
    #expect(RetryPolicy.isRetryable(wrap(wrap(TimeoutError.timeout))))
    #expect(!RetryPolicy.isRetryable(wrap(decodingError())))
  }

  @Test func loopRetriesUntilSuccess() async throws {
    let log = Log.forCategory("RetryPolicyTests")

    // Succeeds on the third attempt after two retryable failures.
    var attempts = 0
    let result = try await RetryPolicy.withRetry(
      "op", label: "Test API", attempts: 3, log: log, sleep: { _ in }
    ) {
      attempts += 1
      if attempts < 3 { throw ImmichApiError.unknown(statusCode: 503, body: "") }
      return "ok"
    }
    #expect(result == "ok")
    #expect(attempts == 3)
  }

  @Test func loopStopsImmediatelyOnNonRetryableFailure() async {
    let log = Log.forCategory("RetryPolicyTests")
    var attempts = 0
    await #expect(throws: ImmichApiError.self) {
      try await RetryPolicy.withRetry(
        "op", label: "Test API", attempts: 5, log: log, sleep: { _ in }
      ) {
        attempts += 1
        throw ImmichApiError.unknown(statusCode: 404, body: "")
      } as Never
    }
    #expect(attempts == 1)
  }

  @Test func loopExhaustsAttemptsOnPersistentRetryableFailure() async {
    let log = Log.forCategory("RetryPolicyTests")
    var attempts = 0
    await #expect(throws: ImmichApiError.self) {
      try await RetryPolicy.withRetry(
        "op", label: "Test API", attempts: 3, log: log, sleep: { _ in }
      ) {
        attempts += 1
        throw ImmichApiError.unknown(statusCode: 500, body: "")
      } as Never
    }
    #expect(attempts == 3)
  }
}
