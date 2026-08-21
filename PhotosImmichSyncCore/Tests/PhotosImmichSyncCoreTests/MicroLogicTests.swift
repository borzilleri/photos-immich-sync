import Foundation
import Photos
import Testing

@testable import PhotosImmichSyncCore

// MARK: - syncAssetResource routing

@Suite struct ResourceSyncActionTests {
  private func check(
    action: Components.Schemas.AssetUploadAction,
    assetId: String? = nil,
    reason: Components.Schemas.AssetRejectReason? = nil
  ) -> Components.Schemas.AssetBulkUploadCheckResult {
    .init(action: action, assetId: assetId, id: "check-1", reason: reason)
  }

  @Test func missingHashCheckUploadsNew() {
    #expect(ImmichService.resourceSyncAction(hashCheck: nil, knownAsset: false) == .uploadNew)
    #expect(ImmichService.resourceSyncAction(hashCheck: nil, knownAsset: true) == .uploadNew)
  }

  @Test func acceptRoutesByKnownAsset() {
    #expect(ImmichService.resourceSyncAction(hashCheck: check(action: .accept), knownAsset: false) == .uploadNew)
    #expect(ImmichService.resourceSyncAction(hashCheck: check(action: .accept), knownAsset: true) == .copy)
  }

  @Test func rejectedDuplicateBecomesMetadataUpdate() {
    let result = ImmichService.resourceSyncAction(
      hashCheck: check(action: .reject, assetId: "im1", reason: .duplicate), knownAsset: false)
    #expect(result == .updateInfo(immichId: "im1"))
  }

  @Test func duplicateWithoutResolvableIdIsSurfaced() {
    let result = ImmichService.resourceSyncAction(
      hashCheck: check(action: .reject, reason: .duplicate), knownAsset: true)
    #expect(result == .updateInfoUnresolvable)
  }

  @Test func rejectWithoutDuplicateReasonIsUnknown() {
    let result = ImmichService.resourceSyncAction(hashCheck: check(action: .reject), knownAsset: false)
    #expect(result == .rejectedUnknown)
  }
}

// MARK: - Tag membership algebra

@Suite struct TagMembershipTests {
  @Test func changesAreDiffedAgainstRemoteMembership() {
    let (toTag, toUntag) = ImmichService.tagMembershipChanges(
      desired: ["a", "b", "c"],
      remote: ["b", "d", "e"],
      changedIds: ["d"],
      remoteFetched: true)
    #expect(Set(toTag) == ["a", "c"])
    // "e" is remote and undesired, but untouched by this run — it must NOT be untagged.
    #expect(Set(toUntag) == ["d"])
  }

  @Test func failedRemoteFetchOnlyEverAddsTags() {
    let (toTag, toUntag) = ImmichService.tagMembershipChanges(
      desired: ["a", "b"],
      remote: [],
      changedIds: ["a", "b", "z"],
      remoteFetched: false)
    #expect(Set(toTag) == ["a", "b"])
    #expect(toUntag.isEmpty)
  }

  @Test func emptyDesiredUntagsOnlyChangedAssets() {
    let (toTag, toUntag) = ImmichService.tagMembershipChanges(
      desired: [],
      remote: ["x", "y"],
      changedIds: ["x"],
      remoteFetched: true)
    #expect(toTag.isEmpty)
    #expect(Set(toUntag) == ["x"])
  }
}

// MARK: - Burst export filter

@Suite struct BurstFilterTests {
  @Test(arguments: [BurstType.none, .selected, .all])
  func nonBurstAssetsAlwaysExport(includeBursts: BurstType) {
    #expect(
      PhotosExporter.shouldExportBurst(burstIdentifier: nil, selectionTypes: [], includeBursts: includeBursts))
  }

  @Test(arguments: [BurstType.none, .selected, .all])
  func userPickedBurstsAlwaysExport(includeBursts: BurstType) {
    #expect(
      PhotosExporter.shouldExportBurst(
        burstIdentifier: "B1", selectionTypes: .userPick, includeBursts: includeBursts))
  }

  @Test func autoPickedBurstsExportForSelectedAndAll() {
    func autoPick(_ mode: BurstType) -> Bool {
      PhotosExporter.shouldExportBurst(burstIdentifier: "B1", selectionTypes: .autoPick, includeBursts: mode)
    }
    #expect(!autoPick(.none))
    #expect(autoPick(.selected))
    #expect(autoPick(.all))
  }

  @Test func unselectedBurstMembersExportOnlyForAll() {
    func unselected(_ mode: BurstType) -> Bool {
      PhotosExporter.shouldExportBurst(burstIdentifier: "B1", selectionTypes: [], includeBursts: mode)
    }
    #expect(!unselected(.none))
    #expect(!unselected(.selected))
    #expect(unselected(.all))
  }
}

// MARK: - Edited filename derivation

@Suite struct EditedFilenameTests {
  @Test(arguments: [
    ("IMG_0001.HEIC", "jpeg", "IMG_0001_edited.jpeg"),
    ("IMG_0001", "jpeg", "IMG_0001_edited.jpeg"),
    ("archive.2024.HEIC", "png", "archive.2024_edited.png"),
    ("IMG.HEIC", "", "IMG_edited."),  // pinned quirk: empty extension keeps the dot
  ])
  func derivesEditedName(original: String, ext: String, expected: String) {
    #expect(PhotosDownloader.editedFilename(original: original, ext: ext) == expected)
  }
}

// MARK: - Preflight endpoint derivation

@Suite struct ProbeEndpointTests {
  @Test func explicitPortWins() throws {
    let endpoint = try #require(NetworkPreflight.probeEndpoint(for: "http://immich.local:8080/api"))
    #expect(endpoint.host == "immich.local")
    #expect(endpoint.port == 8080)
  }

  @Test func schemeDefaultsApply() throws {
    #expect(try #require(NetworkPreflight.probeEndpoint(for: "http://immich.local")).port == 80)
    #expect(try #require(NetworkPreflight.probeEndpoint(for: "https://immich.local")).port == 443)
  }

  @Test func whitespaceIsTrimmed() throws {
    let endpoint = try #require(NetworkPreflight.probeEndpoint(for: "  https://immich.local \n"))
    #expect(endpoint.host == "immich.local")
  }

  @Test(arguments: ["", "not a url", "/just/a/path", "immich.local"])
  func unusableURLsYieldNoEndpoint(url: String) {
    #expect(NetworkPreflight.probeEndpoint(for: url) == nil)
  }
}
