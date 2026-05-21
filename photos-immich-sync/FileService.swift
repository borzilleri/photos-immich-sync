import CryptoKit
import Photos
import UniformTypeIdentifiers

let CHANGE_TOKEN_FILE = "photos_change_token.data"

public enum ChangeTokenError: Error {
  case decode(underlying: Error)
}

public enum ExportError: Error {
  case iCloudDownloadFailed(_ cause: Error?, filename: String)
  case assetUnavailable(_ reason: String, filename: String)
  case timeout(filename: String)
  case exportFailed(_ cause: Error, filename: String)
  case dataMissing(filename: String)

  public var canRetry: Bool {
    switch self {
    case .iCloudDownloadFailed, .timeout, .dataMissing:
      return true
    case .assetUnavailable, .exportFailed:
      return false
    }
  }
}

/// Continuation + cancellation state for a single PhotoKit request.
///
/// PhotoKit's `requestImageDataAndOrientation` and `requestData` deliver their
/// results via Objective-C callbacks. Bridging them with
/// `withCheckedThrowingContinuation` is straightforward but isn't cancellation
/// aware: if the surrounding Task is cancelled (e.g. by `performWithTimeout`),
/// the underlying request keeps running until PhotoKit fires its handler.
///
/// This class arbitrates which path - the result/completion handler or the
/// task-cancellation handler - gets to resume the continuation, and stores the
/// PhotoKit request ID so the cancel path can call `cancelImageRequest` /
/// `cancelDataRequest`. The resource path additionally records the first
/// `FileHandle.write(contentsOf:)` failure (H3) so it can be surfaced through
/// the continuation.
private final class PhotosRequestState: @unchecked Sendable {
  private let lock = NSLock()
  private var requestID_: Int32? = nil
  private var continuation_: CheckedContinuation<Void, Error>? = nil
  private var resumed_: Bool = false
  private var pendingError_: Error? = nil
  private var cancelled_: Bool = false

  func attach(_ continuation: CheckedContinuation<Void, Error>) {
    lock.lock()
    defer { lock.unlock() }
    continuation_ = continuation
  }

  /// Records the PhotoKit request ID. Returns `true` if cancellation arrived
  /// before the ID was known - the caller must immediately cancel the
  /// just-issued request.
  func setID(_ id: Int32) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    requestID_ = id
    return cancelled_
  }

  /// Returns the PhotoKit request ID, if recorded.
  func requestID() -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    return requestID_
  }

  /// Returns the continuation iff the caller is the first to claim resume.
  /// Subsequent callers (whether the result handler or `onCancel`) get `nil`
  /// and must drop their resume attempt.
  func claimResume() -> CheckedContinuation<Void, Error>? {
    lock.lock()
    defer { lock.unlock() }
    if resumed_ { return nil }
    resumed_ = true
    let c = continuation_
    continuation_ = nil
    return c
  }

  /// Marks the state as cancelled and returns the request ID (if known) so the
  /// caller can issue a PhotoKit cancel.
  func markCancelled() -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    cancelled_ = true
    return requestID_
  }

  /// Quick check used by `dataReceivedHandler` to skip work after cancel/resume.
  func shouldAcceptData() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !resumed_ && pendingError_ == nil
  }

  /// Stores the first write error and returns the request ID so the caller can
  /// cancel the resource request. Subsequent errors are dropped.
  func recordWriteError(_ error: Error) -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    if pendingError_ == nil {
      pendingError_ = error
    }
    return requestID_
  }

  /// Reads (and clears) the recorded write error, used by the completion
  /// handler to prefer write failures over PhotoKit's own completion error.
  func consumeWriteError() -> Error? {
    lock.lock()
    defer { lock.unlock() }
    let e = pendingError_
    pendingError_ = nil
    return e
  }
}

public struct FileService {
  private static let log = Log.forCategory("FileService")

  let changeTokenFile: URL
  let workDir: URL
  let dataDir: URL

  init() throws {
    self.workDir = try FileService.makeTempDir()
    self.dataDir = try FileService.makeStorageDir()
    self.changeTokenFile = self.dataDir.appendingPathComponent(CHANGE_TOKEN_FILE, isDirectory: false)
  }

  internal static func makeTempDir() throws -> URL {
    let dirName = "\(Date().timeIntervalSince1970)_\(UUID().uuidString)"
    let caches = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let workDir = caches.appendingPathComponent("\(IMMICH_DEVICE_ID)/\(dirName)", isDirectory: true)
    if !FileManager.default.fileExists(atPath: workDir.path) {
      try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }
    return workDir
  }

