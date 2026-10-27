import Foundation
import Testing

@testable import PhotosImmichSyncCore

/// Guards the local patches applied by `scripts/patch-openapi.sh`, so a spec refresh
/// that skips the script fails here instead of at runtime against a real server.
@Suite struct OpenAPISpecTests {
  private static func loadSpec() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("../../Sources/PhotosImmichSyncCore/openapi.json")
    return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  /// Every `required` property whose x-immich-history "Added" version is newer than `min`,
  /// as `path.property: version`.
  private static func requiredNewerThan(_ min: SemanticVersion, in node: Any, path: String = "") -> [String] {
    if let array = node as? [Any] {
      return array.enumerated().flatMap { requiredNewerThan(min, in: $1, path: "\(path)[\($0)]") }
    }
    guard let object = node as? [String: Any] else { return [] }
    var found: [String] = []
    if let required = object["required"] as? [String], let properties = object["properties"] as? [String: Any] {
      for name in required {
        let history = (properties[name] as? [String: Any])?["x-immich-history"] as? [[String: Any]] ?? []
        if let added = history.first(where: { $0["state"] as? String == "Added" })?["version"] as? String,
          let version = SemanticVersion(parsing: added), min < version
        {
          found.append("\(path).\(name): \(added)")
        }
      }
    }
    for (key, child) in object {
      found += requiredNewerThan(min, in: child, path: path.isEmpty ? key : "\(path).\(key)")
    }
    return found
  }

  @Test func noRequiredPropertyIsNewerThanMinimumServer() throws {
    #expect(Self.requiredNewerThan(IMMICH_MIN_SUPPORTED_VERSION, in: try Self.loadSpec()) == [])
  }

  @Test func assetMetadataIsTypedAsString() throws {
    let spec = try Self.loadSpec()
    let schemas = (spec["components"] as? [String: Any])?["schemas"] as? [String: Any]
    let dto = schemas?["AssetMediaCreateDto"] as? [String: Any]
    let metadata = (dto?["properties"] as? [String: Any])?["metadata"] as? [String: Any]
    #expect(metadata?["type"] as? String == "string")
  }
}
