import Foundation
import Testing

@testable import PhotosImmichSyncCore

@Suite struct FileServiceTests {
  // MARK: ExportError.canRetry

  @Test func exportErrorRetryability() {
    struct Boom: Error {}
    #expect(ExportError.iCloudDownloadFailed(nil, filename: "f").canRetry)
    #expect(ExportError.timeout(filename: "f").canRetry)
    #expect(ExportError.dataMissing(filename: "f").canRetry)
    #expect(!ExportError.assetUnavailable("gone", filename: "f").canRetry)
    #expect(!ExportError.exportFailed(Boom(), filename: "f").canRetry)
  }

  // MARK: convertError NSError classification

  enum ExpectedCase {
    case iCloud, assetUnavailable, timeout, exportFailed
  }

  private static func matches(_ error: ExportError, _ expected: ExpectedCase) -> Bool {
    switch (error, expected) {
    case (.iCloudDownloadFailed, .iCloud),
      (.assetUnavailable, .assetUnavailable),
      (.timeout, .timeout),
      (.exportFailed, .exportFailed):
      return true
    default:
      return false
    }
  }

  @Test(arguments: [
    ("PHPhotosErrorDomain", -1, ExpectedCase.iCloud),
    ("PHPhotosErrorDomain", 3311, .assetUnavailable),
    ("PHPhotosErrorDomain", 3164, .assetUnavailable),
    ("PHPhotosErrorDomain", 9999, .exportFailed),
    ("CloudPhotoLibraryErrorDomain", 123, .iCloud),
    (NSCocoaErrorDomain, 4097, .iCloud),
    (NSCocoaErrorDomain, -1, .iCloud),
    (NSCocoaErrorDomain, 4101, .exportFailed),  // no underlying cloud error
    (NSCocoaErrorDomain, 260, .exportFailed),
    (NSURLErrorDomain, NSURLErrorTimedOut, .timeout),
    (NSURLErrorDomain, NSURLErrorNotConnectedToInternet, .iCloud),
    (NSURLErrorDomain, NSURLErrorNetworkConnectionLost, .iCloud),
    (NSURLErrorDomain, NSURLErrorCannotConnectToHost, .iCloud),
    (NSURLErrorDomain, NSURLErrorBadURL, .exportFailed),
    ("SomeOtherDomain", 1, .exportFailed),
  ])
  func convertErrorClassifiesByDomainAndCode(domain: String, code: Int, expected: ExpectedCase) {
    let converted = FileService.convertError(error: NSError(domain: domain, code: code), filename: "f.jpg")
    #expect(Self.matches(converted, expected), "\(domain)/\(code) → \(converted)")
  }

  @Test func cocoa4101WithUnderlyingCloudErrorIsRetryableICloudFailure() {
    let underlying = NSError(domain: "CloudPhotoLibraryErrorDomain", code: 7)
    let error = NSError(domain: NSCocoaErrorDomain, code: 4101, userInfo: [NSUnderlyingErrorKey: underlying])
    let converted = FileService.convertError(error: error, filename: "f.jpg")
    #expect(Self.matches(converted, .iCloud))
    #expect(converted.canRetry)
  }

  // MARK: FileByteSequence

  @Test func byteSequenceChunksExactly() async throws {
    let dir = try makeTempTestDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("data.bin")
    try Data((0..<25).map { UInt8($0) }).write(to: file)

    let sequence = FileByteSequence(url: file, chunkSize: 10)
    var chunks: [Int] = []
    var collected: [UInt8] = []
    for try await chunk in sequence {
      chunks.append(chunk.count)
      collected.append(contentsOf: chunk)
    }
    #expect(chunks == [10, 10, 5])
    #expect(collected == (0..<25).map { UInt8($0) })
  }

  @Test func byteSequenceSupportsReIteration() async throws {
    // Retried HTTP uploads re-iterate the same sequence; each pass gets a fresh handle.
    let dir = try makeTempTestDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("data.bin")
    try Data(repeating: 7, count: 100).write(to: file)

    let sequence = FileByteSequence(url: file, chunkSize: 64)
    for _ in 0..<2 {
      var total = 0
      for try await chunk in sequence { total += chunk.count }
      #expect(total == 100)
    }
  }

  @Test func byteSequenceOnEmptyFileYieldsNothing() async throws {
    let dir = try makeTempTestDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("empty.bin")
    try Data().write(to: file)

    var count = 0
    for try await _ in FileByteSequence(url: file) { count += 1 }
    #expect(count == 0)
  }

  @Test func byteSequenceThrowsOnMissingFile() async {
    let sequence = FileByteSequence(url: URL(fileURLWithPath: "/nonexistent/missing.bin"))
    await #expect(throws: (any Error).self) {
      for try await _ in sequence {}
    }
  }

  // MARK: copyFile / fileSize

  @Test func copyFileOverwritesExistingTarget() throws {
    let (fs, root) = try makeHermeticFileService()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = fs.workDir.appendingPathComponent("src.txt")
    let target = fs.workDir.appendingPathComponent("dst.txt")
    try "new-content".write(to: source, atomically: true, encoding: .utf8)
    try "old-content".write(to: target, atomically: true, encoding: .utf8)

    try fs.copyFile(fromPath: source.path, toPath: target.path)
    #expect(try String(contentsOf: target, encoding: .utf8) == "new-content")
  }

  @Test func fileSizeReportsBytesAndThrowsWhenMissing() throws {
    let (fs, root) = try makeHermeticFileService()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = fs.workDir.appendingPathComponent("sized.bin")
    try Data(repeating: 0, count: 1234).write(to: file)

    #expect(try fs.fileSize(at: file) == 1234)
    #expect(throws: (any Error).self) {
      _ = try fs.fileSize(at: fs.workDir.appendingPathComponent("missing.bin"))
    }
  }

  // MARK: change token (hermetic dataDir — never the real Application Support file)

  @Test func loadChangeTokenReturnsNilWhenFileIsMissing() throws {
    let (fs, root) = try makeHermeticFileService()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try fs.loadChangeToken() == nil)
  }

  @Test func loadChangeTokenWrapsCorruptDataInDecodeError() throws {
    let (fs, root) = try makeHermeticFileService()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("not an archive".utf8).write(to: fs.changeTokenFile)
    #expect(throws: ChangeTokenError.self) {
      _ = try fs.loadChangeToken()
    }
  }
}
