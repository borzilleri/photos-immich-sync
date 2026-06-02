internal import Algorithms
import ArgumentParser
import Photos
import SQLite3

let PHOTOS_DB_PATH = "Pictures/Photos Library.photoslibrary/database/Photos.sqlite"

private let allKeywordQuery = """
  SELECT
    ZTITLE as "keyword"
  FROM
    ZKEYWORD
  """

private let assetTitleCaptionQuery = """
  SELECT
    assets.ZUUID as "uuid",
    attrs.ZTITLE as "title",
    captions.ZLONGDESCRIPTION as "caption"
  FROM 
    ZASSET as assets
    INNER JOIN ZADDITIONALASSETATTRIBUTES as attrs ON attrs.ZASSET = assets.Z_PK
    LEFT JOIN ZASSETDESCRIPTION as captions ON captions.ZASSETATTRIBUTES = attrs.Z_PK
  WHERE
    attrs.ZTITLE is not NULL
    OR captions.ZLONGDESCRIPTION is not null
  """

private let assetKeywordQuery = """
  SELECT
    assets.ZUUID as "uuid",
    keyword.ZTITLE as "keyword"
  FROM 
    ZASSET as assets
    INNER JOIN Z_1KEYWORDS as kwfk ON assets.Z_PK=kwfk.Z_1ASSETATTRIBUTES
    INNER JOIN ZKEYWORD as keyword ON keyword.Z_PK=kwfk.Z_52KEYWORDS
  """

private struct AssetInfo {
  let title: String?
  let caption: String?
  init(title: String?, caption: String?) {
    self.title = title
    self.caption = caption
  }
}

private struct DeltaChanges {
  let changedAssets: [PHAsset]
  let deletedAssetIds: [String]
  let changedAlbumIds: [String]
  let deletedAlbumIds: [String]
}

actor CloudIdentifierCache {
  private static let log = Log.forCategory("Photos")
  var localToCloudMap: [String: String] = [:]

  func populateCache(localIdentifiers: [String]) async {
    let cloudMappings = PHPhotoLibrary.shared()
      .cloudIdentifierMappings(forLocalIdentifiers: localIdentifiers)
    for (localIdentifier, cloudMapping) in cloudMappings {
      do {
        let cloudIdentifier = try cloudMapping.get()
        localToCloudMap[localIdentifier] = cloudIdentifier.stringValue
      } catch {
        Self.log.warning(
          "Error generating Cloud Identifier; asset will be skipped in export.",
          stage: .exportAssets,
          context: [.localIdentifier: localIdentifier],
          cause: error
        )
      }
    }
  }

  func getCloudId(_ localId: String) -> String? {
    return localToCloudMap[localId]
  }
}

/// In-memory `[ZUUID -> PHAsset.localIdentifier]` map. Populated as PHAssets
/// are enumerated during export so the SQLite-backed keyword/info joins do
/// not have to fabricate a `localIdentifier` from `\(uuid)/L0/001`.
actor LocalIdentifierMap {
  private var uuidToLocalId: [String: String] = [:]

  /// Adds a single localIdentifier, indexed by the prefix up to the first `/`
  /// (which corresponds to `ZUUID` in the Photos SQLite database). Falls back
  /// to the full identifier if no `/` is present.
  func add(localIdentifier id: String) {
    let uuid = id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id
    uuidToLocalId[uuid] = id
  }

  func add(localIdentifiers ids: [String]) {
    for id in ids { add(localIdentifier: id) }
  }

  /// Returns a value-copy snapshot for fast O(1) sync lookups inside the
  /// SQLite row loops (which are not async).
  func snapshot() -> [String: String] { uuidToLocalId }
}

public struct PhotosExporter {
  private static let log = Log.forCategory("Photos")
  let fs: FileService

  var cloudIdCache: CloudIdentifierCache
  private let localIdMap = LocalIdentifierMap()
  private let exportConcurrency: Int

