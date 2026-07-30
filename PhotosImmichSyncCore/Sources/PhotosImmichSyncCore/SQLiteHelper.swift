import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)

/// A row type produced by `SQLite.openCursor`. Conformers declare the set of
/// column aliases they accept and a typed reader for each one.
public protocol SQLiteRow {
  init()
  static var columnReaders: [String: ColumnReader<Self>] { get }
}

/// Reads a single SQLite column value into a field of `Row`. New SQL types are
/// added by extending `ColumnReader` with additional static factories
/// (e.g. `.integer(_:)`, `.blob(_:)`) and corresponding read helpers.
public struct ColumnReader<Row> {
  let read: (OpaquePointer, Int32, inout Row) -> Void

  /// Reads a `TEXT` column into a `String?` field. NULL values and empty
  /// strings are both mapped to `nil`.
  public static func text(_ kp: WritableKeyPath<Row, String?>) -> ColumnReader<Row> {
    .init { stmt, i, row in row[keyPath: kp] = sqliteReadText(stmt, i) }
  }
}

private func sqliteReadText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
  if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
  guard let cText = sqlite3_column_text(stmt, index) else { return nil }
  let s = String(cString: cText)
  return s.isEmpty ? nil : s
}

/// Row produced by queries that select a single `keyword` column.
public struct KeywordRow: SQLiteRow {
  public var keyword: String?
  public init() {}
  public static let columnReaders: [String: ColumnReader<Self>] = [
    "keyword": .text(\.keyword),
  ]
}

/// Row produced by queries that join assets to keywords.
public struct AssetKeywordRow: SQLiteRow {
  public var uuid: String?
  public var keyword: String?
  public init() {}
  public static let columnReaders: [String: ColumnReader<Self>] = [
    "uuid": .text(\.uuid),
    "keyword": .text(\.keyword),
  ]
}

/// Row produced by queries that select asset titles and captions.
public struct AssetTitleCaptionRow: SQLiteRow {
  public var uuid: String?
  public var title: String?
  public var caption: String?
  public init() {}
  public static let columnReaders: [String: ColumnReader<Self>] = [
    "uuid": .text(\.uuid),
    "title": .text(\.title),
    "caption": .text(\.caption),
  ]
}

