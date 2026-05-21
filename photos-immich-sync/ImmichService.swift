internal import Algorithms
import AsyncHTTPClient
import HTTPTypes
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime
import OpenAPIURLSession
import Photos
import PhotosUI

actor AssetCache {
  private let client: ImmichApiClient

  private var fullAssets: [String: Components.Schemas.AssetResponseDto] = [:]
  private var deviceAssetIdToImmichId: [String: String] = [:]
  private var immichIdToDeviceAssetId: [String: String] = [:]
  private var existingDeviceAssetIds: Set<String> = []

  init(client: ImmichApiClient) {
    self.client = client
  }

  public func addExistingDeviceAssetIds(_ ids: Set<String>) {
    existingDeviceAssetIds.formUnion(ids)
  }

  public func hasExistingDeviceAssetId(_ id: String) -> Bool {
    return existingDeviceAssetIds.contains(id)
  }

  public func addId(immichId: String, deviceAssetId: String) {
    deviceAssetIdToImmichId[deviceAssetId] = immichId
    immichIdToDeviceAssetId[immichId] = deviceAssetId
  }

  public func add(_ asset: Components.Schemas.AssetResponseDto) {
    fullAssets[asset.id] = asset
    deviceAssetIdToImmichId[asset.deviceAssetId] = asset.id
    immichIdToDeviceAssetId[asset.id] = asset.deviceAssetId
  }

  public func allAssets() -> [Components.Schemas.AssetResponseDto] {
    Array(fullAssets.values)
  }

  public func clear(immichId: String) {
    if let deviceAssetId = immichIdToDeviceAssetId.removeValue(forKey: immichId) {
      deviceAssetIdToImmichId.removeValue(forKey: deviceAssetId)
    }
    fullAssets.removeValue(forKey: immichId)
  }

  public func resolve(immichId: String) async throws -> Components.Schemas.AssetResponseDto {
    if let asset = fullAssets[immichId] { return asset }
    let asset = try await client.getAsset(id: immichId)
    add(asset)
    return asset
  }

  public func resolveId(deviceAssetId: String) -> String? {
    return deviceAssetIdToImmichId[deviceAssetId]
  }

  public func resolve(deviceAssetId: String) async throws -> Components.Schemas.AssetResponseDto? {
    if let immichId = deviceAssetIdToImmichId[deviceAssetId],
      let asset = fullAssets[immichId]
    {
      return asset
    }
    // Half-populated entry: we know the immich id (e.g. from `addId` after upload)
    // but never fetched the DTO. Fetch by id directly rather than falling through
    // to `searchByDeviceAssetId` so we get a precise GET and avoid a search round trip.
    if let immichId = deviceAssetIdToImmichId[deviceAssetId] {
      let asset = try await client.getAsset(id: immichId)
      add(asset)
      return asset
    }
    if let asset = try await client.searchByDeviceAssetId(deviceAssetId) {
      add(asset)
      return asset
    }
    return nil
  }
}

actor StackTracker {
  private var idToPrimaryMap: [String: [String]] = [:]

  public func add(ids: [String]) {
    guard ids.count > 1 else {
      return
    }
    ids.forEach({ idToPrimaryMap[$0] = ids })
  }

  public func resolveIds(id: String, primaryOnly: Bool) -> [String] {
    let ids = idToPrimaryMap[id] ?? [id]
    if primaryOnly {
      return Array(ids.prefix(1))
    }
    return ids
  }
}

/// Memoizes a single successful `client.listAlbums()` call for the lifetime of an
/// `ImmichService`.
///
/// While a fetch is in flight, concurrent callers coalesce onto the same `Task` rather than
/// racing to fire `listAlbums` multiple times. On success the result is cached and reused
/// for subsequent calls. On failure the in-flight slot is cleared so the next caller can
/// retry the fetch instead of inheriting a poisoned cache.
private actor AlbumListCache {
  private let client: ImmichApiClient
  private var cached: [Components.Schemas.AlbumResponseDto]?
  private var inflight: Task<[Components.Schemas.AlbumResponseDto], Error>?

  init(client: ImmichApiClient) {
    self.client = client
  }

  func get() async throws -> [Components.Schemas.AlbumResponseDto] {
    if let cached { return cached }
    if let inflight { return try await inflight.value }
    let task = Task { [client] in try await client.listAlbums() }
    inflight = task
    do {
      let value = try await task.value
      cached = value
      inflight = nil
      return value
    } catch {
      inflight = nil
      throw error
    }
  }
}

public class ImmichService {
  private static let log = Log.forCategory("Immich")
  private let config: ImmichConfig
  private let client: ImmichApiClient
  private let fs: FileService
  private let downloadManager: PhotosDownloader
  private let downloadLimiter: AsyncSemaphore

  private let assetCache: AssetCache
  private let albumListCache: AlbumListCache
  private var stacks: StackTracker = StackTracker()

  private static func errorContext(_ entries: (LogContextKey, String?)...) -> [LogContextKey: String] {
    entries.reduce(into: [:]) { context, entry in
      if let value = entry.1 {
        context[entry.0] = value
      }
    }
  }

  init(
    client: ImmichApiClient,
    config: ImmichConfig,
    fileService: FileService,
    photoDownloader: PhotosDownloader,
    downloadLimiter: AsyncSemaphore,
  ) {
    self.client = client
    self.config = config
    self.fs = fileService
    self.downloadManager = photoDownloader
    self.downloadLimiter = downloadLimiter
    self.assetCache = AssetCache(client: client)
    self.albumListCache = AlbumListCache(client: client)
  }

  func performFullSync(_ export: FullPhotosExport) async {
    await preFetchDeviceAssetIds(export.assetBundles)
    let immichIds = await uploadAssets(export.assetBundles)

    // Always need the full device-asset listing for orphan asset pruning, and
    // (when enabled) for tag/album asset resolution.
    let prefetchSucceeded = await prefetchAllAssetsForDevice()

    if prefetchSucceeded {
      await pruneOrphanAssets(expected: expectedDeviceAssetIds(export.assetBundles))
    } else {
      Self.log.warning(
        "Skipping orphan asset prune because the device asset prefetch failed; orphans may remain on Immich.",
        stage: .deleteAsset
      )
    }

    if config.tags.enabled, let keywords = export.keywords {
      await syncTags(keywords, changedIds: Set(immichIds))
    }

    if config.albums.enabled {
      await syncAlbums(export.albums)
      await pruneOrphanAlbums(expected: Set(export.albums.map(\.localIdentifier)))
    }

    reportSyncCompletion(mode: "Full")
  }