  init(fileService: FileService, exportConcurrency: Int) {
    self.fs = fileService
    self.cloudIdCache = CloudIdentifierCache()
    self.exportConcurrency = max(1, exportConcurrency)
  }

  public func generateBundleStats(_ bundles: [AssetBundle]) -> String {
    let livePhotoCount = bundles.filter({ b in b.resources[.livephoto] != nil }).count
    let editedCount = bundles.filter({ $0.resources[.edited] != nil }).count
    let videoCount = bundles.filter({ $0.asset.mediaType == .video }).count
    return """
        \(bundles.count) new/updated assets:
          \(livePhotoCount) Live Photos
          \(videoCount) Videos
          \(editedCount) Edited Photo Assets
          \(bundles.reduce(0, { $0+$1.resources.count })) total files
      """
  }

  public func generateDeltaExport(_ changeToken: PHPersistentChangeToken, config: PhotosExportConfig) async
    -> DeltaPhotosExport?
  {
    guard let changes = await fetchChanges(changeToken, config: config) else {
      return nil
    }
    await cloudIdCache.populateCache(localIdentifiers: changes.changedAssets.map(\.localIdentifier))

    var assetDbMetadata: [String: AssetInfo]? = nil
    var keywords: [PhotosKeyword]? = nil

    if config.includeTitleCaption, let db = await preparePhotosDb() {
      let uuidMap = await localIdMap.snapshot()
      assetDbMetadata = await fetchAssetInfo(db: db, uuidMap: uuidMap)
      keywords = await collectKeywords(db: db, uuidMap: uuidMap)
    }

    let bundles = await assembleBundlesFromAssets(assets: changes.changedAssets, infos: assetDbMetadata)
    let albums = fetchChangedAlbums(changes.changedAlbumIds, config: config)

    Self.log.progress(
      """
      Delta Export Contents:
        \(generateBundleStats(bundles))
        \(changes.deletedAssetIds.count) deleted assets
        \(albums.count) new/updated albums
        \(changes.deletedAlbumIds.count) deleted albums
        \(keywords?.count ?? 0) keywords
      """)
    return DeltaPhotosExport(
      upsertedBundles: bundles,
      deletedAssets: changes.deletedAssetIds,
      keywords: keywords,
      upsertedAlbums: albums,
      deletedAlbums: changes.deletedAlbumIds
    )
  }

  public func generateFullExport(config: PhotosExportConfig) async -> FullPhotosExport {
    let assets = await fetchAssets(config: config)
    await cloudIdCache.populateCache(localIdentifiers: assets.map(\.localIdentifier))

    var assetDbMetadata: [String: AssetInfo]? = nil
    var keywords: [PhotosKeyword]? = nil

    if config.includeTitleCaption, let db = await preparePhotosDb() {
      let uuidMap = await localIdMap.snapshot()
      assetDbMetadata = await fetchAssetInfo(db: db, uuidMap: uuidMap)
      keywords = await collectKeywords(db: db, uuidMap: uuidMap)
    }

    let bundles = await assembleBundlesFromAssets(assets: assets, infos: assetDbMetadata)
    let albums = fetchAllAlbums(config: config)

    Self.log.progress(
      """
      Exporting
        \(bundles.count) assets
        \(bundles.reduce(0, { $0+$1.resources.count })) files
        \(albums.count) albums
        \(keywords?.count ?? 0) keywords
      """)
    return FullPhotosExport(
      assetBundles: bundles,
      keywords: keywords,
      albums: albums
    )
  }

  internal func firstResource(
    _ resources: [PHAssetResource],
    type: PHAssetResourceType
  ) -> PHAssetResource? {
    return resources.first { $0.type == type }
  }