  /// Returns a filesystem-safe filename for use as a single path component.
  ///
  /// Replaces path separators, NUL, and control characters with `_`, then clamps
  /// the result while preserving any file extension. Always returns a non-empty
  /// string.
  static func sanitizeFilename(_ raw: String, maxLength: Int = 120) -> String {
    let disallowed = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
    var cleaned = String()
    cleaned.reserveCapacity(raw.unicodeScalars.count)
    for scalar in raw.unicodeScalars {
      if disallowed.contains(scalar) {
        cleaned.append("_")
      } else {
        cleaned.unicodeScalars.append(scalar)
      }
    }
    let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
    let safe = trimmed.isEmpty ? "file" : trimmed
    if safe.count <= maxLength { return safe }
    let ext = (safe as NSString).pathExtension
    let base = (safe as NSString).deletingPathExtension
    let budget = max(1, maxLength - ext.count - 1)
    let clamped = String(base.prefix(budget))
    return ext.isEmpty ? clamped : "\(clamped).\(ext)"
  }

  internal static func makeStorageDir() throws -> URL {
    let supportDir = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dataDir = supportDir.appendingPathComponent(APP_NAME, isDirectory: true)
    if !FileManager.default.fileExists(atPath: dataDir.path) {
      try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }
    return dataDir
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: self.workDir)
  }

  func convertError(error: Error, filename: String) -> ExportError {
    let nsError = error as NSError

    // Check for PHPhotosErrorDomain errors
    if nsError.domain == "PHPhotosErrorDomain" {
      switch nsError.code {
      case -1:
        // PHPhotosErrorDomain Code=-1 often indicates iCloud issues
        return .iCloudDownloadFailed(error, filename: filename)
      case 3311:
        // Authorization issue
        return .assetUnavailable("Authorization denied", filename: filename)
      case 3164:
        // Asset not available
        return .assetUnavailable("Asset not found", filename: filename)
      default:
        break
      }
    }

    // Check for CloudPhotoLibraryErrorDomain
    if nsError.domain == "CloudPhotoLibraryErrorDomain" {
      return .iCloudDownloadFailed(error, filename: filename)
    }

    // Check for NSCocoaErrorDomain errors
    if nsError.domain == NSCocoaErrorDomain {
      switch nsError.code {
      case 4101:
        // "Couldn't communicate with a helper application"
        // Check underlying error for CloudPhotoLibrary issues
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
          underlying.domain == "CloudPhotoLibraryErrorDomain"
        {
          return .iCloudDownloadFailed(error, filename: filename)
        }
        return .exportFailed(error, filename: filename)
      case 4097:  // Connection service issue
        return .iCloudDownloadFailed(error, filename: filename)
      case -1:  // Generic error, often iCloud-related
        return .iCloudDownloadFailed(error, filename: filename)
      default:
        break
      }
    }

    // Check for network-related errors
    if nsError.domain == NSURLErrorDomain {
      switch nsError.code {
      case NSURLErrorTimedOut:
        return .timeout(filename: filename)
      case NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost:
        return .iCloudDownloadFailed(error, filename: filename)
      default:
        break
      }
    }

    // Default: non-retryable export failure
    return .exportFailed(error, filename: filename)
  }

  private func canRetryAfterFailure(_ error: Error, filename: String) -> Bool {
    if error is TimeoutError { return true }
    if let export = error as? ExportError { return export.canRetry }
    return convertError(error: error, filename: filename).canRetry
  }

  private func removePartialFile(at url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// One attempt, no timeout wrapper (outer loop applies per-attempt timeout and retries).
  private func downloadAndHashImageSingleAttempt(
    _ asset: PHAsset, to destination: URL
  ) async throws -> (String, URL) {
    var targetFile = destination
    do {
      let options = PHImageRequestOptions()
      options.deliveryMode = .highQualityFormat
      options.isNetworkAccessAllowed = true
      options.isSynchronous = false

      // Immich Uses SHA1 to calcualte file hashes, so we need to do the same.
      var hasher = Insecure.SHA1()
      var data: Data?
      var dataUTI: String?

      let state = PhotosRequestState()
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          state.attach(continuation)
          let id = PHImageManager.default().requestImageDataAndOrientation(
            for: asset,
            options: options,
            resultHandler: { imageData, imageUTI, _, info in
              guard let cont = state.claimResume() else { return }
              if let err = info?[PHImageErrorKey] as? NSError {
                cont.resume(throwing: err)
              } else {
                data = imageData
                dataUTI = imageUTI
                cont.resume()
              }
            }
          )
          if state.setID(Int32(id)) {
            // Cancellation arrived before the PhotoKit request ID was known.
            PHImageManager.default().cancelImageRequest(id)
          }
        }
      } onCancel: {
        let id = state.markCancelled()
        if let id {
          PHImageManager.default().cancelImageRequest(PHImageRequestID(id))
        }
        if let cont = state.claimResume() {
          cont.resume(throwing: CancellationError())
        }
      }

      var ext = destination.pathExtension
      if let dataUTI, let uti = UTType(dataUTI) {
        ext = uti.preferredFilenameExtension?.lowercased() ?? ext
      }
      targetFile = destination.deletingPathExtension().appendingPathExtension(ext)

      if let data {
        FileManager.default.createFile(atPath: targetFile.path, contents: nil)
        hasher.update(data: data)
        try data.write(to: targetFile)
        let sha1 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (sha1, targetFile)
      } else {
        throw ExportError.dataMissing(filename: targetFile.path)
      }
    } catch {
      removePartialFile(at: targetFile)
      if targetFile != destination {
        removePartialFile(at: destination)
      }
      throw error
    }
  }

  /// One resource download attempt (no timeout wrapper; outer loop applies).
  private func downloadAndHashResourceSingleAttempt(
    _ res: PHAssetResource, to destination: URL
  ) async throws -> String {
    do {
      FileManager.default.createFile(atPath: destination.path, contents: nil)

      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = true

      let handle = try FileHandle(forWritingTo: destination)
      defer { try? handle.close() }
      // Immich Uses SHA1 to calcualte file hashes, so we need to do the same.
      var hasher = Insecure.SHA1()

      let state = PhotosRequestState()
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          state.attach(continuation)
          let id = PHAssetResourceManager.default().requestData(
            for: res,
            options: options,
            dataReceivedHandler: { data in
              guard state.shouldAcceptData() else { return }
              do {
                try handle.write(contentsOf: data)
                hasher.update(data: data)
              } catch {
                if let id = state.recordWriteError(error) {
                  PHAssetResourceManager.default().cancelDataRequest(PHAssetResourceDataRequestID(id))
                }
              }
            },
            completionHandler: { error in
              guard let cont = state.claimResume() else { return }
              let effective = state.consumeWriteError() ?? error
              if let effective {
                cont.resume(throwing: effective)
              } else {
                cont.resume()
              }
            }
          )
          if state.setID(Int32(id)) {
            // Cancellation arrived before the PhotoKit request ID was known.
            PHAssetResourceManager.default().cancelDataRequest(id)
          }
        }
      } onCancel: {
        let id = state.markCancelled()
        if let id {
          PHAssetResourceManager.default().cancelDataRequest(PHAssetResourceDataRequestID(id))
        }
        if let cont = state.claimResume() {
          cont.resume(throwing: CancellationError())
        }
      }

      let sha1 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      return sha1
    } catch {
      removePartialFile(at: destination)
      throw error
    }
  }

  func downloadAndHashImage(
    _ asset: PHAsset, to destination: URL, withRetry: RetryConfig
  ) async throws -> (String, URL) {
    let filename = destination.path
    for attempt in 1...withRetry.maxAttempts {
      do {
        return try await performWithTimeout(of: withRetry.timeout) {
          try await self.downloadAndHashImageSingleAttempt(asset, to: destination)
        }
      } catch {
        removePartialFile(at: destination)
        if !self.canRetryAfterFailure(error, filename: filename) || attempt == withRetry.maxAttempts {
          throw error
        }
        let waitSeconds = min(attempt, 5)
        let backoff = Duration.seconds(waitSeconds)
        Self.log.info(
          "Download (image) attempt \(attempt)/\(withRetry.maxAttempts) failed for \(destination.lastPathComponent); retrying after ~\(waitSeconds) seconds",
          cause: error
        )
        do {
          try await Task.sleep(for: backoff)
        } catch {
          throw error
        }
      }
    }
    preconditionFailure("unreachable: downloadAndHashImage retry loop")
  }

  func downloadAndHashResource(
    _ res: PHAssetResource, to destination: URL, withRetry: RetryConfig
  ) async throws
    -> String
  {
    let filename = res.originalFilename
    for attempt in 1...withRetry.maxAttempts {
      do {
        return try await performWithTimeout(of: withRetry.timeout) {
          try await self.downloadAndHashResourceSingleAttempt(res, to: destination)
        }
      } catch {
        removePartialFile(at: destination)
        if !self.canRetryAfterFailure(error, filename: filename) || attempt == withRetry.maxAttempts {
          throw error
        }
        let waitSeconds = min(attempt, 5)
        let backoff = Duration.seconds(waitSeconds)
        Self.log.info(
          "Download (resource) attempt \(attempt)/\(withRetry.maxAttempts) failed for \(filename); retrying after ~\(waitSeconds) seconds",
          cause: error
        )
        do {
          try await Task.sleep(for: backoff)
        } catch {
          throw error
        }
      }
    }
    preconditionFailure("unreachable: downloadAndHashResource retry loop")
  }

  func copyFile(fromPath sourcePath: String, toPath targetPath: String) throws {
    if FileManager.default.fileExists(atPath: targetPath) {
      try FileManager.default.removeItem(atPath: targetPath)
    }
    try FileManager.default.copyItem(atPath: sourcePath, toPath: targetPath)
  }

  func writeChangeToken(_ token: PHPersistentChangeToken) throws {
    let tokenData = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    try tokenData.write(to: self.changeTokenFile)
  }

  func loadChangeToken() throws -> PHPersistentChangeToken? {
    guard FileManager.default.fileExists(atPath: self.changeTokenFile.path) else {
      return nil
    }
    do {
      let data = try Data(contentsOf: self.changeTokenFile)
      return try NSKeyedUnarchiver.unarchivedObject(
        ofClass: PHPersistentChangeToken.self, from: data)
    } catch {
      throw ChangeTokenError.decode(underlying: error)
    }
  }
}