  func performDeltaSync(_ changes: DeltaPhotosExport) async {
    await preFetchDeviceAssetIds(changes.upsertedBundles)
    let immichIds = await self.uploadAssets(changes.upsertedBundles)
    await self.deleteAssets(changes.deletedAssets)

    await prefetchAllAssetsForDevice()

    if config.tags.enabled, let keywords = changes.keywords {
      await syncTags(keywords, changedIds: Set(immichIds))
    }

    if config.albums.enabled {
      await syncAlbums(changes.upsertedAlbums)
      await deleteAlbums(changes.deletedAlbums)
    }

    reportSyncCompletion(mode: "Delta")
  }

  private func reportSyncCompletion(mode: String) {
    let summary = Log.summary()
    if summary.hasErrors {
      Self.log.progress("\(mode) sync completed with critical errors. Try re-running, or manually resolve issues.")
    } else if summary.hasWarnings {
      Self.log.progress("\(mode) sync completed, with warnings.")
    } else {
      Self.log.progress("\(mode) sync completed successfully.")
    }
  }

  func preFetchDeviceAssetIds(_ assetBundles: [AssetBundle]) async {
    let localAssetIds = expectedDeviceAssetIds(assetBundles)
    await preFetchDeviceAssetIds(Array(localAssetIds))
  }

  /// Builds a set of `deviceAssetId`s we expect to exist in Immich, after a sync.
  /// Used by full-sync to prune remote assets that do not exist locally.
  internal func expectedDeviceAssetIds(_ assetBundles: [AssetBundle]) -> Set<String> {
    var ids = Set<String>()
    for bundle in assetBundles {
      for resource in bundle.resources {
        ids.insert(bundle.getDeviceAssetId(for: resource.key))
      }
    }
    return ids
  }

  func preFetchDeviceAssetIds(_ deviceAssetIds: [String]) async {
    // Then split them into batches as needed.
    let localAssetBatches = stride(from: 0, to: deviceAssetIds.count, by: config.idCheckBatchSize).map {
      Array(deviceAssetIds[$0..<min($0 + config.idCheckBatchSize, deviceAssetIds.count)])
    }

    let remoteDeviceAssetIds = await withTaskGroup(of: [String].self) { group in
      localAssetBatches.forEach { idBatch in
        group.addTask {
          do {
            return try await self.client.checkExistingAssets(idBatch)
          } catch {
            Self.log.warning(
              "Error while fetching existing deviceAssetIds.",
              stage: .uploadAsset,
              cause: error
            )
            return []
          }
        }
      }
      return await group.reduce(into: [String]()) { a, b in
        a.append(contentsOf: b)
      }
    }
    Self.log.progress("Pre-fetch found \(remoteDeviceAssetIds.count)/\(deviceAssetIds.count) pre-existing files.")
    await self.assetCache.addExistingDeviceAssetIds(Set(remoteDeviceAssetIds))
  }

  @discardableResult
  private func prefetchAllAssetsForDevice() async -> Bool {
    guard config.assets.delete || config.albums.enabled || config.tags.enabled else {
      return true
    }
    do {
      let assets = try await client.searchAssets(
        Components.Schemas.MetadataSearchDto(deviceId: IMMICH_DEVICE_ID))
      for asset in assets {
        await self.assetCache.add(asset)
      }
      return true
    } catch {
      Self.log.warning(
        "Asset prefetch by deviceId failed. Pruning orphan assets will be skipped. Album/tag sync may use per-asset lookup.",
        stage: .uploadAsset,
        cause: error
      )
      return false
    }
  }

  func processBundle(bundle: AssetBundle) async -> [String] {
    do {
      return try await self.downloadLimiter.withSlot {
        var resultIds: [String] = []
        await self.downloadManager.downloadBundle(bundle) { result in
          switch result {
          case .success(let download):
            // The bundle's resources have been downloaded, sync them to Immich.
            resultIds = await self.syncAssetBundle(bundle: bundle, files: download.files)
          case .failure(let error):
            // An error occurred, so log it and be done.
            Self.log.error(
              "Error downloading asset resources. Skipping upload.",
              stage: .uploadAsset,
              context: Self.errorContext(
                (.localIdentifier, bundle.asset.localIdentifier),
                (.filename, bundle.resources[.original]?.originalFilename)
              ),
              cause: error
            )
          }
        }
        return resultIds
      }
    } catch is CancellationError {
      // A cancelled wait for a semaphore slot produces no ids, mirroring the
      // prior busy-wait limiter's behavior.
      return []
    } catch {
      // Unreachable today: the closure above is non-throwing, so `withSlot`
      // can only surface `CancellationError` from `acquire()`. Surface loudly
      // in debug if a future throwing closure is added without updating this site.
      assertionFailure("Unexpected error from downloadLimiter.withSlot: \(error)")
      Self.log.error("Unexpected error from downloadLimiter.withSlot.", cause: error)
      return []
    }
  }

  func uploadAssets(_ assetBundles: [AssetBundle]) async -> [String] {
    Self.log.progress("Syncing \(assetBundles.count) assets...")

    var uploadCount: Int = 0
    // Process bundles and collect the resulting Immich Ids
    return await withTaskGroup(of: [String].self, returning: [String].self) { group in
      assetBundles.forEach { bundle in
        group.addTask { await self.processBundle(bundle: bundle) }
      }
      var collectedIds: [String] = []
      for await ids in group {
        collectedIds.append(contentsOf: ids)
        if ids.isEmpty {
          Self.log.debug("Asset processed without uploads.")
        } else {
          uploadCount += 1
          if (uploadCount % 100) == 0 {
            Self.log.progress("...\(uploadCount)/\(assetBundles.count)...")
          }
        }
      }
      return collectedIds
    }
  }