  private func fetchAllKeywords(_ db: String) async -> Set<String>? {
    do {
      var allKeywords: Set<String> = []
      let cursor: SQLite.Cursor<KeywordRow> = try SQLite.openCursor(dbPath: db, query: allKeywordQuery)
      defer { cursor.close() }
      while let row = try cursor.nextRow() {
        if let keyword = row.keyword {
          allKeywords.insert(keyword)
        }
      }
      return allKeywords
    } catch {
      Self.log.warning(
        "Error querying database for Keywords. Skipping keyword export.",
        stage: .exportKeywords,
        cause: error
      )
    }
    return nil
  }

  func fetchAssetsByKeyword(db: String, uuidMap: [String: String]) async -> [String: [String]]? {
    var skippedCount = 0
    do {
      var assetsByKeyword: [String: [String]] = [:]
      let cursor: SQLite.Cursor<AssetKeywordRow> = try SQLite.openCursor(dbPath: db, query: assetKeywordQuery)
      defer { cursor.close() }
      while let row = try cursor.nextRow() {
        guard let uuid = row.uuid else { continue }
        guard let localId = uuidMap[uuid] else {
          skippedCount += 1
          continue
        }
        if let keyword = row.keyword {
          assetsByKeyword[keyword, default: []].append(localId)
        }
      }
      if skippedCount > 0 {
        Self.log.info(
          "Skipped \(skippedCount) keywords not associated with exported Assets.",
          stage: .exportKeywords
        )
      }
      return assetsByKeyword
    } catch {
      Self.log.warning(
        "Error querying database for Asset Keywords. Skipping keyword export.",
        stage: .exportKeywords,
        cause: error
      )
    }
    return nil
  }

  private func collectKeywords(db: String, uuidMap: [String: String]) async -> [PhotosKeyword]? {
    Self.log.progress("Fetching Keywords for export")
    let allKeywords = await fetchAllKeywords(db)
    guard let allKeywords else {
      return nil
    }
    let assetsByKeyword = await fetchAssetsByKeyword(db: db, uuidMap: uuidMap)
    guard let assetsByKeyword else {
      return nil
    }
    Self.log.progress("Keyword export complete.")
    return allKeywords.sorted().map { kw in
      PhotosKeyword(keyword: kw, assetIds: assetsByKeyword[kw] ?? [])
    }
  }

  private func fetchAssetInfo(db: String, uuidMap: [String: String]) async -> [String: AssetInfo]? {
    Self.log.progress("Fetching asset metadata from Photos DB")
    var assetDescriptions: [String: AssetInfo] = [:]
    var skippedCount = 0
    do {
      let cursor: SQLite.Cursor<AssetTitleCaptionRow> = try SQLite.openCursor(
        dbPath: db, query: assetTitleCaptionQuery)
      defer { cursor.close() }
      while let row = try cursor.nextRow() {
        guard let uuid = row.uuid else { continue }
        guard let localId = uuidMap[uuid] else {
          skippedCount += 1
          continue
        }
        assetDescriptions[localId] = AssetInfo(title: row.title, caption: row.caption)
      }
    } catch {
      Self.log.warning(
        "Error querying database for Asset metadata. Skipping metadata sync.",
        stage: .exportAssetMetadata,
        cause: error
      )
      return nil
    }

    if skippedCount > 0 {
      Self.log.info(
        "Skipped \(skippedCount) metadata records not associated with exported assets.",
        stage: .exportKeywords
      )
    }
    Self.log.progress("Metadata fetch complete")
    return assetDescriptions
  }

  func preparePhotosDb() async -> String? {
    do {
      let photosDbPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(PHOTOS_DB_PATH).path
      let photosShmPath = photosDbPath + "-shm"
      let photosWalPath = photosDbPath + "-wal"

      let dbFile = fs.workDir.appendingPathComponent("photos.sqlite").path
      let shmFile = dbFile + "-shm"
      let walFile = dbFile + "-wal"

      try fs.copyFile(fromPath: photosDbPath, toPath: dbFile)
      try fs.copyFile(fromPath: photosShmPath, toPath: shmFile)
      try fs.copyFile(fromPath: photosWalPath, toPath: walFile)

      return dbFile
    } catch {
      Self.log.warning(
        "Error copying Photos SQLite database. Skipping metadata/keyword export.",
        stage: .exportAssetMetadata,
        cause: error
      )
    }
    return nil
  }

