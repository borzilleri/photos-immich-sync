import Foundation
import os


/// Console verbosity, built from `--quiet` / repeated `-v` flags by `Verbosity.fromFlags`.
///
/// `os.Logger` always receives every level regardless of verbosity (the system handles
/// its own filtering). The verbosity gate only controls what reaches stdout/stderr.
///
/// Gating table:
///
/// | level      | quiet  | normal | verbose | debug  | trace  |
/// |------------|--------|--------|---------|--------|--------|
/// | error      | stderr | stderr | stderr  | stderr | stderr |
/// | warning    | -      | stderr | stderr  | stderr | stderr |
/// | progress   | -      | stdout | stdout  | stdout | stdout |
/// | info       | -      | -      | stdout  | stdout | stdout |
/// | debug      | -      | -      | -       | stdout | stdout |
/// | trace      | -      | -      | -       | -      | stdout |
enum Verbosity: Int, Comparable, Sendable {
  case quiet = 0
  case normal = 1
  case verbose = 2
  case debug = 3
  case trace = 4

  static func < (lhs: Verbosity, rhs: Verbosity) -> Bool { lhs.rawValue < rhs.rawValue }

  static func fromFlags(quiet: Bool, verbose: Int) -> Verbosity {
    if quiet { return .quiet }
    switch verbose {
    case ..<0, 0: return .normal
    case 1: return .verbose
    case 2: return .debug
    default: return .trace
    }
  }
}

struct RunSummary: Sendable {
  let errors: Int
  let warnings: Int

  var hasErrors: Bool { errors > 0 }
  var hasWarnings: Bool { warnings > 0 }
}

enum LogContextKey: String {
  case immichId
  case deviceAssetId
  case localIdentifier
  case assetType
  case filename
  case tagId
  case tagName
  case albumId
  case albumName
}

enum PipelineStage: String, Sendable {
  case exportAssets
  case exportKeywords
  case exportAssetMetadata
  case exportAlbums
  case fetchChanges
  case uploadAsset
  case deleteAsset
  case createAlbum
  case syncAlbum
  case deleteAlbum
  case createTag
  case syncTag
  case deleteTag
}

/// One emit level. Internal to the logging implementation; call sites pick a level by
/// calling `CategoryLog.error(...)`, `.warning(...)`, etc.
enum EmitLevel: Sendable {
  case error
  case warning
  case info
  case progress
  case debug
  case trace
}

/// Singleton sink shared by every `CategoryLog`. Owns the configured `Verbosity`,
/// the per-severity counters, and serializes writes to stdout/stderr so concurrent
/// log calls don't interleave their bytes.
///
/// Held mutable state lives behind a single `OSAllocatedUnfairLock`. The lock is
/// taken only for short bookkeeping + a single `FileHandle.write`; it does not span
/// the `os.Logger` call (which is already thread-safe on its own).
final class LogSink: @unchecked Sendable {
  fileprivate struct State {
    var verbosity: Verbosity = .normal
    var errors: Int = 0
    var warnings: Int = 0
  }

  private let lock = OSAllocatedUnfairLock(initialState: State())

  fileprivate func configure(verbosity: Verbosity) {
    lock.withLock { $0.verbosity = verbosity }
  }

  fileprivate func summary() -> RunSummary {
    lock.withLock { s in
      RunSummary(errors: s.errors, warnings: s.warnings)
    }
  }

  /// Emits one log line. Always writes to `osLogger`; conditionally writes to
  /// stdout/stderr depending on the configured verbosity; bumps the `RunSummary`
  /// counter for the two tracked levels (`.error` -> `errors`, `.warning` ->
  /// `warnings`).
  fileprivate func emit(
    level: EmitLevel,
    category: String,
    osLogger: Logger,
    message: String,
    stage: PipelineStage?,
    context: [LogContextKey: String],
    cause: Error?,
    sourceLocation: String?
  ) {
    let baseLine = LogSink.formatBase(
      category: category, level: level, message: message, stage: stage, context: context)
    let detailSuffix = LogSink.formatDetail(sourceLocation: sourceLocation, cause: cause)
    let fullLine = baseLine + detailSuffix

    switch level {
    case .error: osLogger.error("\(fullLine, privacy: .public)")
    case .warning: osLogger.warning("\(fullLine, privacy: .public)")
    case .info: osLogger.info("\(fullLine, privacy: .public)")
    case .progress: osLogger.notice("\(fullLine, privacy: .public)")
    case .debug: osLogger.debug("\(fullLine, privacy: .public)")
    case .trace: osLogger.debug("TRACE: \(fullLine, privacy: .public)")
    }

    lock.withLock { state in
      switch level {
      case .error: state.errors += 1
      case .warning: state.warnings += 1
      case .info, .progress, .debug, .trace: break
      }

      guard LogSink.shouldEmitToConsole(level: level, verbosity: state.verbosity) else {
        return
      }
      let includeDetail = state.verbosity >= .debug
      let consoleLine = (includeDetail ? fullLine : baseLine) + "\n"
      let bytes = Data(consoleLine.utf8)
      switch level {
      case .error, .warning:
        FileHandle.standardError.write(bytes)
      case .info, .progress, .debug, .trace:
        FileHandle.standardOutput.write(bytes)
      }
    }
  }

