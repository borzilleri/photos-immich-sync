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

@Suite struct RetryClassificationTests {
  // MARK: ImmichApiClient.canRetryAfterClientFailure

  @Test func immichRetriesTransportAndServerFailures() {
    let retry = ImmichApiClient.canRetryAfterClientFailure
    #expect(retry(TimeoutError.timeout))
    #expect(retry(HTTPClientError.deadlineExceeded))
    #expect(retry(HTTPClientError.readTimeout))
    #expect(retry(HTTPClientError.writeTimeout))
    #expect(retry(ImmichApiError.unknown(statusCode: 0, body: "")))
    #expect(retry(ImmichApiError.unknown(statusCode: 429, body: "")))
    #expect(retry(ImmichApiError.unknown(statusCode: 500, body: "")))
    #expect(retry(ImmichApiError.unknown(statusCode: 503, body: "")))
    #expect(retry(URLError(.timedOut)))
    #expect(retry(URLError(.dnsLookupFailed)))
    #expect(retry(URLError(.cannotFindHost)))
  }

  @Test func immichDoesNotRetryClientSideOrPermanentFailures() {
    let retry = ImmichApiClient.canRetryAfterClientFailure
    #expect(!retry(CancellationError()))
    #expect(!retry(decodingError()))
    #expect(!retry(ImmichApiError.unknown(statusCode: 400, body: "")))
    #expect(!retry(ImmichApiError.unknown(statusCode: 404, body: "")))
    #expect(!retry(ImmichApiError.invalidPagination(reason: "x")))
    #expect(!retry(URLError(.badURL)))
    #expect(!retry(HTTPClientError.remoteConnectionClosed))
    #expect(!retry(RandomError()))
  }

  @Test func immichRetriesRetryableHTTP2StreamResets() {
    let retry = ImmichApiClient.canRetryAfterClientFailure
    #expect(retry(NIOHTTP2Errors.streamClosed(streamID: 1, errorCode: .cancel)))
    #expect(retry(NIOHTTP2Errors.streamClosed(streamID: 1, errorCode: .refusedStream)))
    #expect(retry(NIOHTTP2Errors.streamClosed(streamID: 1, errorCode: .enhanceYourCalm)))
    #expect(!retry(NIOHTTP2Errors.streamClosed(streamID: 1, errorCode: .protocolError)))
  }

  @Test func immichUnwrapsNestedOpenAPIClientErrors() {
    func wrap(_ error: Error) -> ClientError {
      ClientError(
        operationID: "op", operationInput: "input",
        causeDescription: "test", underlyingError: error)
    }
    #expect(ImmichApiClient.canRetryAfterClientFailure(wrap(TimeoutError.timeout)))
    #expect(ImmichApiClient.canRetryAfterClientFailure(wrap(wrap(TimeoutError.timeout))))
    #expect(!ImmichApiClient.canRetryAfterClientFailure(wrap(decodingError())))
  }

  // MARK: MetadataApiClient.canRetry

  @Test func metadataRetriesTransportAndServerFailures() {
    let retry = MetadataApiClient.canRetry
    #expect(retry(TimeoutError.timeout))
    #expect(retry(HTTPClientError.deadlineExceeded))
    #expect(retry(MetadataApiError.unknown(statusCode: 0, body: "")))
    #expect(retry(MetadataApiError.unknown(statusCode: 429, body: "")))
    #expect(retry(MetadataApiError.unknown(statusCode: 502, body: "")))
    #expect(retry(URLError(.networkConnectionLost)))
  }

  @Test func metadataDoesNotRetryClientSideOrPermanentFailures() {
    let retry = MetadataApiClient.canRetry
    #expect(!retry(CancellationError()))
    #expect(!retry(decodingError()))
    #expect(!retry(MetadataApiError.invalidPagination("stuck page")))
    #expect(!retry(MetadataApiError.unknown(statusCode: 404, body: "")))
    #expect(!retry(URLError(.badURL)))
    #expect(!retry(RandomError()))
  }
}
