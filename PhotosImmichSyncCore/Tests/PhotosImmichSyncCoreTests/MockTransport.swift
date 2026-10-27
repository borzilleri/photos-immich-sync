import AsyncHTTPClient
import Foundation
import HTTPTypes
import NIOCore
import NIOHTTP1
import OpenAPIRuntime

@testable import PhotosImmichSyncCore

/// OpenAPI transport double: plays canned responses in order and records every
/// request it sees (post-middleware, so headers added by middlewares are visible),
/// along with each request body collected as a string.
final class MockTransport: ClientTransport, @unchecked Sendable {
  struct Exhausted: Error {}

  private let lock = NSLock()
  private var canned: [Result<(HTTPResponse, HTTPBody?), any Error>]
  private var recorded: [(request: HTTPRequest, body: String?)] = []

  init(_ responses: [Result<(HTTPResponse, HTTPBody?), any Error>]) {
    self.canned = responses
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    let bodyString: String? = if let body { try await String(collecting: body, upTo: 1 << 20) } else { nil }
    lock.lock()
    recorded.append((request, bodyString))
    let next = canned.isEmpty ? nil : canned.removeFirst()
    lock.unlock()
    guard let next else { throw Exhausted() }
    return try next.get()
  }

  var requests: [HTTPRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded.map(\.request)
  }

  var bodies: [String?] {
    lock.lock()
    defer { lock.unlock() }
    return recorded.map(\.body)
  }
}

func jsonResponse(status: HTTPResponse.Status = .ok, _ json: String) -> Result<(HTTPResponse, HTTPBody?), any Error> {
  .success((HTTPResponse(status: status, headerFields: [.contentType: "application/json"]), HTTPBody(json)))
}

func plainResponse(status: HTTPResponse.Status, _ body: String = "") -> Result<(HTTPResponse, HTTPBody?), any Error> {
  .success((HTTPResponse(status: status), HTTPBody(body)))
}

// Retry backoff is a no-op under both mock factories so retry tests run instantly.

func makeMockedImmichClient(
  responses: [Result<(HTTPResponse, HTTPBody?), any Error>],
  extraYaml: String = ""
) throws -> (client: ImmichApiClient, transport: MockTransport) {
  let transport = MockTransport(responses)
  let client = try ImmichApiClient(makeApiConfig(extraYaml: extraYaml), transport: transport, sleep: { _ in })
  return (client, transport)
}

/// Metadata-client double: hands each request to `handler` (returning status + body)
/// and records the requests.
final class RecordingHTTPStub: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [HTTPClientRequest] = []
  private let handler: @Sendable (HTTPClientRequest, Int) throws -> (UInt, String)

  /// `handler` receives the request and its 0-based sequence number.
  init(_ handler: @escaping @Sendable (HTTPClientRequest, Int) throws -> (UInt, String)) {
    self.handler = handler
  }

  func executor() -> MetadataApiClient.HTTPExecutor {
    { [self] request, _ in
      lock.lock()
      let index = recorded.count
      recorded.append(request)
      lock.unlock()
      let (status, body) = try handler(request, index)
      return HTTPClientResponse(
        status: .init(statusCode: Int(status)),
        body: .bytes(ByteBuffer(string: body)))
    }
  }

  var requests: [HTTPClientRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

func makeMockedMetadataClient(
  extraYaml: String = "",
  _ handler: @escaping @Sendable (HTTPClientRequest, Int) throws -> (UInt, String)
) throws -> (client: MetadataApiClient, stub: RecordingHTTPStub) {
  let stub = RecordingHTTPStub(handler)
  let client = try MetadataApiClient(
    makeApiConfig(extraYaml: extraYaml), executor: stub.executor(), sleep: { _ in })
  return (client, stub)
}