  private static func shouldEmitToConsole(level: EmitLevel, verbosity: Verbosity) -> Bool {
    switch level {
    case .error: return true
    case .warning: return verbosity >= .normal
    case .progress: return verbosity >= .normal
    case .info: return verbosity >= .verbose
    case .debug: return verbosity >= .debug
    case .trace: return verbosity >= .trace
    }
  }

  private static func formatBase(
    category: String,
    level: EmitLevel,
    message: String,
    stage: PipelineStage?,
    context: [LogContextKey: String]
  ) -> String {
    let tag = LogSink.tag(for: level)
    var line: String
    if let tag, let stage {
      line = "\(category): [\(tag):\(stage.rawValue)] \(message)"
    } else if let tag {
      line = "\(category): [\(tag)] \(message)"
    } else if let stage {
      line = "\(category): [\(stage.rawValue)] \(message)"
    } else {
      line = "\(category): \(message)"
    }
    if !context.isEmpty {
      let pairs = context
        .map { "\($0.key.rawValue):\($0.value)" }
        .sorted()
        .joined(separator: ", ")
      line += "\n>> context: \(pairs)"
    }
    return line
  }

  private static func formatDetail(sourceLocation: String?, cause: Error?) -> String {
    var out = ""
    if let sourceLocation {
      out += "\n>> in \(sourceLocation)"
    }
    if let cause {
      out += "\n>> caused by: \(cause.localizedDescription)"
    }
    return out
  }

  private static func tag(for level: EmitLevel) -> String? {
    switch level {
    case .error: return "CRITICAL"
    case .warning: return "WARN"
    case .info: return "INFO"
    case .debug: return "DEBUG"
    case .trace: return "TRACE"
    case .progress: return nil
    }
  }
}

/// Global logging facade. `configure(verbosity:)` must be called once at startup
/// before services begin emitting. Categories are typically created once per
/// long-lived service: `private let log = Log.forCategory("Immich")`.
enum Log {
  fileprivate static let sink = LogSink()

  static func configure(verbosity: Verbosity) {
    sink.configure(verbosity: verbosity)
  }

  /// Returns a `CategoryLog` handle bound to `name`. Cheap to call repeatedly;
  /// each handle creates its own `os.Logger`, but they share the underlying sink.
  static func forCategory(_ name: String) -> CategoryLog {
    CategoryLog(category: name)
  }

  static func summary() -> RunSummary { sink.summary() }
}

struct CategoryLog: Sendable {
  let category: String
  private let logger: Logger

  fileprivate init(category: String) {
    self.category = category
    self.logger = Logger(subsystem: LOGGER_SUBSYSTEM, category: category)
  }

  /// A fatal/critical event.
  /// Surfaced on stderr at every verbosity (including `--quiet`).
  func error(
    _ message: String,
    stage: PipelineStage? = nil,
    context: [LogContextKey: String] = [:],
    cause: Error? = nil,
    function: String = #function,
    file: String = #fileID,
    line: Int = #line
  ) {
    Log.sink.emit(
      level: .error, category: category, osLogger: logger,
      message: message, stage: stage, context: context, cause: cause,
      sourceLocation: "\(file):\(line):\(function)")
  }

  /// A recoverable but noteworthy event.
  /// Surfaced on stderr at `normal` verbosity and above.
  func warning(
    _ message: String,
    stage: PipelineStage? = nil,
    context: [LogContextKey: String] = [:],
    cause: Error? = nil,
    function: String = #function,
    file: String = #fileID,
    line: Int = #line
  ) {
    Log.sink.emit(
      level: .warning, category: category, osLogger: logger,
      message: message, stage: stage, context: context, cause: cause,
      sourceLocation: "\(file):\(line):\(function)")
  }

  /// Tracked informational event (e.g. "skipping empty album").
  /// Surfaced on stdout at `-v` and above.
  func info(
    _ message: String,
    stage: PipelineStage? = nil,
    context: [LogContextKey: String] = [:],
    cause: Error? = nil,
    function: String = #function,
    file: String = #fileID,
    line: Int = #line
  ) {
    Log.sink.emit(
      level: .info, category: category, osLogger: logger,
      message: message, stage: stage, context: context, cause: cause,
      sourceLocation: "\(file):\(line):\(function)")
  }

  /// Routine status/progress line (e.g. "Syncing N assets...").
  /// Surfaced on stdout at `normal` verbosity and above.
  func progress(_ message: String) {
    Log.sink.emit(
      level: .progress, category: category, osLogger: logger,
      message: message, stage: nil, context: [:], cause: nil, sourceLocation: nil)
  }

  /// Finer-grained debugging line.
  /// Surfaced on stdout at `-vv` and above.
  func debug(
    _ message: String,
    stage: PipelineStage? = nil,
    context: [LogContextKey: String] = [:],
    function: String = #function,
    file: String = #fileID,
    line: Int = #line
  ) {
    Log.sink.emit(
      level: .debug, category: category, osLogger: logger,
      message: message, stage: stage, context: context, cause: nil,
      sourceLocation: "\(file):\(line):\(function)")
  }

  /// Finest-grained tracing (e.g. HTTP request bodies).
  /// Surfaced on stdout only at `-vvv`.
  func trace(
    _ message: String,
    stage: PipelineStage? = nil,
    context: [LogContextKey: String] = [:],
    function: String = #function,
    file: String = #fileID,
    line: Int = #line
  ) {
    Log.sink.emit(
      level: .trace, category: category, osLogger: logger,
      message: message, stage: stage, context: context, cause: nil,
      sourceLocation: "\(file):\(line):\(function)")
  }
}
