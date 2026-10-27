import Foundation
import NIOConcurrencyHelpers
import Testing
import os

@testable import PhotosImmichSyncCore

@Suite struct LogSinkTests {
  private let osLogger = Logger(subsystem: "test", category: "test")

  private func emit(_ sink: LogSink, _ level: EmitLevel) {
    sink.emit(
      level: level, category: "Test", osLogger: osLogger,
      message: "m", stage: nil, context: [:], cause: nil, sourceLocation: nil)
  }

  @Test func countersTrackErrorsAndWarningsOnly() {
    let sink = LogSink()
    sink.configure(verbosity: .quiet)  // keep test output off the console
    emit(sink, .error)
    emit(sink, .error)
    emit(sink, .warning)
    emit(sink, .info)
    emit(sink, .progress)
    emit(sink, .debug)
    emit(sink, .trace)

    let summary = sink.summary()
    #expect(summary.errors == 2)
    #expect(summary.warnings == 1)
    #expect(summary.hasErrors)
    #expect(summary.hasWarnings)
  }

  @Test func freshSinkStartsAtZero() {
    let summary = LogSink().summary()
    #expect(summary.errors == 0)
    #expect(summary.warnings == 0)
  }

  @Test func beginRunResetsCountersForTheNextRun() {
    let sink = LogSink()
    sink.configure(verbosity: .quiet)
    emit(sink, .error)
    emit(sink, .warning)
    sink.beginRun()
    #expect(sink.summary().errors == 0)
    #expect(sink.summary().warnings == 0)
    // The next run tallies independently.
    emit(sink, .warning)
    #expect(sink.summary().warnings == 1)
  }

  // MARK: observers

  @Test func observersReceiveEveryRecordRegardlessOfVerbosity() {
    let sink = LogSink()
    sink.configure(verbosity: .quiet)  // console fully gated; observers must not be
    let received = NIOLockedValueBox<[LogRecord]>([])
    sink.addObserver { record in received.withLockedValue { $0.append(record) } }

    emit(sink, .error)
    emit(sink, .trace)
    emit(sink, .progress)

    let levels = received.withLockedValue { $0.map(\.level) }
    #expect(levels == [.error, .trace, .progress])
  }

  @Test func multipleObserversAllFire() {
    let sink = LogSink()
    sink.configure(verbosity: .quiet)
    let first = NIOLockedValueBox(0)
    let second = NIOLockedValueBox(0)
    sink.addObserver { _ in first.withLockedValue { $0 += 1 } }
    sink.addObserver { _ in second.withLockedValue { $0 += 1 } }

    emit(sink, .info)

    #expect(first.withLockedValue { $0 } == 1)
    #expect(second.withLockedValue { $0 } == 1)
  }

  @Test func recordCarriesAllStructuredFields() {
    struct Boom: Error {}
    let sink = LogSink()
    sink.configure(verbosity: .quiet)
    let received = NIOLockedValueBox<[LogRecord]>([])
    sink.addObserver { record in received.withLockedValue { $0.append(record) } }

    let before = Date()
    sink.emit(
      level: .warning, category: "Cat", osLogger: osLogger,
      message: "msg", stage: .uploadAsset, context: [.filename: "f.jpg"],
      cause: Boom(), sourceLocation: "File.swift:1:fn()")

    let record = received.withLockedValue { $0.first }
    #expect(record?.level == .warning)
    #expect(record?.category == "Cat")
    #expect(record?.message == "msg")
    #expect(record?.stage == .uploadAsset)
    #expect(record?.context == [.filename: "f.jpg"])
    #expect(record?.causeDescription?.isEmpty == false)
    #expect(record?.sourceLocation == "File.swift:1:fn()")
    #expect(record.map { $0.timestamp >= before } == true)
  }

  // The doc-comment verbosity table in Logging.swift, as a test matrix:
  // errors always; warnings/progress at normal+; info at -v; debug at -vv; trace at -vvv.
  @Test(arguments: [
    (EmitLevel.error, Verbosity.quiet, true),
    (.error, .trace, true),
    (.warning, .quiet, false),
    (.warning, .normal, true),
    (.progress, .quiet, false),
    (.progress, .normal, true),
    (.info, .normal, false),
    (.info, .verbose, true),
    (.debug, .verbose, false),
    (.debug, .debug, true),
    (.trace, .debug, false),
    (.trace, .trace, true),
  ])
  func consoleGatingFollowsTheVerbosityTable(level: EmitLevel, verbosity: Verbosity, expected: Bool) {
    #expect(LogSink.shouldEmitToConsole(level: level, verbosity: verbosity) == expected)
  }

  // MARK: formatting

  @Test func formatBaseCombinesTagAndStage() {
    let line = LogSink.formatBase(
      category: "Immich", level: .error, message: "boom", stage: .uploadAsset, context: [:])
    #expect(line == "Immich: [CRITICAL:uploadAsset] boom")
  }

  @Test func formatBaseTagOnlyAndStageOnlyAndPlain() {
    #expect(
      LogSink.formatBase(category: "C", level: .warning, message: "m", stage: nil, context: [:])
        == "C: [WARN] m")
    // progress has no tag: stage-only branch
    #expect(
      LogSink.formatBase(category: "C", level: .progress, message: "m", stage: .exportAssets, context: [:])
        == "C: [exportAssets] m")
    #expect(
      LogSink.formatBase(category: "C", level: .progress, message: "m", stage: nil, context: [:])
        == "C: m")
  }

  @Test func formatBaseAppendsSortedContext() {
    let line = LogSink.formatBase(
      category: "C", level: .info, message: "m", stage: nil,
      context: [.localIdentifier: "L1", .filename: "f.jpg", .assetType: "original"])
    #expect(line == "C: [INFO] m\n>> context: assetType:original, filename:f.jpg, localIdentifier:L1")
  }

  @Test func formatDetailRendersLocationAndCause() {
    struct Boom: Error {}
    let detail = LogSink.formatDetail(sourceLocation: "File.swift:1:fn()", cause: Boom())
    #expect(detail.hasPrefix("\n>> in File.swift:1:fn()"))
    #expect(detail.contains("\n>> caused by: "))
    #expect(LogSink.formatDetail(sourceLocation: nil, cause: nil) == "")
  }
}
