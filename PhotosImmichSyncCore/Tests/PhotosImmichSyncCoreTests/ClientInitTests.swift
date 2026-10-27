import Foundation
import Testing

@testable import PhotosImmichSyncCore

/// Invalid URLs must throw *before* any HTTPClient is created — an orphaned,
/// never-shut-down HTTPClient crashes on deinit.
private let INVALID_URLS = ["", "   ", "notaurl", "ftp://host", "http://"]

@Suite struct ClientInitTests {
  @Test(arguments: INVALID_URLS)
  func immichClientRejectsInvalidServerURL(url: String) throws {
    let config = try makeApiConfig(url: url)
    #expect(throws: ImmichConfigError.self) {
      _ = try ImmichApiClient(config)
    }
  }

  @Test(arguments: INVALID_URLS)
  func metadataClientRejectsInvalidServerURL(url: String) throws {
    let config = try makeApiConfig(metadataApiUrl: url)
    #expect(throws: MetadataApiError.self) {
      _ = try MetadataApiClient(config)
    }
  }

  @Test func successfulClientsOwnAndShutDownTheirHTTPClients() async throws {
    // Round-trips the real lifecycle: convenience init builds an HTTPClient, shutdown
    // releases it, and deinit afterwards is clean (no precondition crash).
    let immich = try ImmichApiClient(makeApiConfig())
    await immich.shutdown()
    let metadata = try MetadataApiClient(makeApiConfig())
    await metadata.shutdown()
  }

  @Test func mockBackedClientsShutDownAsANoOp() async throws {
    let (immich, _) = try makeMockedImmichClient(responses: [])
    await immich.shutdown()
    let (metadata, _) = try makeMockedMetadataClient { _, _ in (200, "") }
    await metadata.shutdown()
  }
}
