import Foundation
import Testing

@testable import PhotosImmichSyncCore

@Suite struct SanitizeFilenameTests {
  @Test(arguments: [
    ("a/b\\c:d", "a_b_c_d"),
    ("nul\0byte", "nul_byte"),
    ("ctrl\u{01}\u{1F}char", "ctrl__char"),
    ("IMG_0001.HEIC", "IMG_0001.HEIC"),
    ("  padded  ", "padded"),
  ])
  func replacesUnsafeCharacters(raw: String, expected: String) {
    #expect(FileService.sanitizeFilename(raw) == expected)
  }

  @Test(arguments: ["", "   ", "\0", "///"])
  func neverReturnsEmpty(raw: String) {
    let result = FileService.sanitizeFilename(raw)
    #expect(!result.isEmpty)
  }

  @Test func emptyAndWhitespaceBecomeFile() {
    #expect(FileService.sanitizeFilename("") == "file")
    #expect(FileService.sanitizeFilename("    ") == "file")
    // A tab is a control character: replaced with "_" before trimming, so the
    // result is "_" rather than the "file" fallback.
    #expect(FileService.sanitizeFilename("  \t ") == "_")
  }

  @Test func clampPreservesExtension() {
    let name = String(repeating: "a", count: 200) + ".jpg"
    let result = FileService.sanitizeFilename(name, maxLength: 120)
    #expect(result.hasSuffix(".jpg"))
    // budget = maxLength - ext - dot
    #expect(result.count == 120)
    #expect(result == String(repeating: "a", count: 116) + ".jpg")
  }

  @Test func clampWithoutExtensionReservesTheDotBudget() {
    let result = FileService.sanitizeFilename(String(repeating: "a", count: 200), maxLength: 120)
    // Documented quirk: the budget always subtracts one for a dot, even with no extension.
    #expect(result == String(repeating: "a", count: 119))
  }

  @Test func oversizedExtensionIsPreservedBeyondTheBudget() {
    let ext = String(repeating: "x", count: 130)
    let result = FileService.sanitizeFilename("base." + ext, maxLength: 120)
    // Documented quirk: the extension survives clamping even when it alone exceeds maxLength.
    #expect(result == "b." + ext)
  }

  @Test func exactlyMaxLengthIsUntouched() {
    let name = String(repeating: "a", count: 120)
    #expect(FileService.sanitizeFilename(name, maxLength: 120) == name)
  }

  @Test func unicodeCountsCharactersNotBytes() {
    let name = String(repeating: "😀", count: 10)
    let result = FileService.sanitizeFilename(name, maxLength: 5)
    #expect(result == String(repeating: "😀", count: 4))
  }
}
