import Foundation
import NIOCore
import Testing

@testable import PhotosImmichSyncCore

@Suite struct CommonTests {
  // Live photo must sort first so its immich id exists before the original uploads
  // (`syncAssetBundle` relies on this ordering).
  @Test func assetTypeOrderingIsUploadOrder() {
    let sorted = ([.original, .alternate, .livephoto, .edited] as [AssetType]).sorted()
    #expect(sorted == [.livephoto, .edited, .original, .alternate])
  }

  @Test func albumNameJoinsFolderPath() {
    func album(_ path: [String]) -> PhotosAlbum {
      PhotosAlbum(localIdentifier: "A1", folderPath: path, assetIds: [], nameChangeOnly: false)
    }
    #expect(album(["Trips", "2024", "Japan"]).getName(separator: " / ") == "Trips / 2024 / Japan")
    #expect(album(["Solo"]).getName(separator: " / ") == "Solo")
    #expect(album([]).getName(separator: " / ") == "")
    #expect(album(["a", "b"]).getName(separator: "") == "ab")
  }

  @Test(arguments: [
    (0.0, "00:00:00.000000"),
    (-5.0, "00:00:00.000000"),
    (1.5, "00:00:01.500000"),
    (59.25, "00:00:59.250000"),
    // %09.6f rounds up at the format boundary; Immich receives "60" seconds. Pinned as-is.
    (59.9999995, "00:00:60.000000"),
    (3661.25, "01:01:01.250000"),
    (86399.0, "23:59:59.000000"),
    (360000.0, "100:00:00.000000"),
  ])
  func immichDurationFormatting(seconds: Double, expected: String) {
    #expect(formatImmichDuration(seconds) == expected)
  }

  @Test func durationToTimeAmountConverts() {
    #expect(Duration.seconds(2).toTimeAmount() == .nanoseconds(2_000_000_000))
    #expect(Duration.milliseconds(1500).toTimeAmount() == .nanoseconds(1_500_000_000))
    #expect(Duration.zero.toTimeAmount() == .nanoseconds(0))
  }

  @Test func durationToTimeAmountSaturatesOnOverflow() {
    #expect(Duration.seconds(Int64.max).toTimeAmount() == .nanoseconds(Int64.max))
  }
}
