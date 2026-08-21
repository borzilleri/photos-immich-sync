import Testing

@testable import PhotosImmichSyncCore

@Suite struct SemanticVersionTests {
  @Test(arguments: [
    ("1.2.3", 1, 2, 3),
    ("v1.2.3", 1, 2, 3),
    ("V1.2.3", 1, 2, 3),
    ("1.2", 1, 2, 0),
    ("7", 7, 0, 0),
    ("1.2.3-rc1", 1, 2, 3),
    ("1.2.3+build5", 1, 2, 3),
    (" 1.2.3\n", 1, 2, 3),
    ("0.0.0", 0, 0, 0),
  ])
  func parsesValidVersions(raw: String, major: Int, minor: Int, patch: Int) {
    #expect(SemanticVersion(parsing: raw) == SemanticVersion(major: major, minor: minor, patch: patch))
  }

  @Test(arguments: [
    "", "not-a-version", "1.2.3.4", "1..3", "a.b.c", "-1.2.3", "1.2.x", "v", "..",
  ])
  func rejectsInvalidVersions(raw: String) {
    #expect(SemanticVersion(parsing: raw) == nil)
  }

  @Test func ordersByMajorMinorPatch() {
    let ordered = ["1.2.3", "1.2.4", "1.3.0", "2.0.0"].compactMap { SemanticVersion(parsing: $0) }
    #expect(ordered.count == 4)
    #expect(ordered == ordered.sorted())
    #expect(ordered[0] < ordered[1])
    #expect(!(ordered[0] < ordered[0]))
    // Minor beats patch.
    #expect(SemanticVersion(parsing: "1.2.9")! < SemanticVersion(parsing: "1.3.0")!)
  }
}
