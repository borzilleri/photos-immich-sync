import Foundation
import Testing

@testable import PhotosImmichSyncCore

@Suite struct MetadataDecodeTests {
  @Test func metadataEntryDecodesFromApiFixture() throws {
    let entry = try decodeJSON(
      MetadataEntry.self,
      from: """
        {
          "assetId": "immich-asset-1",
          "value": {
            "phAssetCloudIdentifier": "cloud-1",
            "phAssetLocalIdentifier": "local-1",
            "burstIdentifier": null,
            "resourceType": "original",
            "originalFilename": "IMG_0001.HEIC"
          }
        }
        """)
    #expect(entry.assetId == "immich-asset-1")
    #expect(entry.value.phAssetCloudIdentifier == "cloud-1")
    #expect(entry.value.phAssetLocalIdentifier == "local-1")
    #expect(entry.value.burstIdentifier == nil)
    #expect(entry.value.originalFilename == "IMG_0001.HEIC")
  }

  @Test func assetIdentifierRoundTripsThroughResourceType() throws {
    let value = try decodeJSON(
      AssetMetadataValue.self,
      from: """
        {"phAssetLocalIdentifier": "L1", "resourceType": "edited"}
        """)
    #expect(value.assetIdentifier() == "L1edited")
  }

  @Test(arguments: [
    #"{"phAssetLocalIdentifier": "L1", "resourceType": "bogus"}"#,
    #"{"phAssetLocalIdentifier": "L1"}"#,
    #"{"resourceType": "original"}"#,
  ])
  func assetIdentifierIsNilWithoutResolvableTypeAndLocalId(json: String) throws {
    let value = try decodeJSON(AssetMetadataValue.self, from: json)
    #expect(value.assetIdentifier() == nil)
  }
}
