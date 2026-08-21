import Testing

@testable import PhotosImmichSyncCore

/// Validate that the album marker embedded in the album description survives round-trip encoding+decoding.
@Suite struct AlbumTagTests {
  @Test func generateWrapsValueInMarker() {
    #expect(ImmichApiClient.generateAlbumTag("ABC-123") == "#photos-immich-sync:ABC-123#")
  }

  @Test(arguments: ["ABC-123", "UUID/L0/040", "with:colon", "with spaces"])
  func roundTripsTypicalLocalIdentifiers(value: String) {
    let tag = ImmichApiClient.generateAlbumTag(value)
    #expect(ImmichApiClient.extractAlbumTagValue(tag) == value)
  }

  @Test func extractFindsMarkerEmbeddedInText() {
    let text = "My vacation album\n\n#photos-immich-sync:UUID-9#\ntrailing notes"
    #expect(ImmichApiClient.extractAlbumTagValue(text) == "UUID-9")
  }

  @Test func extractIsNonGreedyAcrossMultipleMarkers() {
    let text = "#photos-immich-sync:one# and #photos-immich-sync:two#"
    #expect(ImmichApiClient.extractAlbumTagValue(text) == "one")
  }

  @Test func valueContainingHashDoesNotRoundTrip() {
    // Pinned quirk: '#' inside a value terminates the non-greedy match early.
    // Photos localIdentifiers (UUID/Lx/xxx) can never contain '#', so this is fine.
    let tag = ImmichApiClient.generateAlbumTag("a#b")
    #expect(ImmichApiClient.extractAlbumTagValue(tag) == "a")
  }

  @Test(arguments: ["", "no marker here", "#photos-immich-sync:#", "#other-app:value#"])
  func extractReturnsNilWithoutAValidMarker(text: String) {
    #expect(ImmichApiClient.extractAlbumTagValue(text) == nil)
  }
}
