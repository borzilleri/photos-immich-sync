import Foundation
import Testing

@testable import PhotosImmichSyncCore

/// Minimal replica of the Photos.sqlite tables the exporter's queries join over
/// (`ZASSET` / `ZADDITIONALASSETATTRIBUTES` / `Z_1KEYWORDS` / `ZKEYWORD` /
/// `ZASSETDESCRIPTION`). This is the regression net for the fragile schema workaround.
private let PHOTOS_SCHEMA_FIXTURE = """
  CREATE TABLE ZKEYWORD (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT);
  CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT);
  CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZTITLE TEXT);
  CREATE TABLE Z_1KEYWORDS (Z_1ASSETATTRIBUTES INTEGER, Z_52KEYWORDS INTEGER);
  CREATE TABLE ZASSETDESCRIPTION (Z_PK INTEGER PRIMARY KEY, ZASSETATTRIBUTES INTEGER, ZLONGDESCRIPTION TEXT);

  INSERT INTO ZKEYWORD VALUES (1, 'travel');
  INSERT INTO ZKEYWORD VALUES (2, 'family');
  INSERT INTO ZKEYWORD VALUES (3, 'unused');
  INSERT INTO ZKEYWORD VALUES (4, NULL);

  INSERT INTO ZASSET VALUES (1, 'UUID-A');
  INSERT INTO ZASSET VALUES (2, 'UUID-B');
  INSERT INTO ZASSET VALUES (3, 'UUID-C');  -- not in the exported uuid map

  INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (10, 1, 'Title A');
  INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (20, 2, NULL);
  INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (30, 3, 'Title C');

  INSERT INTO Z_1KEYWORDS VALUES (10, 1);  -- A: travel
  INSERT INTO Z_1KEYWORDS VALUES (10, 2);  -- A: family
  INSERT INTO Z_1KEYWORDS VALUES (20, 1);  -- B: travel
  INSERT INTO Z_1KEYWORDS VALUES (30, 1);  -- C: travel (skipped: not exported)

  INSERT INTO ZASSETDESCRIPTION VALUES (100, 20, 'Caption B');
  """

private let LOCAL_A = "UUID-A/L0/001"
private let LOCAL_B = "UUID-B/L0/001"
private let UUID_MAP = ["UUID-A": LOCAL_A, "UUID-B": LOCAL_B]

private func makeExporter() throws -> (PhotosExporter, URL) {
  let (fs, root) = try makeHermeticFileService()
  return (PhotosExporter(fileService: fs, exportConcurrency: 1), root)
}

@Suite struct PhotosDbQueryTests {
  // The fixture is read-only; build it once for the whole suite.
  private static let dbPath: String = try! makeSQLiteDB(PHOTOS_SCHEMA_FIXTURE)

  @Test func fetchAllKeywordsSkipsNullTitles() async throws {
    let (exporter, root) = try makeExporter()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Self.dbPath

    let keywords = await exporter.fetchAllKeywords(db)
    #expect(keywords == ["travel", "family", "unused"])
  }

  @Test func fetchAssetsByKeywordJoinsAndSkipsUnexportedAssets() async throws {
    let (exporter, root) = try makeExporter()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Self.dbPath

    let byKeyword = await exporter.fetchAssetsByKeyword(db: db, uuidMap: UUID_MAP)
    #expect(byKeyword != nil)
    #expect(Set(byKeyword?["travel"] ?? []) == [LOCAL_A, LOCAL_B])  // UUID-C row dropped
    #expect(byKeyword?["family"] == [LOCAL_A])
    #expect(byKeyword?["unused"] == nil)  // no join rows at all
  }

  @Test func collectKeywordsSortsAndIncludesKeywordsWithNoAssets() async throws {
    let (exporter, root) = try makeExporter()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Self.dbPath

    let keywords = await exporter.collectKeywords(db: db, uuidMap: UUID_MAP)
    #expect(keywords?.map(\.keyword) == ["family", "travel", "unused"])
    #expect(keywords?.first(where: { $0.keyword == "unused" })?.assetIds == [])
    #expect(Set(keywords?.first(where: { $0.keyword == "travel" })?.assetIds ?? []) == [LOCAL_A, LOCAL_B])
  }

  @Test func fetchAssetInfoMapsTitleAndCaptionPerExportedAsset() async throws {
    let (exporter, root) = try makeExporter()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Self.dbPath

    let info = await exporter.fetchAssetInfo(db: db, uuidMap: UUID_MAP)
    #expect(info?.count == 2)
    #expect(info?[LOCAL_A]?.title == "Title A")
    #expect(info?[LOCAL_A]?.caption == nil)
    #expect(info?[LOCAL_B]?.title == nil)
    #expect(info?[LOCAL_B]?.caption == "Caption B")
  }

  @Test func emptyCaptionReadsAsNil() async throws {
    // The `.text` column reader deliberately maps empty strings to nil; pin that
    // end-to-end through the caption join.
    let (exporter, root) = try makeExporter()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try makeSQLiteDB(
      PHOTOS_SCHEMA_FIXTURE + "\nINSERT INTO ZASSETDESCRIPTION VALUES (101, 10, '');")

    let info = await exporter.fetchAssetInfo(db: db, uuidMap: UUID_MAP)
    #expect(info?[LOCAL_A]?.title == "Title A")
    #expect(info?[LOCAL_A]?.caption == nil)
  }

  @Test func queriesReturnNilAgainstABrokenDatabase() async throws {
    let (exporter, root) = try makeExporter()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try makeSQLiteDB("CREATE TABLE unrelated (x TEXT);")

    // Missing schema surfaces as a logged warning + nil, never a throw.
    let keywords = await exporter.fetchAllKeywords(db)
    #expect(keywords == nil)
    let byKeyword = await exporter.fetchAssetsByKeyword(db: db, uuidMap: [:])
    #expect(byKeyword == nil)
    let info = await exporter.fetchAssetInfo(db: db, uuidMap: [:])
    #expect(info == nil)
  }
}
