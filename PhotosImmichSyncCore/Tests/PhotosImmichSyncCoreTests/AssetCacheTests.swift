import AsyncHTTPClient
import Foundation
import Testing

@testable import PhotosImmichSyncCore

/// Builds an AssetCache backed by mocks. `metadataHandler` drives the sidecar
/// lookups; the Immich client double never expects traffic in these tests.
private func makeCache(
  _ metadataHandler: @escaping @Sendable (HTTPClientRequest, Int) throws -> (UInt, String) = { _, _ in
    (200, metadataPageJSON(total: 0))
  }
) throws -> (cache: AssetCache, stub: RecordingHTTPStub) {
  let (immich, _) = try makeMockedImmichClient(responses: [])
  let (metadata, stub) = try makeMockedMetadataClient(metadataHandler)
  return (AssetCache(client: immich, metadataClient: metadata), stub)
}

private func entry(_ assetId: String, localId: String, resourceType: String = "original") throws -> MetadataEntry {
  try decodeJSON(
    MetadataEntry.self,
    from: metadataEntryJSON(assetId: assetId, localIdentifier: localId, resourceType: resourceType))
}

@Suite struct AssetCacheTests {
  @Test func addedMetadataIsKnownAndResolvable() async throws {
    let (cache, _) = try makeCache()
    await cache.add(try entry("im1", localId: "L1"))

    #expect(await cache.isKnownIdentifier(assetIdentifier: "L1original"))
    #expect(await cache.cachedImmichId(localIdentifier: "L1", type: .original) == "im1")
    #expect(await cache.cachedImmichId(localIdentifier: "L1", type: .edited) == nil)
  }

  @Test func metadataWithUnresolvableIdentifierIsCachedButNotIndexed() async throws {
    let (cache, _) = try makeCache()
    await cache.add(try entry("im9", localId: "L9", resourceType: "bogus"))
    #expect(await !cache.isKnownIdentifier(assetIdentifier: "L9bogus"))
    #expect(await cache.cachedImmichId(localIdentifier: "L9", type: .original) == nil)
  }

  @Test func bundleRegistrationIndexesTheIdentifier() async throws {
    let (cache, _) = try makeCache()
    let bundle = makeBundle(localIdentifier: "L2")
    await cache.add(immichId: "im2", bundle: bundle, type: .livephoto)
    #expect(await cache.cachedImmichId(localIdentifier: "L2", type: .livephoto) == "im2")
  }

  @Test func clearRemovesEveryIndexEntryForTheAsset() async throws {
    let (cache, _) = try makeCache()
    await cache.add(try entry("im1", localId: "L1"))
    await cache.clear(immichId: "im1")

    #expect(await !cache.isKnownIdentifier(assetIdentifier: "L1original"))
    #expect(await cache.cachedImmichId(localIdentifier: "L1", type: .original) == nil)
    #expect(await cache.orphanImmichIds(expectedAssetIds: []).isEmpty)
  }

  @Test func orphansAreTrackedAssetsMissingFromTheExpectedSet() async throws {
    let (cache, _) = try makeCache()
    await cache.add(try entry("im1", localId: "L1"))
    await cache.add(try entry("im2", localId: "L2"))
    await cache.add(try entry("im3", localId: "L3", resourceType: "bogus"))  // unresolvable: never orphaned

    let orphans = await cache.orphanImmichIds(expectedAssetIds: ["L1original"])
    #expect(Set(orphans) == ["im2"])

    let allOrphans = await cache.orphanImmichIds(expectedAssetIds: [])
    #expect(Set(allOrphans) == ["im1", "im2"])
  }

  @Test func resolveIdFallsBackToTheSidecarThenCaches() async throws {
    let (cache, stub) = try makeCache { request, _ in
      #expect(request.url.contains("filter=phAssetLocalIdentifier%3AL5"))
      #expect(request.url.contains("filter=resourceType%3Aoriginal"))
      return (
        200,
        metadataPageJSON(
          entries: [metadataEntryJSON(assetId: "im5", localIdentifier: "L5")], total: 1))
    }

    #expect(try await cache.resolveId(localIdentifier: "L5", type: .original) == "im5")
    // Second resolve is served from the cache: no extra sidecar request.
    #expect(try await cache.resolveId(localIdentifier: "L5", type: .original) == "im5")
    #expect(stub.requests.count == 1)
  }

  @Test func resolveIdReturnsNilWhenTheSidecarHasNothing() async throws {
    let (cache, _) = try makeCache()
    #expect(try await cache.resolveId(localIdentifier: "L404", type: .original) == nil)
  }
}
