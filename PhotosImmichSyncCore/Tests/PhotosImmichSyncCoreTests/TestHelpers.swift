import Foundation
import Photos
import SQLite3
import Yams

@testable import PhotosImmichSyncCore

/// Canonical test credentials, shared by every config builder and asserted on by
/// the client mock tests.
let TEST_IMMICH_URL = "http://immich.local:2283"
let TEST_METADATA_URL = "http://immich.local:8788"
let TEST_API_KEY = "test-key"

/// Decodes an `ImmichApiConfig` from YAML, defaulting to valid URLs. Used to build
/// configs for client-init tests without needing a memberwise initializer.
func makeApiConfig(
  url: String = TEST_IMMICH_URL,
  metadataApiUrl: String = TEST_METADATA_URL,
  extraYaml: String = ""
) throws -> ImmichApiConfig {
  try YAMLDecoder().decode(
    ImmichApiConfig.self,
    from: """
      url: "\(url)"
      metadataApiUrl: "\(metadataApiUrl)"
      apiKey: "\(TEST_API_KEY)"
      \(extraYaml)
      """)
}

/// Full `ImmichConfig` (api + feature toggles) for validateApiKey-style tests.
func makeImmichConfig(albumsEnabled: Bool, tagsEnabled: Bool) throws -> ImmichConfig {
  try YAMLDecoder().decode(
    ImmichConfig.self,
    from: """
      api:
        url: "\(TEST_IMMICH_URL)"
        metadataApiUrl: "\(TEST_METADATA_URL)"
        apiKey: "\(TEST_API_KEY)"
      albums:
        enabled: \(albumsEnabled)
      tags:
        enabled: \(tagsEnabled)
      """)
}

// MARK: - Metadata sidecar wire-format fixtures
// The `{"assetId": …, "value": {…}}` shape is pinned here once; every suite that
// fakes sidecar responses composes these.

private func jsonField(_ value: String?) -> String {
  value.map { "\"\($0)\"" } ?? "null"
}

func metadataValueJSON(
  cloudIdentifier: String? = nil, localIdentifier: String?, resourceType: String? = "original"
) -> String {
  """
  {"phAssetCloudIdentifier": \(jsonField(cloudIdentifier)),   "phAssetLocalIdentifier": \(jsonField(localIdentifier)),   "burstIdentifier": null,   "resourceType": \(jsonField(resourceType)),   "originalFilename": null}
  """
}

func metadataEntryJSON(
  assetId: String, cloudIdentifier: String? = nil, localIdentifier: String?,
  resourceType: String? = "original"
) -> String {
  let value = metadataValueJSON(
    cloudIdentifier: cloudIdentifier, localIdentifier: localIdentifier, resourceType: resourceType)
  return #"{"assetId":"\#(assetId)","value":\#(value)}"#
}

func metadataPageJSON(entries: [String] = [], total: Int) -> String {
  #"{"items":[\#(entries.joined(separator: ","))],"limit":1000,"offset":0,"total":\#(total)}"#
}

/// Builds an `AssetBundle` from value fields alone. The embedded `PHAsset` is a bare
/// instance — it is never handed to PhotoKit in tests; only the download path uses it
/// in production.
func makeBundle(
  localIdentifier: String = "ABC-123/L0/001",
  cloudIdentifier: String? = nil,
  resources: [AssetType: PHAssetResource] = [:],
  burstIdentifier: String? = nil,
  mediaType: PHAssetMediaType = .image,
  isFavorite: Bool = false,
  latitude: Double? = nil,
  longitude: Double? = nil,
  creationDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
  modificationDate: Date = Date(timeIntervalSince1970: 1_700_000_100),
  duration: TimeInterval = 0,
  mediaSubtypes: PHAssetMediaSubtype = [],
  hasAdjustments: Bool = false,
  title: String? = nil,
  caption: String? = nil
) -> AssetBundle {
  AssetBundle(
    asset: PHAsset(),
    cloudIdentifier: cloudIdentifier,
    resources: resources,
    burstIdentifier: burstIdentifier,
    localIdentifier: localIdentifier,
    mediaType: mediaType,
    isFavorite: isFavorite,
    latitude: latitude,
    longitude: longitude,
    creationDate: creationDate,
    modificationDate: modificationDate,
    duration: duration,
    mediaSubtypes: mediaSubtypes,
    hasAdjustments: hasAdjustments,
    title: title,
    caption: caption
  )
}

/// Creates a unique temporary directory for a test and returns its URL.
/// Callers should remove it in a `defer`.
func makeTempTestDir() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("photos-immich-sync-tests", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func decodeJSON<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(json.utf8))
}

/// Builds a `FileService` rooted in a fresh temp directory so tests never touch the
/// real `~/Library` locations. Remove `root` in a `defer` to clean up.
func makeHermeticFileService() throws -> (fs: FileService, root: URL) {
  let root = try makeTempTestDir()
  let workDir = root.appendingPathComponent("work", isDirectory: true)
  let dataDir = root.appendingPathComponent("data", isDirectory: true)
  try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
  return (FileService(workDir: workDir, dataDir: dataDir), root)
}

/// Creates a SQLite database in a temp directory, executes `sql` against it
/// (schema + seed rows), and returns the database file path.
func makeSQLiteDB(_ sql: String) throws -> String {
  let dir = try makeTempTestDir()
  let path = dir.appendingPathComponent("test.sqlite").path
  var db: OpaquePointer?
  guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
    throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create test db"])
  }
  defer { sqlite3_close(db) }
  var errMsg: UnsafeMutablePointer<CChar>?
  guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
    let message = errMsg.map { String(cString: $0) } ?? "unknown sqlite error"
    sqlite3_free(errMsg)
    throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
  }
  return path
}
