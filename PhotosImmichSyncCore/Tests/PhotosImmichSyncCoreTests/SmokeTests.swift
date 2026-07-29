import Testing

@testable import PhotosImmichSyncCore

@Suite struct SmokeTests {
  @Test func semanticVersionParsesTaggedRelease() {
    let version = SemanticVersion(parsing: "v1.2.3")
    #expect(version == SemanticVersion(major: 1, minor: 2, patch: 3))
  }

  @Test func semanticVersionRejectsGarbage() {
    #expect(SemanticVersion(parsing: "not-a-version") == nil)
  }
}
