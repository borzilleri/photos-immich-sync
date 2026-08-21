import Foundation
import Testing

@testable import PhotosImmichSyncCore

private actor GateCounter {
  private(set) var current = 0
  private(set) var peak = 0

  func enter() {
    current += 1
    peak = max(peak, current)
  }

  func exit() { current -= 1 }
}

@Suite struct ConcurrencyTests {
  // MARK: AsyncSemaphore

  @Test func semaphoreNeverExceedsMaxConcurrency() async throws {
    let semaphore = AsyncSemaphore(maxConcurrentTasks: 3)
    let counter = GateCounter()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<24 {
        group.addTask {
          try await semaphore.withSlot {
            await counter.enter()
            try await Task.sleep(for: .milliseconds(2))
            await counter.exit()
          }
        }
      }
      try await group.waitForAll()
    }
    let peak = await counter.peak
    #expect(peak <= 3)
    #expect(peak > 0)
    let current = await counter.current
    #expect(current == 0)
  }

  @Test func withSlotReleasesOnThrow() async throws {
    struct Boom: Error {}
    let semaphore = AsyncSemaphore(maxConcurrentTasks: 1)
    await #expect(throws: Boom.self) {
      try await semaphore.withSlot { throw Boom() }
    }
    // The slot must be free again: a second use completes rather than hanging.
    let value = try await semaphore.withSlot { 42 }
    #expect(value == 42)
  }

  @Test func cancellingAWaiterThrowsAndPreservesTheSlot() async throws {
    let semaphore = AsyncSemaphore(maxConcurrentTasks: 1)
    try await semaphore.acquire()  // hold the only slot

    let waiter = Task {
      try await semaphore.withSlot { Issue.record("cancelled waiter must not run its work") }
    }
    try await Task.sleep(for: .milliseconds(20))  // let the waiter enqueue
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }

    await semaphore.release()
    // Slot still usable after the cancelled waiter is cleaned up.
    let value = try await semaphore.withSlot { "ok" }
    #expect(value == "ok")
  }

  // MARK: performWithTimeout

  @Test func timeoutReturnsWorkResultWhenItFinishesFirst() async throws {
    let result = try await performWithTimeout(of: .seconds(5)) { "done" }
    #expect(result == "done")
  }

  @Test func timeoutThrowsTimeoutErrorWhenWorkIsTooSlow() async throws {
    await #expect(throws: TimeoutError.self) {
      try await performWithTimeout(of: .milliseconds(20)) {
        try await Task.sleep(for: .seconds(10))
      }
    }
  }

  @Test func timeoutPropagatesWorkErrors() async throws {
    struct Boom: Error {}
    await #expect(throws: Boom.self) {
      try await performWithTimeout(of: .seconds(5)) { throw Boom() }
    }
  }

  @Test func outerCancellationSurfacesAsCancellationNotTimeout() async throws {
    let task = Task {
      try await performWithTimeout(of: .seconds(30)) {
        try await Task.sleep(for: .seconds(30))
      }
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
