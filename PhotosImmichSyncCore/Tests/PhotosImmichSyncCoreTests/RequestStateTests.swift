import Foundation
import Testing

@testable import PhotosImmichSyncCore

/// Pins the claim/resume/cancel arbitration that keeps PhotoKit callback bridging
/// from double-resuming a continuation.
@Suite struct RequestStateTests {
  @Test func onlyTheFirstClaimGetsTheContinuation() async throws {
    let state = PhotosRequestState()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      state.attach(continuation)
      let first = state.claimResume()
      #expect(first != nil)
      #expect(state.claimResume() == nil)  // the losing path must drop its resume
      first?.resume()
    }
  }

  @Test func setIDReportsWhetherCancellationAlreadyArrived() {
    let early = PhotosRequestState()
    #expect(early.setID(7) == false)  // no cancel yet: caller proceeds
    #expect(early.requestID() == 7)

    let late = PhotosRequestState()
    #expect(late.markCancelled() == nil)  // cancelled before the ID was known
    #expect(late.setID(9) == true)  // caller must immediately cancel request 9
  }

  @Test func markCancelledReturnsTheKnownRequestID() {
    let state = PhotosRequestState()
    _ = state.setID(42)
    #expect(state.markCancelled() == 42)
  }

  @Test func dataAcceptanceStopsAfterResumeOrWriteError() {
    struct WriteFailure: Error {}

    let resumed = PhotosRequestState()
    #expect(resumed.shouldAcceptData())
    _ = resumed.claimResume()
    #expect(!resumed.shouldAcceptData())

    let failed = PhotosRequestState()
    _ = failed.setID(1)
    #expect(failed.recordWriteError(WriteFailure()) == 1)
    #expect(!failed.shouldAcceptData())
  }

  @Test func firstWriteErrorWinsAndConsumeClears() {
    struct First: Error {}
    struct Second: Error {}
    let state = PhotosRequestState()
    _ = state.recordWriteError(First())
    _ = state.recordWriteError(Second())  // dropped

    #expect(state.consumeWriteError() is First)
    #expect(state.consumeWriteError() == nil)
  }
}
