import Foundation
import Testing

@testable import PhotosImmichSyncCore

@Suite struct MetadataUrlTests {
  private let base = "http://immich.local:8788"

  @Test func plainPathHasNoQueryString() throws {
    let url = try MetadataApiClient.makeURL(base: base, path: "/api/health", query: [])
    #expect(url == "http://immich.local:8788/api/health")
  }

  @Test func reservedCharactersInQueryValuesArePercentEncoded() throws {
    // Cloud identifiers contain `:` `+` `/` `=`; none may survive un-encoded.
    let url = try MetadataApiClient.makeURL(
      base: base, path: "/api/lookup",
      query: [URLQueryItem(name: "value", value: "AB:cd+ef/gh=")])
    #expect(url == "http://immich.local:8788/api/lookup?value=AB%3Acd%2Bef%2Fgh%3D")
  }

  @Test func multipleQueryItemsAreJoined() throws {
    let url = try MetadataApiClient.makeURL(
      base: base, path: "/api/lookup",
      query: [
        URLQueryItem(name: "field", value: "phAssetCloudIdentifier"),
        URLQueryItem(name: "limit", value: "100"),
      ])
    #expect(url == "http://immich.local:8788/api/lookup?field=phAssetCloudIdentifier&limit=100")
  }

  @Test func unreservedCharactersSurviveUntouched() throws {
    let url = try MetadataApiClient.makeURL(
      base: base, path: "/api/lookup",
      query: [URLQueryItem(name: "v", value: "abc-DEF_123.~xyz")])
    #expect(url.hasSuffix("?v=abc-DEF_123.~xyz"))
  }
}
