import Foundation
import Testing

@testable import PhotosImmichSyncCore

/// Only the *throwing* init paths are exercised here: a successful client init creates
/// an HTTPClient that is retained for the process lifetime (see `retainedHTTPClients`),
/// so tests avoid it until the lifecycle fix lands (pre-work item 3).
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
}
