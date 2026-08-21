import Testing

@testable import PhotosImmichSyncCore

@Suite struct TagPlanningTests {
  // MARK: buildKeywordMap

  @Test func keywordMapAppliesPrefixAndDropsEmptyKeywords() {
    let keywords = [
      PhotosKeyword(keyword: "travel", assetIds: ["a1", "a2"]),
      PhotosKeyword(keyword: "unused", assetIds: []),  // delta-safety: never tagged, never deleted
      PhotosKeyword(keyword: "family", assetIds: ["a3"]),
    ]
    let map = ImmichService.buildKeywordMap(keywords: keywords, tagPrefix: "🍎/")
    #expect(Set(map.keys) == ["🍎/travel", "🍎/family"])
    #expect(map["🍎/travel"]?.assetIds == ["a1", "a2"])
  }

  @Test func keywordMapWithEmptyPrefixUsesBareKeywords() {
    let map = ImmichService.buildKeywordMap(
      keywords: [PhotosKeyword(keyword: "solo", assetIds: ["x"])], tagPrefix: "")
    #expect(Set(map.keys) == ["solo"])
  }

  // MARK: shouldDeleteTag

  @Test func desiredTagsAreKept() {
    #expect(!ImmichService.shouldDeleteTag(tagValue: "🍎/travel", desiredTagValues: ["🍎/travel"]))
  }

  @Test func ancestorsOfDesiredNestedTagsAreKept() {
    // "a" must survive when "a/b" is still desired — deleting it would cascade in Immich.
    #expect(!ImmichService.shouldDeleteTag(tagValue: "a", desiredTagValues: ["a/b"]))
    #expect(!ImmichService.shouldDeleteTag(tagValue: "a/b", desiredTagValues: ["a/b/c"]))
  }

  @Test func prefixMatchRequiresAPathBoundary() {
    // "a/b" is NOT an ancestor of "a/bc" — the childPrefix "a/b/" must not match it.
    #expect(ImmichService.shouldDeleteTag(tagValue: "a/b", desiredTagValues: ["a/bc"]))
  }

  @Test func unrelatedTagsAreDeleted() {
    #expect(ImmichService.shouldDeleteTag(tagValue: "🍎/old", desiredTagValues: ["🍎/new", "🍎/other"]))
    #expect(ImmichService.shouldDeleteTag(tagValue: "anything", desiredTagValues: []))
  }
}