  private func collectAssetResources(_ asset: PHAsset) async -> [AssetType: PHAssetResource]? {
    let resources: [PHAssetResource] = PHAssetResource.assetResources(for: asset)
    var resourcesToSync: [AssetType: PHAssetResource] = [:]
    switch asset.mediaType {
    case .image:
      if let photo = firstResource(resources, type: .photo) {
        resourcesToSync[.original] = photo
        if asset.hasAdjustments {
          resourcesToSync[.edited] = photo
        }
      }
      if asset.mediaSubtypes.contains(.photoLive) {
        if let pairedVideo = firstResource(resources, type: .pairedVideo) {
          resourcesToSync[.livephoto] = pairedVideo
        }
      } else {
        if let altPhoto = firstResource(resources, type: .alternatePhoto) {
          resourcesToSync[.alternate] = altPhoto
        }
      }
    case .video:
      if let video = firstResource(resources, type: .video) {
        resourcesToSync[.original] = video
      }
    case .unknown, .audio:
      Self.log.debug(
        "Skipping non-synced asset type '\(asset.mediaType)': \(asset.localIdentifier)"
      )
    @unknown default:
      Self.log.debug(
        "Skipping unknown asset type for '\(asset.mediaType)': \(asset.localIdentifier)"
      )
    }
    if resourcesToSync.isEmpty || resourcesToSync[.original] == nil {
      Self.log.warning(
        "No resources exported, or no original resource found to export. Skipping asset.",
        stage: .exportAssets,
        context: [.localIdentifier: asset.localIdentifier]
      )
      return nil
    }
    Self.log.debug("Exporting asset: \(resourcesToSync.map({k,v in "\(k.rawValue):\(v.originalFilename)"}))")
    return resourcesToSync
  }

  private func assembleBundlesFromAssets(assets: [PHAsset], infos: [String: AssetInfo]?)
    async -> [AssetBundle]
  {
    Self.log.progress("Assembling assets and metadata into export bundles.")
    let result = await withTaskGroup(of: AssetBundle?.self) { group in
      var bundles = [AssetBundle]()
      var iter = assets.makeIterator()
      var inflight = 0

      // Prime the group with up to `exportConcurrency` tasks. Subsequent tasks are scheduled
      // as earlier ones complete, keeping in-flight work bounded without staging one Task per
      // asset up front.
      while inflight < exportConcurrency, let asset = iter.next() {
        group.addTask {
          await self.processAssetToBundle(asset, info: infos?[asset.localIdentifier])
        }
        inflight += 1
      }
      while let bundle = await group.next() {
        inflight -= 1
        if let bundle {
          bundles.append(bundle)
        }
        if let asset = iter.next() {
          group.addTask {
            await self.processAssetToBundle(asset, info: infos?[asset.localIdentifier])
          }
          inflight += 1
        }
      }
      return bundles
    }
    Self.log.progress("Bundle assembly complete")
    return result
  }

  private func processAssetToBundle(_ asset: PHAsset, info: AssetInfo?) async -> AssetBundle? {
    let cloudId = await cloudIdCache.getCloudId(asset.localIdentifier)
    let resources = await collectAssetResources(asset)
    if resources == nil || resources?.isEmpty == true {
      Self.log.warning(
        "No resources found to export, skipping.",
        stage: .exportAssets,
        context: [.localIdentifier: asset.localIdentifier]
      )
      return nil
    }
    // This should be perfunctory at this point, just to safely unwrap the optionals.
    if let resources {
      var title: String? = nil
      var caption: String? = nil
      if let info {
        title = info.title
        caption = info.caption
      }
      return AssetBundle(
        asset: asset,
        cloudIdentifier: cloudId,
        resources: resources,
        burstIdentifier: asset.burstIdentifier,
        title: title,
        caption: caption
      )
    }
    return nil
  }