  func uploadNewFile(
    _ file: ResourceFile, type: AssetType, bundle: AssetBundle, livePhotoId: String?, deviceAssetIdKnown: Bool
  ) async -> String? {
    let deviceAssetId = bundle.getDeviceAssetId(for: type)
    let createDto: [Components.Schemas.AssetMediaCreateDto]
    do {
      createDto = try buildCreateDto(
        deviceAssetId: deviceAssetId,
        file: file,
        type: type,
        assetBundle: bundle,
        livePhotoId: livePhotoId
      )
    } catch {
      Self.log.error(
        "Error building AssetMediaCreateDto.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, type.rawValue),
          (.deviceAssetId, deviceAssetId),
          (.filename, file.originalFileName)
        ),
        cause: error
      )
      return nil
    }
    let result: Components.Schemas.AssetMediaResponseDto
    do {
      result = try await client.uploadAsset(createDto)
      Self.log.info(
        "Successfully uploaded asset.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.immichId, "\(result.id):\(result.status.value1.rawValue)"),
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, type.rawValue),
          (.deviceAssetId, deviceAssetId),
          (.filename, file.originalFileName)
        )
      )
    } catch {
      Self.log.error(
        "Error during uploadAsset call.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, type.rawValue),
          (.deviceAssetId, deviceAssetId),
          (.filename, file.originalFileName)
        ),
        cause: error
      )
      return nil
    }

    if let description = bundle.getImmichDescription(), result.status.value1 == .created, type != .livephoto {
      // The file has a description, it was uploaded, and it's NOT a Live Photo.
      // So let's set the description.
      do {
        let updateDto = Components.Schemas.UpdateAssetDto(description: description)
        let _ = try await client.updateAssetInfo(id: result.id, data: updateDto)
      } catch {
        Self.log.warning(
          "Error updating asset info.",
          stage: .uploadAsset,
          context: Self.errorContext(
            (.immichId, result.id),
            (.localIdentifier, bundle.asset.localIdentifier),
            (.assetType, "\(type.rawValue)"),
            (.deviceAssetId, deviceAssetId),
            (.filename, file.originalFileName)
          ),
          cause: error
        )
      }
    } else if result.status.value1 == .duplicate {
      // Immich Already has the file, so let's fetch it and evaluate what to do.
      let asset: Components.Schemas.AssetResponseDto
      do {
        asset = try await assetCache.resolve(immichId: result.id)
      } catch {
        Self.log.error(
          "Duplicate asset found; error while fetching asset for resolution.",
          stage: .uploadAsset,
          context: Self.errorContext(
            (.immichId, result.id),
            (.localIdentifier, bundle.asset.localIdentifier),
            (.assetType, "\(type.rawValue)"),
            (.deviceAssetId, deviceAssetId),
            (.filename, file.originalFileName)
          ),
          cause: error
        )
        /* We were unable to fetch asset from Immich. We don't know if this is just an update operation
         * (deviceAssetIds match) OR if there's some potential data corruption.
         * Let's bail out here to avoid making mistakes
         */
        return result.id
      }

      if asset.deviceAssetId == deviceAssetId {
        /* Our deviceAssetIds match, so we're probably just updating a known asset.
         * This *should* have been caught earlier by hash checking, but it's possible that failed
         * and we're just in a fallback scenario.
         */
        await self.updateFileMetadata(result.id, bundle: bundle, type: type)
        await self.updateFileInfo(result.id, bundle: bundle, type: type, livePhotoId: livePhotoId)
      } else if asset.deviceId == IMMICH_DEVICE_ID {
        /* Here, our deviceAssetId doesn't match, but our deviceId does.
         * This should never actually happen, but it suggests our upload proccess messed up at some point.
         */
        Self.log.error(
          "Duplicate asset found, but deviceAssetId mismatch! This probably indicates duplicate Photos entries: Resolve duplicates in Photos and re-run full sync.",
          stage: .uploadAsset,
          context: Self.errorContext(
            (.immichId, result.id),
            (.localIdentifier, bundle.asset.localIdentifier),
            (.assetType, "\(type.rawValue)"),
            (.deviceAssetId, deviceAssetId),
            (.filename, file.originalFileName)
          )
        )
      } else {
        /* Finally, our deviceId and deviceAssetId are both different.
         * This suggests the file was uploaded by something else. We don't (yet) have the ability to take over
         * assets.
         */
        Self.log.warning(
          "Duplicate asset found, but deviceId mismatch! Assuming this asset uploaded by something else. Skipping.",
          stage: .uploadAsset,
          context: Self.errorContext(
            (.immichId, result.id),
            (.localIdentifier, bundle.asset.localIdentifier),
            (.assetType, "\(type.rawValue)"),
            (.deviceAssetId, deviceAssetId),
            (.filename, file.originalFileName)
          )
        )
        return nil
      }
    }
    return result.id
  }

  func buildAssetMetadataDto(_ bundle: AssetBundle, type: AssetType) throws
    -> Components.Schemas.AssetMetadataUpsertItemDto
  {
    let metadata = [
      "phAssetCloudIdentifier": bundle.cloudIdentifier,
      "phAssetLocalIdentifier": bundle.asset.localIdentifier,
      "burstIdentifier": bundle.asset.burstIdentifier,
      "resourceType": type.rawValue,
      "originalFilename": bundle.resources[type]?.originalFilename,
    ]
    return Components.Schemas.AssetMetadataUpsertItemDto(
      key: IMMICH_DEVICE_ID, value: try .init(unvalidatedValue: metadata))
  }

  func updateFileMetadata(_ id: String, bundle: AssetBundle, type: AssetType) async {
    let data: Components.Schemas.AssetMetadataUpsertItemDto
    do {
      data = try buildAssetMetadataDto(bundle, type: type)
    } catch {
      Self.log.error(
        "While updating asset metadata, error while constructing metadata dto.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.immichId, id),
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, "\(type.rawValue)"),
          (.deviceAssetId, bundle.getDeviceAssetId(for: type)),
          (.filename, bundle.resources[type]?.originalFilename)
        )
      )
      return
    }
    do {
      let _ = try await client.updateAssetMetadata(id: id, data: [data])
    } catch {
      Self.log.error(
        "Error during updateAssetMetdata call.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.immichId, id),
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, "\(type.rawValue)"),
          (.deviceAssetId, bundle.getDeviceAssetId(for: type)),
          (.filename, bundle.resources[type]?.originalFilename)
        )
      )
      return
    }
  }

  func updateFileInfo(_ id: String, bundle: AssetBundle, type: AssetType, livePhotoId: String?) async {
    guard config.assets.overwriteInfo else {
      Self.log.info(
        "overWriteAssetInfo=false; Skipping update.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.immichId, id),
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, "\(type.rawValue)"),
          (.deviceAssetId, bundle.getDeviceAssetId(for: type)),
          (.filename, bundle.resources[type]?.originalFilename)
        )
      )
      return
    }

    let updateDto = Components.Schemas.UpdateAssetDto(
      description: bundle.getImmichDescription(),
      isFavorite: bundle.asset.isFavorite,
      latitude: bundle.asset.location?.coordinate.latitude,
      livePhotoVideoId: livePhotoId,
      longitude: bundle.asset.location?.coordinate.longitude
    )

    do {
      let _ = try await client.updateAssetInfo(id: id, data: updateDto)
      Self.log.info(
        "Asset Update Successful.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.immichId, id),
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, "\(type.rawValue)"),
          (.deviceAssetId, bundle.getDeviceAssetId(for: type)),
          (.filename, bundle.resources[type]?.originalFilename)
        )
      )
    } catch {
      Self.log.warning(
        "Error during updateAssetInfo call.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.immichId, id),
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, "\(type.rawValue)"),
          (.deviceAssetId, bundle.getDeviceAssetId(for: type)),
          (.filename, bundle.resources[type]?.originalFilename)
        ),
        cause: error
      )
    }
  }

  func copyAsset(
    _ file: ResourceFile, type: AssetType, bundle: AssetBundle, livePhotoId: String?, deviceAssetIdKnown: Bool
  ) async -> String? {
    let oldAsset: Components.Schemas.AssetResponseDto?
    let deviceAssetId = bundle.getDeviceAssetId(for: type)
    // Fetch our asset by deviceAssetId.
    do {
      oldAsset = try await assetCache.resolve(deviceAssetId: deviceAssetId)
    } catch {
      Self.log.error(
        "During copy asset, error fetching old asset by deviceAssetId",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, type.rawValue),
          (.deviceAssetId, deviceAssetId),
          (.filename, file.originalFileName)
        ),
        cause: error
      )
      return nil
    }
    guard let oldAsset else {
      Self.log.error(
        "During copy asset, unexpected result, fetching old asset by deviceAssetId returned nil.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, type.rawValue),
          (.deviceAssetId, deviceAssetId),
          (.filename, file.originalFileName)
        )
      )
      return nil
    }

    // Upload the new asset.
    let newId = await uploadNewFile(
      file, type: type, bundle: bundle, livePhotoId: livePhotoId, deviceAssetIdKnown: deviceAssetIdKnown)
    guard let newId else {
      Self.log.error(
        "During copy asset, asset upload failed.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, type.rawValue),
          (.deviceAssetId, deviceAssetId),
          (.filename, file.originalFileName)
        )
      )
      return nil
    }

    // Copy old->new
    do {
      try await self.client.copyAsset(sourceId: oldAsset.id, targetId: newId)
    } catch {
      Self.log.error(
        "During asset copy, error copying over asset info from \(oldAsset.id). Skipping delete of old asset. Manual remediation required.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.immichId, newId),
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, type.rawValue),
          (.deviceAssetId, deviceAssetId),
          (.filename, file.originalFileName)
        ),
        cause: error
      )
      // This is fatal in that it requires remediation, but we can continue with processing.
      return newId
    }

    // Delete the OLD asset
    do {
      try await self.client.deleteAsset(oldAsset.id, force: config.assets.forceDelete)
      await assetCache.clear(immichId: oldAsset.id)
    } catch {
      Self.log.error(
        "After copying asset, error while deleting old asset. Manual remediation required.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.immichId, oldAsset.id),
          (.localIdentifier, bundle.asset.localIdentifier),
          (.assetType, type.rawValue),
          (.deviceAssetId, deviceAssetId),
          (.filename, file.originalFileName)
        )
      )
    }
    return newId
  }

  func syncAssetBundle(bundle: AssetBundle, files: [AssetType: ResourceFile]) async -> [String] {
    let bulkUploadCheckItems: [Components.Schemas.AssetBulkUploadCheckItem] = files.map { resourceItem in
      Components.Schemas.AssetBulkUploadCheckItem(
        checksum: resourceItem.value.hash,
        id: bundle.getDeviceAssetId(for: resourceItem.key)
      )
    }
    let hashes: [String: Components.Schemas.AssetBulkUploadCheckResult]
    do {
      hashes = try await self.client.bulkUploadCheck(bulkUploadCheckItems)
    } catch {
      Self.log.warning("Error during upload hash check.", stage: .uploadAsset, cause: error)
      hashes = [:]
    }

    var livePhotoId: String? = nil
    var resultImmichIds: [String] = []
    var assetsToStack: [String] = []

    for (type, resourceFile) in files.sorted(by: { $0.key < $1.key }) {
      var immichAssetId: String? = nil

      let deviceAssetId = bundle.getDeviceAssetId(for: type)
      let deviceAssetIdExists = await assetCache.hasExistingDeviceAssetId(deviceAssetId)
      let hashCheck = hashes[deviceAssetId]

      if hashCheck == nil || (hashCheck!.action == .accept && !deviceAssetIdExists) {
        // This is a net-new file.
        immichAssetId = await self.uploadNewFile(
          resourceFile,
          type: type,
          bundle: bundle,
          livePhotoId: livePhotoId,
          deviceAssetIdKnown: deviceAssetIdExists
        )
      } else if hashCheck!.action == .accept && deviceAssetIdExists {
        // Our deviceAssetId exists, but Immich thinks this is a new file
        // So we assume the underlying file changed. Do a copy operation.
        immichAssetId = await self.copyAsset(
          resourceFile,
          type: type,
          bundle: bundle,
          livePhotoId: livePhotoId,
          deviceAssetIdKnown: deviceAssetIdExists
        )
      } else if hashCheck!.action == .reject && hashCheck!.reason == .duplicate && hashCheck!.id == deviceAssetId {
        // File exists & matches device asset id, just do a metadata update.
        guard let id = hashCheck?.assetId else {
          Self.log.error(
            "During Asset Sync: Known duplicate found, attempted to update asset info, but could not resolve ImmichId",
            stage: .uploadAsset,
            context: Self.errorContext(
              (.localIdentifier, bundle.asset.localIdentifier),
              (.assetType, type.rawValue),
              (.deviceAssetId, deviceAssetId),
              (.filename, resourceFile.originalFileName)
            )
          )
          continue
        }
        await self.updateFileInfo(id, bundle: bundle, type: type, livePhotoId: livePhotoId)
        immichAssetId = id
      } else if hashCheck!.action == .reject && hashCheck!.reason == .duplicate && hashCheck!.id != deviceAssetId {
        // The file exists, but its deviceAssetId is different than what we expect.
        // Chances are good this file is not managed by us.
        Self.log.warning(
          "During Asset Sync: Asset found, but deviceAssetId mismatch! Assuming this was uploaded by something else. Skipping",
          stage: .uploadAsset,
          context: Self.errorContext(
            (.immichId, hashCheck?.assetId),
            (.localIdentifier, bundle.asset.localIdentifier),
            (.assetType, type.rawValue),
            (.deviceAssetId, deviceAssetId),
            (.filename, resourceFile.originalFileName)
          )
        )
      } else {
        Self.log.warning(
          "During Asset Sync: Immich rejected upload with unknown reason.",
          stage: .uploadAsset,
          context: Self.errorContext(
            (.immichId, hashCheck?.assetId),
            (.localIdentifier, bundle.asset.localIdentifier),
            (.assetType, type.rawValue),
            (.deviceAssetId, deviceAssetId),
            (.filename, resourceFile.originalFileName)
          )
        )
      }

      guard let immichAssetId else {
        continue
      }

      // We've finished syncing the file (either an upload, update, or copy/delete).
      resultImmichIds.append(immichAssetId)
      // Add our id mapping to our cache
      await assetCache.addId(immichId: immichAssetId, deviceAssetId: deviceAssetId)
      if type == .livephoto {
        // If the file we processed was the Live Photo paired video,
        // Set that field so we properly persist it for other variants.
        livePhotoId = immichAssetId
      } else {
        // Otherwise, add it to the list of assets to stack.
        // (Live Photos aren't stacked)
        assetsToStack.append(immichAssetId)
      }
    }

    // We've completed uploading all our files, now try and stack them if applicable.
    await stackAssets(assetsToStack)

    return resultImmichIds
  }

  func stackAssets(_ ids: [String]) async {
    guard ids.count > 1 else {
      // Can't stack a single asset.
      return
    }
    do {
      let _ = try await self.client.stackAssets(ids: ids)
      await stacks.add(ids: ids)
    } catch {
      Self.log.error(
        "Error creating Asset Stack",
        stage: .uploadAsset,
        context: Self.errorContext((.immichId, ids[0])),
        cause: error
      )
    }
  }

  func buildCreateDto(
    deviceAssetId: String, file: ResourceFile, type: AssetType, assetBundle bundle: AssetBundle, livePhotoId: String?
  )
    throws
    -> [Components.Schemas.AssetMediaCreateDto]
  {
    var data: [Components.Schemas.AssetMediaCreateDto] = []
    // Asset File Data
    do {
      data.append(
        .assetData(.init(payload: .init(body: .init(try Data(contentsOf: file.url))), filename: file.originalFileName)))
    } catch {
      throw error
    }
    data.append(.deviceId(.init(payload: .init(body: .init(stringLiteral: IMMICH_DEVICE_ID)))))
    data.append(.deviceAssetId(.init(payload: .init(body: .init(stringLiteral: deviceAssetId)))))
    data.append(.filename(.init(payload: .init(body: .init(stringLiteral: file.originalFileName)))))
    data.append(
      .isFavorite(
        .init(payload: .init(body: .init(stringLiteral: bundle.asset.isFavorite ? "true" : "false"))))
    )

    let createdAt = (bundle.asset.creationDate ?? Date()).formatted(.iso8601)
    data.append(.fileCreatedAt(.init(payload: .init(body: .init(createdAt)))))
    let modifiedAt = bundle.asset.modificationDate?.formatted(.iso8601) ?? createdAt
    data.append(.fileModifiedAt(.init(payload: .init(body: .init(modifiedAt)))))

    if bundle.asset.duration > 0 {
      data.append(
        .duration(.init(payload: .init(body: .init(stringLiteral: formatImmichDuration(bundle.asset.duration))))))
    }

    if let livePhotoId {
      data.append(.livePhotoVideoId(.init(payload: .init(body: .init(stringLiteral: livePhotoId)))))
    }

    do {
      let metadataDto = try buildAssetMetadataDto(bundle, type: type)
      data.append(.metadata(.init(payload: .init(body: metadataDto))))
    } catch {
      throw error
    }
    return data
  }

  func deleteAssets(_ assetIds: [String]) async {
    guard config.assets.delete else {
      Self.log.progress("Asset deletion is disabled. Skipping.")
      return
    }
    // The asset was removed from Photos so we weren't able to figure out what kinds of alternate asset versions
    // might exist, we just expand our list out to all possible ones.
    let expandedDeviceAssetIds = assetIds.flatMap({ id in AssetType.allCases.map({ t in t.deviceAssetId(id: id) }) })

    var immichIds: [String] = []
    for deviceAssetId in expandedDeviceAssetIds {
      // Attempt to load the asset by its deviceAssetId
      // We need to get the immichId anyway, and we can log stack ids to delete.
      let asset: Components.Schemas.AssetResponseDto?
      do {
        asset = try await assetCache.resolve(deviceAssetId: deviceAssetId)
      } catch {
        Self.log.warning(
          "Error resolving Immich asset by deviceAssetId.",
          stage: .deleteAsset,
          context: Self.errorContext((.deviceAssetId, deviceAssetId)),
          cause: error
        )
        continue
      }
      guard let asset else {
        Self.log.info(
          "No asset found to delete.",
          stage: .deleteAsset,
          context: Self.errorContext((.deviceAssetId, deviceAssetId))
        )
        continue
      }

      immichIds.append(asset.id)
    }

    // Delete our assets in bulk
    if !immichIds.isEmpty {
      do {
        try await client.deleteAssets(immichIds, force: config.assets.forceDelete)
        Self.log.progress("Deleted \(immichIds.count) assets.")
      } catch {
        Self.log.error("Error in deleteAssets call.", stage: .deleteAsset, cause: error)
      }
    }
  }

  func pruneOrphanAssets(expected: Set<String>) async {
    guard config.assets.delete else {
      Self.log.progress("Asset deletion is disabled. Skipping.")
      return
    }
    let cached = await assetCache.allAssets()
    let orphans = cached.filter { asset in
      asset.deviceId == IMMICH_DEVICE_ID && !expected.contains(asset.deviceAssetId)
    }
    guard !orphans.isEmpty else {
      Self.log.progress("No orphan assets to prune.")
      return
    }

    let orphanIds = orphans.map(\.id)
    do {
      try await client.deleteAssets(orphanIds, force: config.assets.forceDelete)
      for id in orphanIds {
        await assetCache.clear(immichId: id)
      }
      Self.log.progress("Pruned \(orphanIds.count) orphan assets.")
    } catch {
      Self.log.error(
        "Error pruning orphan assets. Orphans assets may remain and require manual cleanup.",
        stage: .deleteAsset,
        cause: error
      )
    }
  }

  private func fetchTags(tagPrefix: String) async throws -> [String: String] {
    let tags = try await client.getAllTags()
    return Dictionary(
      tags.filter { $0.value.starts(with: tagPrefix) }.map { ($0.value, $0.id) }
    ) { existing, duplicate in
      Self.log.warning(
        "fetchTags: duplicate tag value; keeping id \(existing), ignoring \(duplicate)"
      )
      return existing
    }
  }

  private func buildKeywordMap(keywords: [PhotosKeyword], tagPrefix: String) -> [String: PhotosKeyword] {
    var map: [String: PhotosKeyword] = [:]
    for keyword in keywords where !keyword.assetIds.isEmpty {
      map["\(tagPrefix)\(keyword.keyword)"] = keyword
    }
    return map
  }

  private func shouldDeleteTag(tagValue: String, desiredTagValues: Set<String>) -> Bool {
    guard !desiredTagValues.contains(tagValue) else {
      return false
    }
    let childPrefix = "\(tagValue)/"
    return !desiredTagValues.contains(where: { $0.starts(with: childPrefix) })
  }

  private func resolveKeywordAssetIds(_ keyword: PhotosKeyword, tagId: String, tagValue: String) async -> Set<String> {
    var resolvedIds: Set<String> = []
    for deviceAssetId in keyword.assetIds {
      do {
        if let asset = try await assetCache.resolve(deviceAssetId: deviceAssetId) {
          resolvedIds.insert(asset.stack?.value1.primaryAssetId ?? asset.id)
        } else {
          Self.log.warning(
            "Unable to resolve asset for tagging. Tagging may be incomplete.",
            stage: .syncTag,
            context: Self.errorContext(
              (.tagId, tagId),
              (.deviceAssetId, deviceAssetId),
              (.tagName, tagValue)
            )
          )
        }
      } catch {
        Self.log.warning(
          "Error resolving asset for tagging. Tagging may be incomplete.",
          stage: .syncTag,
          context: Self.errorContext(
            (.tagId, tagId),
            (.deviceAssetId, deviceAssetId),
            (.tagName, tagValue)
          ),
          cause: error
        )
      }
    }
    return resolvedIds
  }

  func syncTags(_ keywords: [PhotosKeyword], changedIds: Set<String>) async {
    Self.log.progress("Starting Tag Sync")
    let tagPrefix = config.tags.parentTag.isEmpty ? "" : "\(config.tags.parentTag)/"
    var tagValueToIdMap: [String: String]
    do {
      tagValueToIdMap = try await fetchTags(tagPrefix: tagPrefix)
    } catch {
      Self.log.error("Error fetching tag list from Immich. Skipping tag sync.", stage: .syncTag, cause: error)
      return
    }

    let keywordsByTagValue = buildKeywordMap(keywords: keywords, tagPrefix: tagPrefix)
    let desiredTagValues = Set(keywordsByTagValue.keys)
    let remoteTagValues = Set(tagValueToIdMap.keys)

    // Create any missing managed tags
    let tagsToCreate = Array(desiredTagValues.subtracting(remoteTagValues)).sorted()
    if !tagsToCreate.isEmpty {
      do {
        let createdTags = try await self.client.upsertTags(tags: tagsToCreate)
        createdTags.forEach { tag in
          tagValueToIdMap[tag.value] = tag.id
          Self.log.progress("Tag Sync: Created new tag: \(tag.value)")
        }
      } catch {
        Self.log.warning("Error creating new tags. Tagging may be incomplete.", stage: .syncTag, cause: error)
      }
    }

    if config.tags.delete {
      // Delete managed remote tags that no longer exist locally.
      // Keep ancestor tags for nested desired tags.
      let tagsToDelete =
      remoteTagValues
        .filter({ shouldDeleteTag(tagValue: $0, desiredTagValues: desiredTagValues) })
        .sorted()
      await withDiscardingTaskGroup { group in
        for tagValue in tagsToDelete {
          guard let tagId = tagValueToIdMap[tagValue] else {
            continue
          }
          group.addTask {
            do {
              try await self.client.deleteTag(tagId)
              Self.log.progress("Tag Sync: Deleted tag: \(tagValue)")
            } catch {
              Self.log.warning(
                "Error deleting stale tag. Stale tags may remain in Immich.",
                stage: .deleteTag,
                context: Self.errorContext(
                  (.tagId, tagId),
                  (.tagName, tagValue)
                ),
                cause: error
              )
            }
          }
        }
      }
    }
    else {
      Self.log.progress("Tag Sync: Tag deletion disabled, skipping.")
    }

    await withDiscardingTaskGroup { group in
      for (tagValue, keyword) in keywordsByTagValue.sorted(by: { $0.key < $1.key }) {
        group.addTask {
          guard let tagId = tagValueToIdMap[tagValue] else {
            Self.log.warning(
              "Unable to resolve id for tag. Skipping syncing this tag.",
              stage: .syncTag,
              context: Self.errorContext((.tagName, keyword.keyword))
            )
            return
          }

          // Resolve the keyword deviceAssetIds into Immich ids, and ensure we're referencing the primary id for any stack
          let mappedImmichIds = await self.resolveKeywordAssetIds(keyword, tagId: tagId, tagValue: tagValue)
          var desiredImmichIds: Set<String> = []
          for id in mappedImmichIds {
            desiredImmichIds.formUnion(
              Set(await self.stacks.resolveIds(id: id, primaryOnly: self.config.tags.stackPrimaryOnly)))
          }

          // Fetch current remote membership for this tag.
          var remoteTaggedAssetIds: Set<String> = []
          var remoteAssetsFetched = false
          do {
            let remoteTaggedAssets = try await self.client.searchAssets(
              Components.Schemas.MetadataSearchDto(deviceId: IMMICH_DEVICE_ID, tagIds: [tagId]))
            remoteAssetsFetched = true
            remoteTaggedAssetIds = Set(remoteTaggedAssets.map(\.id))
          } catch {
            Self.log.warning(
              "Error while fetching assets for tag. Old assets will not be untagged.",
              stage: .syncTag,
              context: Self.errorContext(
                (.tagId, tagId),
                (.tagName, keyword.keyword)
              ),
              cause: error
            )
          }

          let assetsToTag: [String]
          let assetsToUntag: [String]
          if remoteAssetsFetched {
            assetsToTag = Array(desiredImmichIds.subtracting(remoteTaggedAssetIds))
            assetsToUntag = Array(remoteTaggedAssetIds.intersection(changedIds).subtracting(desiredImmichIds))
          } else {
            assetsToTag = Array(desiredImmichIds)
            assetsToUntag = []
          }

          if !assetsToTag.isEmpty {
            do {
              let result = try await self.client.tagAssets(tagId: tagId, assetIds: assetsToTag)
              Self.log.progress("\(tagValue): Added \(result.filter(\.success).count) assets.")
            } catch {
              Self.log.error(
                "Error tagging assets.",
                stage: .syncTag,
                context: Self.errorContext(
                  (.tagId, tagId),
                  (.tagName, tagValue)
                ),
                cause: error
              )
            }
          }

          if !assetsToUntag.isEmpty {
            do {
              let result = try await self.client.untagAssets(tagId: tagId, assetIds: assetsToUntag)
              Self.log.progress("\(tagValue): Removed \(result.filter(\.success).count) assets.")
            } catch {
              Self.log.error(
                "Error un-tagging assets.",
                stage: .syncTag,
                context: Self.errorContext(
                  (.tagId, tagId),
                  (.tagName, tagValue)
                ),
                cause: error
              )
            }
          }
        }
      }
    }
    Self.log.progress("Completed Tag Sync")
  }

  private func resolvePrimaryStackedIds(deviceAssetId: String, primaryOnly: Bool) async throws -> [String]? {
    guard let asset = try await assetCache.resolve(deviceAssetId: deviceAssetId) else { return nil }
    let primaryId = asset.stack?.value1.primaryAssetId ?? asset.id
    return await stacks.resolveIds(id: primaryId, primaryOnly: primaryOnly)
  }

  internal func uploadNewAlbum(album: PhotosAlbum) async {
    let albumName = album.getName(separator: config.albums.pathSeparator)

    guard !album.assetIds.isEmpty || config.albums.createEmpty else {
      Self.log.info(
        "Skipping album creation for empty album; use createEmpty: true to create empty albums.",
        stage: .createAlbum,
        context: Self.errorContext(
          (.localIdentifier, album.localIdentifier),
          (.albumName, albumName)
        )
      )
      return
    }

    Self.log.progress("Creating album: \(albumName), with \(album.assetIds.count) assets")
    // Resolve our albumAssets into immich asset ids.
    var idsToAdd: [String] = []
    for deviceAssetId in album.assetIds {
      do {
        if let resolved = try await resolvePrimaryStackedIds(
          deviceAssetId: deviceAssetId, primaryOnly: config.albums.stackPrimaryOnly)
        {
          idsToAdd.append(contentsOf: resolved)
        } else {
          Self.log.warning(
            "Unable to find Immich asset for deviceAssetId",
            stage: .createAlbum,
            context: Self.errorContext(
              (.deviceAssetId, deviceAssetId),
              (.localIdentifier, album.localIdentifier),
              (.albumName, albumName)
            )
          )
        }
      } catch {
        Self.log.error(
          "Error fetching Immich asset for deviceAssetId.",
          stage: .createAlbum,
          context: Self.errorContext(
            (.deviceAssetId, deviceAssetId),
            (.localIdentifier, album.localIdentifier),
            (.albumName, albumName)
          ),
          cause: error
        )
      }
    }
    do {
      // Create the album and add our assets to it.
      let _ = try await self.client.createAlbum(
        albumName, assetIds: idsToAdd, description: client.generateAlbumTag(album.localIdentifier))
      Self.log.progress("\(albumName): Created with \(idsToAdd.count)/\(album.assetIds.count) assets.")
    } catch {
      Self.log.error(
        "Error while creating album.",
        stage: .createAlbum,
        context: Self.errorContext(
          (.localIdentifier, album.localIdentifier),
          (.albumName, albumName)
        ),
        cause: error
      )
    }
  }

  internal func syncExistingAlbum(photosAlbum: PhotosAlbum, immichAlbum: Components.Schemas.AlbumResponseDto) async {
    // The album exists remotely
    var immichAlbum = immichAlbum

    // Check to see if we need to change the album name.
    let albumName = photosAlbum.getName(separator: config.albums.pathSeparator)
    if albumName != immichAlbum.albumName {
      do {
        let dto: Components.Schemas.UpdateAlbumDto = .init(albumName: albumName)
        immichAlbum = try await client.updateAlbum(immichAlbum.id, dto: dto)
        Self.log.info(
          "Album name update successful",
          stage: .syncAlbum,
          context: Self.errorContext(
            (.localIdentifier, photosAlbum.localIdentifier),
            (.albumId, immichAlbum.id),
            (.albumName, albumName)
          )
        )
      }
      catch {
        Self.log.warning(
          "Error changing album name to \(albumName). Manual name change may be required.",
          stage: .syncAlbum,
          context: Self.errorContext(
            (.albumId, immichAlbum.id),
            (.albumName, immichAlbum.albumName)
          ),
          cause: error
        )
      }
      return
    }
    // Be sure we're not JUST changing the album name
    guard !photosAlbum.nameChangeOnly else {
      Self.log.progress("Updated Album Name: \(albumName)")
      return
    }

    // Retrieve the remote album
    // The album passed in probably doesn't have asset membership info,
    // but retrieving it here will get us that.
    do {
      immichAlbum = try await self.client.getAlbum(immichAlbum.id)
    } catch {
      Self.log.error(
        "Error fetching album. Skipping.",
        stage: .syncAlbum,
        context: Self.errorContext(
          (.albumId, immichAlbum.id),
          (.albumName, immichAlbum.albumName)
        ),
        cause: error
      )
      return
    }

    // Resolve our deviceAssetIds into Immich Asset Ids.
    var immichIdsToAdd: [String] = []
    await withDiscardingTaskGroup { group in
      for deviceAssetId in photosAlbum.assetIds {
        group.addTask {
          do {
            if let resolved = try await self.resolvePrimaryStackedIds(
              deviceAssetId: deviceAssetId, primaryOnly: self.config.albums.stackPrimaryOnly)
            {
              immichIdsToAdd.append(contentsOf: resolved)
            } else {
              Self.log.warning(
                "Unable to find Immich asset for deviceAssetId",
                stage: .syncAlbum,
                context: Self.errorContext(
                  (.deviceAssetId, deviceAssetId),
                  (.albumId, immichAlbum.id),
                  (.albumName, immichAlbum.albumName)
                )
              )
            }
          } catch {
            Self.log.error(
              "Error fetching Immich asset for deviceAssetId.",
              stage: .syncAlbum,
              context: Self.errorContext(
                (.deviceAssetId, deviceAssetId),
                (.albumId, immichAlbum.id),
                (.albumName, immichAlbum.albumName)
              ),
              cause: error
            )
          }
        }
      }
    }

    var numAssetsAdded = 0
    var numAssetsRemoved = 0

    // Add our local assets to the album.
    // Immich will properly handle adding assets that may already be in the album.
    if !immichIdsToAdd.isEmpty {
      do {
        let result = try await self.client.addAssetsToAlbum(immichAlbum.id, assetIds: immichIdsToAdd)
        numAssetsAdded = result.filter(\.success).count
      } catch {
        Self.log.error(
          "Error adding assets to album.",
          stage: .syncAlbum,
          context: Self.errorContext(
            (.albumId, immichAlbum.id),
            (.albumName, immichAlbum.albumName)
          ),
          cause: error
        )
      }
    }

    let desiredAssetIds = Set(photosAlbum.assetIds)
    do {
      let immichIdsToRemove = immichAlbum.assets
        .filter({ $0.deviceId == IMMICH_DEVICE_ID })
        .filter({ a in
          // Resolve any alternate-version device asset ids to the base one,
          // which would be supplied in the assetids sent to this method.
          let baseAssetId =
            a.deviceAssetId.split(separator: ":", maxSplits: 1).first.map(String.init) ?? a.deviceAssetId
          return !desiredAssetIds.contains(baseAssetId)
        })
        .map({ $0.id })
      if !immichIdsToRemove.isEmpty {
        let result = try await self.client.removeAssetsFromAlbum(immichAlbum.id, assetIds: immichIdsToRemove)
        numAssetsRemoved = result.filter(\.success).count
      }
    } catch {
      Self.log.warning(
        "Error removing assets from album.",
        stage: .syncAlbum,
        context: Self.errorContext(
          (.albumId, immichAlbum.id),
          (.albumName, immichAlbum.albumName)
        ),
        cause: error
      )
    }

    if numAssetsAdded > 0 || numAssetsRemoved > 0 {
      Self.log.progress("\(immichAlbum.albumName): \(numAssetsAdded) assets added; \(numAssetsRemoved) removed")
    }
  }

  func syncAlbums(_ photosAlbums: [PhotosAlbum]) async {
    Self.log.progress("Syncing Photos albums.")

    let immichAlbums: [Components.Schemas.AlbumResponseDto]
    do {
      immichAlbums = try await albumListCache.get()
    } catch {
      Self.log.error("Error while fetching albums. Skipping album sync.", stage: .syncAlbum, cause: error)
      return
    }
    let immichAlbumMap = Dictionary(
      uniqueKeysWithValues: immichAlbums.map({ (client.extractAlbumTagValue($0.description), $0) }))

    await withDiscardingTaskGroup { group in
      for album in photosAlbums {
        group.addTask {
          if let immichAlbum = immichAlbumMap[album.localIdentifier] {
            await self.syncExistingAlbum(photosAlbum: album, immichAlbum: immichAlbum)
          }
          else {
            await self.uploadNewAlbum(album: album)
          }
        }
      }
    }
    Self.log.progress("Album sync complete.")
  }

  func deleteAlbums(_ albumIds: [String]) async {
    let albumIdSet = Set(albumIds)
    await deleteAlbums(matching: { albumIdSet.contains($0) })
  }

  func pruneOrphanAlbums(expected: Set<String>) async {
    await deleteAlbums(matching: { !expected.contains($0) })
  }

  private func deleteAlbums(matching predicate: (String) -> Bool) async {
    guard config.albums.delete else {
      Self.log.progress("Album deletion is disabled. Skipping.")
      return
    }
    let albums: [Components.Schemas.AlbumResponseDto]
    do {
      albums = try await albumListCache.get()
    } catch {
      Self.log.error("Error while fetching albums. Skipping album delete.", stage: .deleteAlbum, cause: error)
      return
    }
    var deleted = 0
    for album in albums {
      guard let albumLocalIdentifier = client.extractAlbumTagValue(album.description),
        predicate(albumLocalIdentifier)
      else { continue }
      do {
        try await self.client.deleteAlbum(album.id)
        deleted += 1
      } catch {
        Self.log.warning(
          "Error deleting album.",
          stage: .deleteAlbum,
          context: Self.errorContext(
            (.localIdentifier, albumLocalIdentifier),
            (.albumId, album.id),
            (.albumName, album.albumName)
          ),
          cause: error
        )
      }
    }
    if deleted > 0 {
      Self.log.progress("Deleted \(deleted) album(s).")
    }
  }
}