public struct SQLite {
  private static func bind(value: Any?, to stmt: OpaquePointer!, at index: Int32) throws {
    if value == nil {
      guard sqlite3_bind_null(stmt, index) == SQLITE_OK else {
        throw bindError(stmt: stmt)
      }
      return
    }
    let v = value!
    switch v {
    case let i as Int:
      guard sqlite3_bind_int64(stmt, index, Int64(i)) == SQLITE_OK else {
        throw bindError(stmt: stmt)
      }
    case let i as Int32:
      guard sqlite3_bind_int64(stmt, index, Int64(i)) == SQLITE_OK else {
        throw bindError(stmt: stmt)
      }
    case let i as Int64:
      guard sqlite3_bind_int64(stmt, index, i) == SQLITE_OK else {
        throw bindError(stmt: stmt)
      }
    case let b as Bool:
      guard sqlite3_bind_int64(stmt, index, b ? 1 : 0) == SQLITE_OK else {
        throw bindError(stmt: stmt)
      }
    case let d as Double:
      guard sqlite3_bind_double(stmt, index, d) == SQLITE_OK else {
        throw bindError(stmt: stmt)
      }
    case let f as Float:
      guard sqlite3_bind_double(stmt, index, Double(f)) == SQLITE_OK else {
        throw bindError(stmt: stmt)
      }
    case let s as String:
      let nsStr = s as NSString
      guard let cStr = nsStr.utf8String else {
        throw NSError(domain: "LocalDataStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get UTF-8 representation of string"])
      }
      let result = sqlite3_bind_text(stmt, index, cStr, -1, sqliteTransient)
      guard result == SQLITE_OK else {
        throw bindError(stmt: stmt)
      }
    case let data as Data:
      let result = data.withUnsafeBytes { buf in
        sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(data.count), sqliteTransient)
      }
      guard result == SQLITE_OK else {
        throw bindError(stmt: stmt)
      }
    default:
      throw NSError(domain: "LocalDataStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported parameter type: \(type(of: v))"])
    }
  }

  private static func bindError(stmt: OpaquePointer!) -> NSError {
    let message = String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt)))
    return NSError(domain: "LocalDataStore", code: Int(sqlite3_errcode(sqlite3_db_handle(stmt))), userInfo: [NSLocalizedDescriptionKey: message])
  }

  /// Opens a streaming cursor over `query` against the SQLite database at `dbPath`.
  /// Rows are produced lazily via `Cursor.nextRow()` so large result sets are
  /// not materialized in memory. The `Row` type chosen by the caller determines
  /// which result columns are accepted and how each value is read.
  ///
  /// Throws if the database cannot be opened, the statement cannot be
  /// prepared, parameter binding fails, or any result column is not declared
  /// in `Row.columnReaders`.
  public static func openCursor<Row: SQLiteRow>(
    dbPath: String,
    query: String,
    parameters: [String: Any?] = [:]
  ) throws -> Cursor<Row> {
    return try Cursor<Row>(dbPath: dbPath, query: query, parameters: parameters)
  }

  /// Lazy, single-pass cursor over a prepared SQLite statement. Holds the
  /// `sqlite3*` and `sqlite3_stmt*` for its lifetime; callers should `defer`
  /// `close()` (or rely on `deinit`) to release them.
  public final class Cursor<Row: SQLiteRow> {
    private var db: OpaquePointer?
    private var stmt: OpaquePointer?
    private let readers: [(Int32, ColumnReader<Row>)]

    fileprivate init(dbPath: String, query: String, parameters: [String: Any?]) throws {
      var localDb: OpaquePointer?
      let openResult = sqlite3_open_v2(dbPath, &localDb, SQLITE_OPEN_READONLY, nil)
      if openResult != SQLITE_OK {
        let message: String
        if let localDb, let cString = sqlite3_errmsg(localDb) {
          message = String(cString: cString)
        } else {
          message = "Failed to open database"
        }
        if let localDb { sqlite3_close(localDb) }
        throw NSError(domain: "LocalDataStore", code: Int(openResult), userInfo: [NSLocalizedDescriptionKey: message])
      }
      guard let localDb else {
        throw NSError(domain: "LocalDataStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to open database"])
      }

      var localStmt: OpaquePointer?
      guard sqlite3_prepare_v2(localDb, query, -1, &localStmt, nil) == SQLITE_OK, let localStmt else {
        let message = String(cString: sqlite3_errmsg(localDb))
        let code = Int(sqlite3_errcode(localDb))
        sqlite3_close(localDb)
        throw NSError(domain: "LocalDataStore", code: code, userInfo: [NSLocalizedDescriptionKey: message])
      }

      do {
        for (name, value) in parameters {
          let index = sqlite3_bind_parameter_index(localStmt, name)
          guard index != 0 else { continue }
          try SQLite.bind(value: value, to: localStmt, at: index)
        }
      } catch {
        sqlite3_finalize(localStmt)
        sqlite3_close(localDb)
        throw error
      }

      let columnCount = sqlite3_column_count(localStmt)
      var matched: [(Int32, ColumnReader<Row>)] = []
      let knownReaders = Row.columnReaders
      for i in 0..<columnCount {
        let name: String
        if let cName = sqlite3_column_name(localStmt, i) {
          name = String(cString: cName)
        } else {
          sqlite3_finalize(localStmt)
          sqlite3_close(localDb)
          throw NSError(
            domain: "LocalDataStore",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to read column name at index \(i)"]
          )
        }
        guard let reader = knownReaders[name] else {
          sqlite3_finalize(localStmt)
          sqlite3_close(localDb)
          throw NSError(
            domain: "LocalDataStore",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported column '\(name)' for row type \(Row.self)"]
          )
        }
        matched.append((i, reader))
      }

      self.db = localDb
      self.stmt = localStmt
      self.readers = matched
    }

    /// Steps the underlying statement and returns the next row, or `nil` when
    /// the result set is exhausted. Throws on any SQLite error other than
    /// `SQLITE_ROW`/`SQLITE_DONE`.
    public func nextRow() throws -> Row? {
      guard let stmt else { return nil }
      let result = sqlite3_step(stmt)
      switch result {
      case SQLITE_ROW:
        var row = Row()
        for (index, reader) in readers {
          reader.read(stmt, index, &row)
        }
        return row
      case SQLITE_DONE:
        return nil
      default:
        let dbHandle = sqlite3_db_handle(stmt)
        let message = String(cString: sqlite3_errmsg(dbHandle))
        let code = Int(sqlite3_errcode(dbHandle))
        throw NSError(domain: "LocalDataStore", code: code, userInfo: [NSLocalizedDescriptionKey: message])
      }
    }

    /// Releases the underlying statement and database handles. Idempotent;
    /// safe to call from `defer` and from `deinit`.
    public func close() {
      if let stmt {
        sqlite3_finalize(stmt)
        self.stmt = nil
      }
      if let db {
        sqlite3_close(db)
        self.db = nil
      }
    }

    deinit { close() }
  }
}