  private func shouldExport(_ asset: PHAsset, config: PhotosExportConfig) -> Bool {
    guard asset.burstIdentifier != nil else { return true }
    return asset.burstSelectionTypes == .userPick
      || config.includeBursts == .all
      || (config.includeBursts == .selected && asset.burstSelectionTypes == .autoPick)
  }

  private func buildFetchOptions(config: PhotosExportConfig) -> PHFetchOptions {
    let options = PHFetchOptions()
    options.sortDescriptors = [
      NSSortDescriptor(key: "creationDate", ascending: config.oldestFirst)
    ]
    options.includeHiddenAssets = config.includeHidden
    options.includeAllBurstAssets = config.includeBursts != .none
    return options
  }

  func fetchAssets(config: PhotosExportConfig) async -> [PHAsset] {
    Self.log.progress("Fetching Assets for export.")
    let fetchOptions = buildFetchOptions(config: config)
    if let limit = config.fetchLimit {
      fetchOptions.fetchLimit = limit
    }
    let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
    var assets = [PHAsset]()
    assets.reserveCapacity(fetchResult.count)
    fetchResult.enumerateObjects { asset, _, _ in
      if shouldExport(asset, config: config) {
        assets.append(asset)
      }
    }
    await localIdMap.add(localIdentifiers: assets.map(\.localIdentifier))
    Self.log.progress("Asset fetch complete.")
    return assets
  }

  func fetchChangedAlbums(_ albumIds: [String], config: PhotosExportConfig) -> [PhotosAlbum] {
    Self.log.progress("Fetching Albums and membership")

    var albums: [PHAssetCollection] = []
    var folders: [PHCollectionList] = []
    PHAssetCollection
      .fetchAssetCollections(withLocalIdentifiers: albumIds, options: nil)
      .enumerateObjects {
        item, _, _ in
        let collection = item as PHCollection
        switch collection {
        case let album as PHAssetCollection:
          if album.assetCollectionSubtype == .albumRegular {
            albums.append(album)
          }
        case let folder as PHCollectionList:
          folders.append(folder)
        default:
          Self.log.debug("Ignoring unknown collection: \(collection.localizedTitle ?? "?")")
        }
      }

    let albumMap: [String: PhotosAlbum] = Dictionary(
      uniqueKeysWithValues: albums.map({ exportAlbumWithAssets($0, config: config) }).map({ ($0.localIdentifier, $0) })
    )
    let nameChangeOnlyAlbums = folders.flatMap({ exportFolder($0, path: []) })
      .filter({ albumMap[$0.localIdentifier] == nil })

    Self.log.progress("Album export complete")
    return albumMap.values + nameChangeOnlyAlbums
  }

  func exportFolder(_ folder: PHCollectionList, path: [String]) -> [PhotosAlbum] {
    var albums: [PhotosAlbum] = []
    let newPath = path + [folder.localizedTitle ?? "UnknownFolder"]
    PHCollectionList.fetchCollections(in: folder, options: nil).enumerateObjects { c, _, _ in
      switch c {
      case let a as PHAssetCollection:
        let album = PhotosAlbum(
          localIdentifier: a.localIdentifier,
          folderPath: newPath + [a.localizedTitle ?? "UnknownAlbum"],
          assetIds: [],
          nameChangeOnly: true
        )
        Self.log.debug("Exporting album: \(album.folderPath); name change only.")
        albums.append(album)
      case let f as PHCollectionList:
        albums.append(contentsOf: exportFolder(f, path: newPath))
      default:
        Self.log.debug("non album/folder collection: \(c.localizedTitle ?? "?")")
      }
    }
    return albums
  }

  func fetchAllAlbums(config: PhotosExportConfig) -> [PhotosAlbum] {
    Self.log.progress("Fetching Albums and membership")
    var albums = [PhotosAlbum]()
    PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects {
      album, _, _ in
      albums.append(exportAlbumWithAssets(album, config: config))
    }
    Self.log.progress("Album export complete")
    return albums
  }

