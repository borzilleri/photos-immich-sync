import Foundation
import Photos
import Testing

@testable import PhotosImmichSyncCore

@Suite struct BundleValueTests {
  // Pins the assumption the whole test-bundle strategy rests on: a bare PHAsset (and
  // PHAssetResource) can be constructed without Photos authorization or a library.
  @Test func barePhotoKitObjectsConstruct() {
    _ = PHAsset()
    _ = PHAssetResource()
  }

  @Test func assetIdentifierAppendsResourceType() {
    let bundle = makeBundle(localIdentifier: "UUID-1/L0/001")
    #expect(bundle.getAssetIdentifier(for: .original) == "UUID-1/L0/001original")
    #expect(bundle.getAssetIdentifier(for: .livephoto) == "UUID-1/L0/001livephoto")
  }

  @Test(arguments: [
    (nil, nil, nil),
    ("Title", nil, "Title"),
    (nil, "Caption", "Caption"),
    ("Title", "Caption", "Title\n\nCaption"),
  ] as [(String?, String?, String?)])
  func immichDescriptionCombinesTitleAndCaption(title: String?, caption: String?, expected: String?) {
    let bundle = makeBundle(title: title, caption: caption)
    #expect(bundle.getImmichDescription() == expected)
  }

  @Test func descriptionRendersSnapshotFields() {
    let bundle = makeBundle(localIdentifier: "L1", title: "T")
    #expect(bundle.description == "AsstBundle(cloudId:nil; localId:L1; type:Image; resources:[]; title:T; caption:-)")
  }

  @Test func bundleStatsCountsTypesAndFiles() {
    let bundles = [
      makeBundle(resources: [.original: PHAssetResource(), .livephoto: PHAssetResource()]),
      makeBundle(resources: [.original: PHAssetResource(), .edited: PHAssetResource()]),
      makeBundle(resources: [.original: PHAssetResource()], mediaType: .video),
    ]
    let stats = PhotosExporter.generateBundleStats(bundles)

    #expect(stats.contains("3 new/updated assets"))
    #expect(stats.contains("1 Live Photos"))
    #expect(stats.contains("1 Videos"))
    #expect(stats.contains("1 Edited Photo Assets"))
    #expect(stats.contains("5 total files"))
  }

  // MARK: matchesBundle precedence

  private func metadataValue(cloud: String?, local: String?, resourceType: String? = "original") throws
    -> AssetMetadataValue
  {
    try decodeJSON(
      AssetMetadataValue.self,
      from: metadataValueJSON(cloudIdentifier: cloud, localIdentifier: local, resourceType: resourceType))
  }

  @Test func matchRejectsResourceTypeMismatch() throws {
    let value = try metadataValue(cloud: "C1", local: "L1", resourceType: "original")
    #expect(!value.matchesBundle(makeBundle(localIdentifier: "L1", cloudIdentifier: "C1"), type: .edited))
  }

  @Test func cloudIdentifierOnBothSidesDecidesTheMatch() throws {
    let bundle = makeBundle(localIdentifier: "L1", cloudIdentifier: "C1")
    #expect(try metadataValue(cloud: "C1", local: "other").matchesBundle(bundle, type: .original))
    // Cloud ids disagree: no fallback to the (matching) local identifier.
    #expect(try !metadataValue(cloud: "C2", local: "L1").matchesBundle(bundle, type: .original))
  }

  @Test func fallsBackToLocalIdentifierWhenEitherCloudIdIsMissing() throws {
    let bundleWithCloud = makeBundle(localIdentifier: "L1", cloudIdentifier: "C1")
    let bundleNoCloud = makeBundle(localIdentifier: "L1", cloudIdentifier: nil)
    #expect(try metadataValue(cloud: nil, local: "L1").matchesBundle(bundleWithCloud, type: .original))
    #expect(try metadataValue(cloud: "C1", local: "L1").matchesBundle(bundleNoCloud, type: .original))
    #expect(try !metadataValue(cloud: nil, local: "L2").matchesBundle(bundleWithCloud, type: .original))
  }
}
