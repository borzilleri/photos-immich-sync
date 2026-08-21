import Foundation
import HTTPTypes
import Testing

@testable import PhotosImmichSyncCore

private let SERVER_VERSION_JSON = #"{"major":3,"minor":2,"patch":1,"prerelease":0}"#

private func apiKeyJSON(permissions: [String]) -> String {
  let list = permissions.map { "\"\($0)\"" }.joined(separator: ",")
  return """
    {"createdAt":"2024-01-01T00:00:00.000Z","id":"k1","name":"test",
     "permissions":[\(list)],"updatedAt":"2024-01-01T00:00:00.000Z"}
    """
}

private let CORE_PERMISSIONS = [
  "asset.read", "asset.update", "asset.delete", "asset.upload", "asset.copy", "stack.create",
]
private let ALBUM_PERMISSIONS = [
  "album.create", "album.read", "album.update", "album.delete",
  "albumAsset.create", "albumAsset.delete",
]

private func searchJSON(nextPage: String?) -> String {
  let next = nextPage.map { "\"\($0)\"" } ?? "null"
  return """
    {"albums":{"count":0,"facets":[],"items":[],"total":0},
     "assets":{"count":0,"facets":[],"items":[],"total":0,"nextPage":\(next)}}
    """
}

@Suite struct ImmichClientMockTests {
  @Test func serverVersionParsesAndSendsApiKeyHeader() async throws {
    let (client, transport) = try makeMockedImmichClient(responses: [jsonResponse(SERVER_VERSION_JSON)])
    let version = try await client.checkServerVersion()
    #expect(version == SemanticVersion(major: 3, minor: 2, patch: 1))

    let request = try #require(transport.requests.first)
    #expect(request.headerFields[HTTPField.Name("X-Api-Key")!] == "test-key")
  }

  @Test func undocumentedStatusBecomesApiErrorWithoutRetry() async throws {
    let (client, transport) = try makeMockedImmichClient(
      responses: [plainResponse(status: .notFound, "nope")],
      extraYaml: "retryAttempts: 3")
    do {
      _ = try await client.checkServerVersion()
      Issue.record("expected ImmichApiError")
    } catch ImmichApiError.unknown(let status, let body) {
      #expect(status == 404)
      #expect(body == "nope")
    }
    #expect(transport.requests.count == 1)  // 4xx is not retried
  }

  @Test func serverErrorsAreRetriedUntilSuccess() async throws {
    // maxConcurrentRequests 1 also proves the concurrency-limit middleware releases
    // its slot on a thrown attempt — a leak would deadlock the retry.
    let (client, transport) = try makeMockedImmichClient(
      responses: [
        plainResponse(status: .internalServerError, "boom"),
        jsonResponse(SERVER_VERSION_JSON),
      ],
      extraYaml: "retryAttempts: 2\nmaxConcurrentRequests: 1")
    let version = try await client.checkServerVersion()
    #expect(version == SemanticVersion(major: 3, minor: 2, patch: 1))
    #expect(transport.requests.count == 2)
  }

  @Test func retryStopsAfterConfiguredAttempts() async throws {
    let (client, transport) = try makeMockedImmichClient(
      responses: [
        plainResponse(status: .serviceUnavailable),
        plainResponse(status: .serviceUnavailable),
        plainResponse(status: .serviceUnavailable),
      ],
      extraYaml: "retryAttempts: 2")
    await #expect(throws: ImmichApiError.self) {
      _ = try await client.checkServerVersion()
    }
    #expect(transport.requests.count == 2)
  }

  // MARK: validateApiKey permission logic

  @Test func allPermissionShortCircuits() async throws {
    let (client, _) = try makeMockedImmichClient(responses: [jsonResponse(apiKeyJSON(permissions: ["all"]))])
    try await client.validateApiKey(config: makeImmichConfig(albumsEnabled: true, tagsEnabled: true))
  }

  @Test func corePermissionsSufficeWhenFeaturesAreDisabled() async throws {
    let (client, _) = try makeMockedImmichClient(
      responses: [jsonResponse(apiKeyJSON(permissions: CORE_PERMISSIONS))])
    try await client.validateApiKey(config: makeImmichConfig(albumsEnabled: false, tagsEnabled: false))
  }

  @Test func missingCorePermissionsAreReported() async throws {
    let granted = CORE_PERMISSIONS.filter { $0 != "asset.upload" }
    let (client, _) = try makeMockedImmichClient(responses: [jsonResponse(apiKeyJSON(permissions: granted))])
    do {
      try await client.validateApiKey(config: makeImmichConfig(albumsEnabled: false, tagsEnabled: false))
      Issue.record("expected missing permissions")
    } catch ImmichPermissionError.missingPermissions(let missing) {
      #expect(missing == [.asset_upload])
    }
  }

  @Test func enabledAlbumSyncRequiresAlbumPermissions() async throws {
    let (client, _) = try makeMockedImmichClient(
      responses: [jsonResponse(apiKeyJSON(permissions: CORE_PERMISSIONS))])
    do {
      try await client.validateApiKey(config: makeImmichConfig(albumsEnabled: true, tagsEnabled: false))
      Issue.record("expected missing album permissions")
    } catch ImmichPermissionError.missingPermissions(let missing) {
      #expect(missing == PERMISSIONS_ALBUMS)
    }
  }

  @Test func enabledTagSyncRequiresTagPermissions() async throws {
    let (client, _) = try makeMockedImmichClient(
      responses: [jsonResponse(apiKeyJSON(permissions: CORE_PERMISSIONS + ALBUM_PERMISSIONS))])
    do {
      try await client.validateApiKey(config: makeImmichConfig(albumsEnabled: true, tagsEnabled: true))
      Issue.record("expected missing tag permissions")
    } catch ImmichPermissionError.missingPermissions(let missing) {
      #expect(missing == PERMISSIONS_TAGS)
    }
  }

  // MARK: searchAssets pagination guards

  @Test func nonNumericNextPageAborts() async throws {
    let (client, _) = try makeMockedImmichClient(responses: [jsonResponse(searchJSON(nextPage: "abc"))])
    do {
      _ = try await client.searchAssets(.init())
      Issue.record("expected invalidPagination")
    } catch ImmichApiError.invalidPagination(let reason) {
      #expect(reason.contains("non-numeric"))
    }
  }

  @Test func nonAdvancingNextPageAborts() async throws {
    let (client, _) = try makeMockedImmichClient(responses: [jsonResponse(searchJSON(nextPage: "1"))])
    do {
      _ = try await client.searchAssets(.init())
      Issue.record("expected invalidPagination")
    } catch ImmichApiError.invalidPagination(let reason) {
      #expect(reason.contains("non-advancing"))
    }
  }

  @Test func paginationFollowsAdvancingPagesToTheEnd() async throws {
    let (client, transport) = try makeMockedImmichClient(responses: [
      jsonResponse(searchJSON(nextPage: "2")),
      jsonResponse(searchJSON(nextPage: "3")),
      jsonResponse(searchJSON(nextPage: nil)),
    ])
    let items = try await client.searchAssets(.init())
    #expect(items.isEmpty)
    #expect(transport.requests.count == 3)
  }
}