  func exportAlbumWithAssets(_ album: PHAssetCollection, config: PhotosExportConfig) -> PhotosAlbum {
    var albumAssetIds: [String] = []
    let fetchOptions = buildFetchOptions(config: config)
    PHAsset.fetchAssets(in: album, options: fetchOptions).enumerateObjects { asset, _, _ in
      if shouldExport(asset, config: config) {
        albumAssetIds.append(asset.localIdentifier)
      }
    }
    let album = PhotosAlbum(
      localIdentifier: album.localIdentifier,
      folderPath: fetchCollectionPath(for: album).reversed(),
      assetIds: albumAssetIds,
      nameChangeOnly: false
    )
    Self.log.debug("Exporting album: \(album.folderPath); \(album.assetIds.count) assets")
    return album
  }

  func fetchCollectionPath(for collection: PHCollection) -> [String] {
    let result = PHCollectionList.fetchCollectionListsContaining(collection, options: nil)
    var out = [collection.localizedTitle ?? "Unknown"]
    if let parent = result.firstObject {
      out.append(contentsOf: fetchCollectionPath(for: parent))
    }
    return out
  }

  private func fetchChanges(_ token: PHPersistentChangeToken, config: PhotosExportConfig) async -> DeltaChanges? {
    Self.log.progress("Fetching asset changes")
    var assetIdsChanged = Set<String>()
    var assetIdsDeleted = Set<String>()

    var albumIdsChanged = Set<String>()
    var albumIdsDeleted = Set<String>()

    do {
      let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
      for change in changes {
        let assetChanges = try change.changeDetails(for: .asset)
        assetIdsDeleted.formUnion(assetChanges.deletedLocalIdentifiers)
        // Add inserted & Updated elements
        assetIdsChanged.formUnion(
          assetChanges.insertedLocalIdentifiers
            .union(assetChanges.updatedLocalIdentifiers))

        let albumChanges = try change.changeDetails(for: .assetCollection)
        albumIdsDeleted.formUnion(albumChanges.deletedLocalIdentifiers)
        albumIdsChanged.formUnion(
          albumChanges.insertedLocalIdentifiers
            .union(albumChanges.updatedLocalIdentifiers))
      }
    } catch let error as PHPhotosError {
      switch error.code {
      case .persistentChangeTokenExpired:
        Self.log.error(
          "The saved change token is older than the system's persistent change history "
            + "(typically ~30 days). A full sync is required to recover.",
          stage: .fetchChanges
        )
      case .persistentChangeDetailsUnavailable:
        Self.log.error(
          "Persistent change details are unavailable for the saved token. "
            + "A full sync is required to recover.",
          stage: .fetchChanges
        )
      default:
        Self.log.error(
          "Error retrieving change details.",
          stage: .fetchChanges,
          cause: error
        )
      }
      return nil
    } catch {
      Self.log.error(
        "Error retrieving change details.",
        stage: .fetchChanges,
        cause: error
      )
      return nil
    }


    let fetchOptions = buildFetchOptions(config: config)
    var changedAssets: [PHAsset] = []
    PHAsset.fetchAssets(
      withLocalIdentifiers: Array(assetIdsChanged.subtracting(assetIdsDeleted)), options: fetchOptions
    ).enumerateObjects { asset, _, _ in
      if shouldExport(asset, config: config) {
        changedAssets.append(asset)
      }
    }

    await localIdMap.add(localIdentifiers: changedAssets.map(\.localIdentifier))

    Self.log.progress("Changed asset export complete")
    return DeltaChanges(
      changedAssets: changedAssets,
      deletedAssetIds: Array(assetIdsDeleted),
      changedAlbumIds: Array(albumIdsChanged.subtracting(albumIdsDeleted)),
      deletedAlbumIds: Array(albumIdsDeleted)
    )
  }
}
