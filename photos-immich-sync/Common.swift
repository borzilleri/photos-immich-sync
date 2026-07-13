import Foundation
import Photos

let IMMICH_SUPPORTED_VERSION_MAJOR = 3
let APP_NAME = "photos-immich-sync"
let IMMICH_DEVICE_ID = "io.rampant.photos-immich-sync"
let LOGGER_SUBSYSTEM = "photos-immich-sync"

enum TimeoutError: Error {
  case timeout
}

enum BurstType: String, Codable {
  case all
  case none
  case selected
}

public enum AssetType: String, Comparable, CaseIterable, Sendable {
  case original
  case livephoto
  case alternate
  case edited

  // LivePhoto should be ordered first, to ensure we have an immich id to populate into the original asset.
  var order: Int {
    switch self {
    case .livephoto: return 10
    case .edited: return 20
    case .original: return 30
    case .alternate: return 40
    }
  }

  func assetIdentifier(id: String) -> String {
    return "\(id)\(self.rawValue)"
  }

  public static func < (lhs: AssetType, rhs: AssetType) -> Bool {
    lhs.order < rhs.order
  }
}

public struct DeltaPhotosExport {
  let upsertedBundles: [AssetBundle]
  let deletedAssets: [String]
  let keywords: [PhotosKeyword]?
  let upsertedAlbums: [PhotosAlbum]
  let deletedAlbums: [String]
}

public struct FullPhotosExport {
  let assetBundles: [AssetBundle]
  let keywords: [PhotosKeyword]?
  let albums: [PhotosAlbum]
}

public struct AssetBundle: CustomStringConvertible {
  let asset: PHAsset
  let cloudIdentifier: String?
  let resources: [AssetType: PHAssetResource]
  let burstIdentifier: String?

  var title: String? = nil
  var caption: String? = nil

  public func getAssetIdentifier(for type: AssetType) -> String {
    return type.assetIdentifier(id: asset.localIdentifier)
  }

  public func getImmichDescription() -> String? {
    // Compile title & caption into single description
    var description: String? = nil
    if let title {
      description = title
    }
    if let caption {
      if let existingDescription = description {
        description = "\(existingDescription)\n\n\(caption)"
      } else {
        description = caption
      }
    }
    return description
  }

  public var description: String {
    return
      "AsstBundle(cloudId:\(cloudIdentifier ?? "nil"); localId:\(asset.localIdentifier); type:\(asset.mediaType); "
      + "resources:\(resources.keys.map(\.rawValue)); title:\(title ?? "-"); caption:\(caption ?? "-"))"
  }
}

public struct PhotosKeyword {
  let keyword: String
  let assetIds: [String]
}

public struct PhotosAlbum {
  let localIdentifier: String
  let folderPath: [String]
  let assetIds: [String]
  let nameChangeOnly: Bool

  public func getName(separator: String) -> String {
    return folderPath.joined(separator: "\(separator)")
  }
}

/// Continuation-backed async semaphore that gates concurrent work across actors and
/// task groups. FIFO fair, cancellation-safe.
public actor AsyncSemaphore {
  private let maxConcurrentTasks: Int
  private var inflight: Int = 0
  private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

  init(maxConcurrentTasks: Int) {
    precondition(maxConcurrentTasks >= 1, "AsyncSemaphore maxConcurrentTasks must be at least 1")
    self.maxConcurrentTasks = maxConcurrentTasks
  }

  func acquire() async throws {
    if waiters.isEmpty && inflight < maxConcurrentTasks {
      inflight += 1
      // Honor cancellation that arrived between the slot grant and our return.
      if Task.isCancelled {
        release()
        throw CancellationError()
      }
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        waiters.append((id, cont))
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }
    // A waiter resumed by `release()` may still have been cancelled in the gap before
    // it ran. `cancelWaiter` is a no-op once the waiter is removed from the queue, so
    // the slot has effectively been handed to us; return it so the count stays balanced.
    if Task.isCancelled {
      release()
      throw CancellationError()
    }
  }

  private func cancelWaiter(id: UUID) {
    if let idx = waiters.firstIndex(where: { $0.id == id }) {
      let removed = waiters.remove(at: idx)
      removed.continuation.resume(throwing: CancellationError())
    }
  }

  func release() {
    if let next = waiters.first {
      waiters.removeFirst()
      next.continuation.resume()
      // Slot is handed off; inflight count unchanged.
    } else {
      inflight -= 1
    }
  }

  /// Acquires a slot, runs `work`, and releases the slot on every exit path
  /// (normal return, throw, or `CancellationError` propagated through `work`).
  /// `rethrows` so non-throwing work bodies stay non-throwing at the call site.
  nonisolated func withSlot<T>(_ work: () async throws -> T) async throws -> T {
    try await acquire()
    do {
      let result = try await work()
      await release()
      return result
    } catch {
      await release()
      throw error
    }
  }
}

/// Formats a duration in seconds as `HH:MM:SS.ffffff`, the format Immich expects for the
/// upload `duration` form field. Negative inputs are clamped to zero.
func formatImmichDuration(_ seconds: TimeInterval) -> String {
  let total = max(0, min(seconds, Double(Int.max)))
  let hours = Int(total) / 3600
  let minutes = (Int(total) % 3600) / 60
  let secs = total.truncatingRemainder(dividingBy: 60)
  return String(format: "%02d:%02d:%09.6f", hours, minutes, secs)
}

/// Runs `work` and a `Task.sleep`-based watchdog concurrently. If the watchdog
/// fires first it cancels `work` and `TimeoutError.timeout` is thrown; otherwise
/// `work`'s result is returned and the watchdog is cancelled. Cancellation of the
/// surrounding task is forwarded to `work` and surfaced as `CancellationError`.
///
/// `work` is `@isolated(any)` so it carries its own isolation and can be handed
/// straight to `Task.init(operation:)` as a `sending` value. A `withThrowingTaskGroup`
/// shape doesn't work here in Swift 6: the group body is task-isolated, so capturing
/// `work` into it would land it in a task-isolated region and trip region-isolation
/// checks when `addTask` later tries to transfer it. Using an unstructured `Task`
/// keeps `work` in the caller's region and transfers it exactly once.
func performWithTimeout<T: Sendable>(
  of timeout: Duration,
  _ work: sending @escaping @isolated(any) () async throws -> T
) async throws -> T {
  let workTask = Task<T, Error>(operation: work)
  let watchdog = Task<Void, Never> {
    do {
      try await Task.sleep(until: .now + timeout)
      workTask.cancel()
    } catch {
      // Watchdog itself was cancelled; `work` already finished or threw.
    }
  }
  defer { watchdog.cancel() }
  do {
    return try await withTaskCancellationHandler {
      try await workTask.value
    } onCancel: {
      // Unstructured `Task` does not inherit parent cancellation; forward it.
      workTask.cancel()
    }
  } catch is CancellationError {
    // If the surrounding task was cancelled, propagate that. Otherwise the only
    // remaining cause for the work task's cancellation is our own watchdog.
    if Task.isCancelled {
      throw CancellationError()
    }
    throw TimeoutError.timeout
  }
}

struct RetryConfig {
  var maxAttempts: Int
  var timeout: Duration
}
