import Foundation
import Testing

@testable import PhotosImmichSyncCore

@Suite struct DateTranscoderTests {
  private let transcoder = CustomDateTranscoder()

  @Test func decodesFractionalSecondsFirst() throws {
    let date = try transcoder.decode("2024-01-02T03:04:05.678Z")
    #expect(abs(date.timeIntervalSince1970 - 1_704_164_645.678) < 0.001)
  }

  @Test func fallsBackToWholeSeconds() throws {
    let date = try transcoder.decode("2024-01-02T03:04:05Z")
    #expect(date.timeIntervalSince1970 == 1_704_164_645)
  }

  @Test func rejectsNonISO8601Strings() {
    #expect(throws: DecodingError.self) {
      _ = try transcoder.decode("01/02/2024 03:04")
    }
  }

  @Test func encodeAlwaysEmitsFractionalSecondsAndRoundTrips() throws {
    let original = Date(timeIntervalSince1970: 1_704_164_645.5)
    let encoded = try transcoder.encode(original)
    #expect(encoded.contains("."))
    let decoded = try transcoder.decode(encoded)
    #expect(abs(decoded.timeIntervalSince1970 - original.timeIntervalSince1970) < 0.001)
  }
}
