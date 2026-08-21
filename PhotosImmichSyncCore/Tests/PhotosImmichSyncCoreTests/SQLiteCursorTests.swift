import Foundation
import Testing

@testable import PhotosImmichSyncCore

/// Row type exercising multi-column text reads against the test schema.
private struct SampleRow: SQLiteRow {
  var uuid: String?
  var keyword: String?
  init() {}
  static let columnReaders: [String: ColumnReader<Self>] = [
    "uuid": .text(\.uuid),
    "keyword": .text(\.keyword),
  ]
}

private let SAMPLE_SCHEMA = """
  CREATE TABLE samples (
    uuid TEXT,
    keyword TEXT,
    num INTEGER,
    big INTEGER,
    flag INTEGER,
    ratio REAL,
    payload BLOB
  );
  INSERT INTO samples VALUES ('u1', 'alpha', 1, 5000000000, 1, 1.5, X'DEADBEEF');
  INSERT INTO samples VALUES ('u2', NULL,    2, 0,          0, 0.0, NULL);
  INSERT INTO samples VALUES ('u3', '',      3, 0,          0, 0.0, NULL);
  """

@Suite struct SQLiteCursorTests {
  // The fixture is read-only; build it once for the whole suite.
  private static let dbPath: String = try! makeSQLiteDB(SAMPLE_SCHEMA)

  @Test func streamsRowsAndMapsNullAndEmptyTextToNil() throws {
    let path = Self.dbPath
    let cursor: SQLite.Cursor<SampleRow> = try SQLite.openCursor(
      dbPath: path, query: "SELECT uuid, keyword FROM samples ORDER BY uuid")
    defer { cursor.close() }

    let row1 = try cursor.nextRow()
    #expect(row1?.uuid == "u1")
    #expect(row1?.keyword == "alpha")

    // NULL text reads as nil…
    #expect(try cursor.nextRow()?.keyword == nil)
    // …and, deliberately, so does the empty string (SQLiteHelper.swift's `.text` contract).
    #expect(try cursor.nextRow()?.keyword == nil)

    #expect(try cursor.nextRow() == nil)
  }

  @Test func everySupportedParameterTypeBinds() throws {
    let path = Self.dbPath
    let cursor: SQLite.Cursor<SampleRow> = try SQLite.openCursor(
      dbPath: path,
      query: """
        SELECT uuid FROM samples
        WHERE uuid = :s AND num = :i AND big = :i64 AND flag = :b AND ratio = :d AND payload = :blob
        """,
      parameters: [
        ":s": "u1",
        ":i": 1,
        ":i64": Int64(5_000_000_000),
        ":b": true,
        ":d": 1.5,
        ":blob": Data([0xDE, 0xAD, 0xBE, 0xEF]),
      ])
    defer { cursor.close() }
    #expect(try cursor.nextRow()?.uuid == "u1")
  }

  @Test func int32AndFloatAndNilBind() throws {
    let path = Self.dbPath
    let cursor: SQLite.Cursor<SampleRow> = try SQLite.openCursor(
      dbPath: path,
      query: "SELECT uuid FROM samples WHERE num = :i32 AND ratio = :f AND payload IS :none",
      parameters: [":i32": Int32(2), ":f": Float(0.0), ":none": nil])
    defer { cursor.close() }
    #expect(try cursor.nextRow()?.uuid == "u2")
  }

  @Test func unsupportedParameterTypeThrows() throws {
    let path = Self.dbPath
    #expect(throws: (any Error).self) {
      let _: SQLite.Cursor<SampleRow> = try SQLite.openCursor(
        dbPath: path,
        query: "SELECT uuid FROM samples WHERE uuid = :when",
        parameters: [":when": Date()])
    }
  }

  @Test func unmatchedParameterNameIsSilentlySkipped() throws {
    // Pinned behavior: a parameter that doesn't appear in the query is ignored.
    let path = Self.dbPath
    let cursor: SQLite.Cursor<SampleRow> = try SQLite.openCursor(
      dbPath: path,
      query: "SELECT uuid FROM samples WHERE uuid = 'u1'",
      parameters: [":doesNotExist": 42])
    defer { cursor.close() }
    #expect(try cursor.nextRow()?.uuid == "u1")
  }

  @Test func undeclaredResultColumnThrows() throws {
    let path = Self.dbPath
    #expect(throws: (any Error).self) {
      let _: SQLite.Cursor<SampleRow> = try SQLite.openCursor(
        dbPath: path, query: "SELECT uuid, num FROM samples")
    }
  }

  @Test func invalidSQLThrows() throws {
    let path = Self.dbPath
    #expect(throws: (any Error).self) {
      let _: SQLite.Cursor<SampleRow> = try SQLite.openCursor(dbPath: path, query: "SELEKT nope")
    }
  }

  @Test func missingDatabaseThrows() {
    #expect(throws: (any Error).self) {
      let _: SQLite.Cursor<SampleRow> = try SQLite.openCursor(
        dbPath: "/nonexistent/dir/missing.sqlite", query: "SELECT uuid FROM samples")
    }
  }

  @Test func closeIsIdempotent() throws {
    let path = Self.dbPath
    let cursor: SQLite.Cursor<SampleRow> = try SQLite.openCursor(
      dbPath: path, query: "SELECT uuid FROM samples")
    _ = try cursor.nextRow()
    cursor.close()
    cursor.close()
    // After close, the cursor reports exhaustion instead of crashing.
    #expect(try cursor.nextRow() == nil)
  }
}
