import AsyncHTTPClient
import Foundation
import NIOHTTP1
import Testing

@testable import PhotosImmichSyncCore

private func pageJSON(items: [(assetId: String, localId: String)], total: Int) -> String {
  metadataPageJSON(
    entries: items.map { metadataEntryJSON(assetId: $0.assetId, localIdentifier: $0.localId) },
    total: total)
}

@Suite struct MetadataClientMockTests {
  @Test func healthCheckMapsStatusToBool() async throws {
    let (healthy, _) = try makeMockedMetadataClient { _, _ in (200, "ok") }
    #expect(await healthy.checkHealth())

    let (unhealthy, stub) = try makeMockedMetadataClient { _, _ in (500, "down") }
    #expect(await !unhealthy.checkHealth())
    #expect(stub.requests.count == 1)  // health check does not retry
  }

  @Test func lookupBuildsFilteredRequestWithApiKey() async throws {
    let (client, stub) = try makeMockedMetadataClient { _, _ in
      (200, pageJSON(items: [("im1", "L1")], total: 1))
    }
    let entries = try await client.lookup(field: .phAssetLocalIdentifier, value: "L1")
    #expect(entries.count == 1)
    #expect(entries.first?.assetId == "im1")

    let request = try #require(stub.requests.first)
    #expect(request.url.contains("/metadata?"))
    #expect(request.url.contains("filter=phAssetLocalIdentifier%3AL1"))
    #expect(request.url.contains("limit=1000"))
    #expect(request.headers.first(name: "x-api-key") == "test-key")
  }

  @Test func paginationAdvancesByReturnedCountUntilTotal() async throws {
    let (client, stub) = try makeMockedMetadataClient { _, index in
      switch index {
      case 0: return (200, pageJSON(items: [("im1", "L1"), ("im2", "L2")], total: 3))
      default: return (200, pageJSON(items: [("im3", "L3")], total: 3))
      }
    }
    let entries = try await client.enumerateManaged()
    #expect(entries.map(\.assetId) == ["im1", "im2", "im3"])

    let offsets = stub.requests.compactMap { request -> String? in
      URLComponents(string: request.url)?.queryItems?.first(where: { $0.name == "offset" })?.value
    }
    #expect(offsets == ["0", "2"])
  }

  @Test func emptyPageEndsPaginationEvenBelowTotal() async throws {
    // A server-reported total that never materializes must not loop forever.
    let (client, stub) = try makeMockedMetadataClient { _, index in
      index == 0
        ? (200, pageJSON(items: [("im1", "L1")], total: 100))
        : (200, pageJSON(items: [], total: 100))
    }
    let entries = try await client.lookup(filters: [])
    #expect(entries.count == 1)
    #expect(stub.requests.count == 2)
  }

  @Test func non2xxSurfacesAsUnknownWithoutRetry() async throws {
    let (client, stub) = try makeMockedMetadataClient(extraYaml: "retryAttempts: 3") { _, _ in
      (404, "missing")
    }
    do {
      _ = try await client.lookup(field: .phAssetLocalIdentifier, value: "L1")
      Issue.record("expected MetadataApiError")
    } catch MetadataApiError.unknown(let status, let body) {
      #expect(status == 404)
      #expect(body == "missing")
    }
    #expect(stub.requests.count == 1)
  }
}
