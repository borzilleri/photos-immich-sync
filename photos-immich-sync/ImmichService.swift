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
  private let metadataClient: MetadataApiClient

  private var immichAssets: [String: Components.Schemas.AssetResponseDto] = [:]
  private var immichMetadata: [String: AssetMetadataValue] = [:]

  private var knownAssetIdentifiers: Set<String> = []
  private var assetIdentifierToImmichId: [String: String] = [:]

  /// `true` if the full managed set of assets has been loaded
  /// (via `prefetchMetadata()`)
  /// If true, a cache miss indicates the asset is not managed by us, when false
  /// a cache miss should result in a fallback lookup.
  private var fullyHydrated = false

  init(client: ImmichApiClient, metadataClient: MetadataApiClient) {
    self.client = client
    self.metadataClient = metadataClient
  }

  public func clear(immichId: String) {
    if let el = assetIdentifierToImmichId.first(where: {$0.value == immichId}) {
      assetIdentifierToImmichId.removeValue(forKey: el.key)
      knownAssetIdentifiers.remove(el.key)
    }
    immichAssets.removeValue(forKey: immichId)
    immichMetadata.removeValue(forKey: immichId)
  }

  public func add(_ metadata: MetadataEntry) {
    immichMetadata[metadata.assetId] = metadata.value
    if let id = metadata.value.assetIdentifier() {
      knownAssetIdentifiers.insert(id)
      assetIdentifierToImmichId[id] = metadata.assetId
    }
  }

  public func add(_ asset: Components.Schemas.AssetResponseDto) {
    immichAssets[asset.id] = asset
  }

  public func add(immichId: String, bundle: AssetBundle, type: AssetType) {
    let assetIdentifier = bundle.getAssetIdentifier(for: type)
    knownAssetIdentifiers.insert(assetIdentifier)
    assetIdentifierToImmichId[assetIdentifier] = immichId
  }

  public func resolve(immichId: String) async throws -> Components.Schemas.AssetResponseDto {
    if let asset = immichAssets[immichId] { return asset }
    let asset = try await client.getAsset(id: immichId)
    add(asset)
    return asset
  }

  public func resolve(localIdentifier: String, type: AssetType) async throws -> Components.Schemas.AssetResponseDto? {
    if let immichId = try await resolveId(localIdentifier: localIdentifier, type: type) {
      return try await resolve(immichId: immichId)
    }
    return nil
  }

  public func resolveId(localIdentifier: String, type: AssetType) async throws -> String? {
    if let immichId = cachedImmichId(localIdentifier: localIdentifier, type: type) {
      return immichId
    }
    let metadata = try await metadataClient.lookup(filters: [
      .init(field: .phAssetLocalIdentifier, value: localIdentifier),
      .init(field: .resourceType, value: type.rawValue),
    ]).first
    if let metadata {
      add(metadata)
      return metadata.assetId
    }
    return nil
  }

  public func isKnownIdentifier(assetIdentifier: String) -> Bool {
    return knownAssetIdentifiers.contains(assetIdentifier)
  }

  /// Return a list of ImmichIds from our tracked set of assets that are NOT in the set of asset ids passed in.
  func orphanImmichIds(expectedAssetIds: Set<String>) -> [String] {
    immichMetadata.compactMap { immichId, value in
      guard let assetId = value.assetIdentifier() else { return nil }
      return expectedAssetIds.contains(assetId) ? nil : immichId
    }
  }

  func metadata(forImmichId immichId: String) async -> AssetMetadataValue? {
    if let cached = immichMetadata[immichId] { return cached }
    if fullyHydrated { return nil }
    let fetched = (try? await client.getAssetMetadata(id: immichId)) ?? nil
    if let fetched { immichMetadata[immichId] = fetched }
    return fetched
  }

  /// Resolves a local identifier to an Immich id from the in-memory cache only, without
  /// falling back to the sidecar. Callers that run after `prefetchMetadata()` (which loads
  /// the full managed set) can rely on this for a pure in-memory lookup.
  func cachedImmichId(localIdentifier: String, type: AssetType) -> String? {
    return assetIdentifierToImmichId[type.assetIdentifier(id: localIdentifier)]
  }

  /// Loads metadata for all of our managed assets.
  /// Marks the cache fully hydrated so later misses are authoritative.
  func prefetchMetadata() async throws {
    let entries = try await metadataClient.enumerateManaged()
    for entry in entries {
      add(entry)
    }
    fullyHydrated = true
  }

  /// Loads metadata only for the given set of local identifiers. Used for delta processes where
  /// we're typically operating on a small subset of overall assets.
  func prefetchMetadata(localIdentifiers: Set<String>) async throws {
    let client = metadataClient
    try await withThrowingTaskGroup(of: [MetadataEntry].self) { group in
      for id in localIdentifiers {
        group.addTask { try await client.lookup(field: .phAssetLocalIdentifier, value: id) }
      }
      for try await entries in group {
        entries.forEach { add($0) }
      }
    }
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
  private let metadataClient: MetadataApiClient

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
    metadataClient: MetadataApiClient
  ) {
    self.client = client
    self.config = config
    self.fs = fileService
    self.downloadManager = photoDownloader
    self.downloadLimiter = downloadLimiter
    self.metadataClient = metadataClient
    self.assetCache = AssetCache(client: client, metadataClient: metadataClient)
    self.albumListCache = AlbumListCache(client: client)
  }

  func performFullSync(_ export: FullPhotosExport) async {
    let prefetched = await prefetchManagedMetadata()
    let immichIds = await uploadAssets(export.assetBundles)

    // Only prune assets if we know our export is complete AND we successfully pre-fetched metadata.
    // Without both we may have an incorrect picture of what our orphaned assets are, and we should err on the side of
    // not deleting data. A non-erroring full-sync will resolve these later.
    if prefetched && export.complete {
      await pruneOrphanAssets(bundles: export.assetBundles)
    } else if !export.complete {
      Self.log.warning(
        "Skipping orphan prune: the photo export was incomplete (some assets failed to export). Re-run once resolved to reconcile deletions."
      )
    } else {
      Self.log.warning("Skipping orphan prune because managed metadata prefetch failed.")
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
    // Delta only acts on the changed assets, so prefetch just their metadata rather than
    // enumerating the whole managed set (the full set is only needed by orphan pruning,
    // which delta never runs).
    let touched = Set(
      changes.upsertedBundles.map(\.asset.localIdentifier)
        + changes.deletedAssets
        + (changes.keywords?.flatMap(\.assetIds) ?? [])
        + changes.upsertedAlbums.flatMap(\.assetIds))
    let prefetched = await prefetchManagedMetadata(localIdentifiers: touched)
    let immichIds = await self.uploadAssets(changes.upsertedBundles)

    // Delete resolves assets from the prefetched managed set. Skip it if the prefetch
    // failed, so we never act on partial data (matching the full-sync prune guard).
    if prefetched {
      await self.deleteAssets(changes.deletedAssets)
    } else if !changes.deletedAssets.isEmpty {
      Self.log.error(
        "Skipping asset deletion: metadata prefetch failed, unable to resolve immich ids. Re-run delta sync when resolved retry.",
        stage: .deleteAsset)
    }

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

  /// Loads the full managed metadata set into the asset cache. Returns `true` on success;
  /// `false` if the enumeration failed (callers use this to gate the orphan prune).
  @discardableResult
  func prefetchManagedMetadata() async -> Bool {
    await runPrefetch { try await self.assetCache.prefetchMetadata() }
  }

  /// Loads managed metadata for the given local identifiers only (delta sync). Returns
  /// `true` on success; `false` if any lookup failed (callers gate deletion on this).
  @discardableResult
  func prefetchManagedMetadata(localIdentifiers: Set<String>) async -> Bool {
    await runPrefetch { try await self.assetCache.prefetchMetadata(localIdentifiers: localIdentifiers) }
  }

  private func runPrefetch(_ work: () async throws -> Void) async -> Bool {
    do {
      try await work()
      return true
    } catch {
      Self.log.warning("Failed to prefetch managed asset metadata; proceeding anyway", cause: error)
      return false
    }
  }

  /// Builds the set of asset identifiers we expect to exist in Immich, after a sync.
  /// Used by full-sync to prune remote assets that do not exist locally.
  internal func expectedAssetIdentifiers(_ assetBundles: [AssetBundle]) -> Set<String> {
    var ids = Set<String>()
    for bundle in assetBundles {
      for resource in bundle.resources {
        ids.insert(bundle.getAssetIdentifier(for: resource.key))
      }
    }
    return ids
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

  func uploadNewFile(_ file: ResourceFile, type: AssetType, bundle: AssetBundle, livePhotoId: String?) async -> String?
  {
    let createDto: [Components.Schemas.AssetMediaCreateDto]
    do {
      createDto = try buildCreateDto(
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
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, type.rawValue),
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
          (.immichId, "\(result.id):\(result.status.rawValue)"),
          (.localIdentifier, bundle.asset.localIdentifier),
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, type.rawValue),
          (.filename, file.originalFileName)
        )
      )
    } catch {
      Self.log.error(
        "Error during uploadAsset call.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.localIdentifier, bundle.asset.localIdentifier),
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, type.rawValue),
          (.filename, file.originalFileName)
        ),
        cause: error
      )
      return nil
    }

    if let description = bundle.getImmichDescription(), result.status == .created, type != .livephoto {
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
            (.cloudIdentifier, bundle.cloudIdentifier),
            (.assetType, "\(type.rawValue)"),
            (.filename, file.originalFileName)
          ),
          cause: error
        )
      }
    } else if result.status == .duplicate {
      // Immich says our upload is a duplicate. It's possible the hash-check failed and we're updating a known asset,
      // or it was upload by another process, or something went wrong.
      // Query for the asset metadata to see if we're tracking this asset.
      let metadata: AssetMetadataValue?
      do {
        metadata = try await client.getAssetMetadata(id: result.id)
      } catch {
        Self.log.error(
          "Duplicate asset found; error while fetching asset metadata for resolution.",
          stage: .uploadAsset,
          context: Self.errorContext(
            (.immichId, result.id),
            (.localIdentifier, bundle.asset.localIdentifier),
            (.cloudIdentifier, bundle.cloudIdentifier),
            (.assetType, "\(type.rawValue)"),
            (.filename, file.originalFileName)
          ),
          cause: error
        )
        /* We were unable to fetch asset metadata from Immich. Without this we don't really know how to resolve this,
         * so we're just going to bail out at this point, rather than make a mistake. */
        return result.id
      }

      if let metadata, metadata.matchesBundle(bundle, type: type) {
        /* Immich says this was a duplicate, but this asset is tracked by us and our metadata matches, so this is
         * probably just updating a known asset. This should have been caught by earlier hash checking,
         * but that could have failed, so we're probably in a fall back case, and we can just run the update.
         */
        await self.updateFileMetadata(result.id, bundle: bundle, type: type)
        await self.updateFileInfo(result.id, bundle: bundle, type: type, livePhotoId: livePhotoId)
      } else if metadata != nil {
        /* Immich says this was a duplicate, and it's one of our tracked files (we have a metadata entry),
         * BUT, our ids don't match up. TThis couild indidcate duplicate entries in photos, or an error in the upload
         * process, or corrupt data. Log and continue.
         */
        Self.log.error(
          "Duplicate asset found, but metadata mismatch! This probably indicates duplicate Photos entries: Resolve duplicates in Photos and re-run full sync.",
          stage: .uploadAsset,
          context: Self.errorContext(
            (.immichId, result.id),
            (.localIdentifier, bundle.asset.localIdentifier),
            (.cloudIdentifier, bundle.cloudIdentifier),
            (.assetType, "\(type.rawValue)"),
            (.filename, file.originalFileName)
          )
        )
      } else {
        /* Immich says it's a dupe, but we're not tracking it (no metadata entry). This file was probably udpated by
         * another process. Eventually we can adopt these assets, but for now just log and return.
         */
        // TODO: Implement asset adoption.
        Self.log.warning(
          "Duplicate asset found, but no managed metadata entry! Assuming this asset uploaded by something else. Skipping.",
          stage: .uploadAsset,
          context: Self.errorContext(
            (.immichId, result.id),
            (.localIdentifier, bundle.asset.localIdentifier),
            (.cloudIdentifier, bundle.cloudIdentifier),
            (.assetType, "\(type.rawValue)"),
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
    let metadata = try [
      "phAssetCloudIdentifier": bundle.cloudIdentifier,
      "phAssetLocalIdentifier": bundle.asset.localIdentifier,
      "burstIdentifier": bundle.asset.burstIdentifier,
      "resourceType": type.rawValue,
      "originalFilename": bundle.resources[type]?.originalFilename,
    ].mapValues { try OpenAPIValueContainer(unvalidatedValue: $0) }
    return Components.Schemas.AssetMetadataUpsertItemDto(
      key: IMMICH_DEVICE_ID, value: .init(additionalProperties: metadata))
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
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, "\(type.rawValue)"),
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
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, "\(type.rawValue)"),
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
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, "\(type.rawValue)"),
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
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, "\(type.rawValue)"),
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
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, "\(type.rawValue)"),
          (.filename, bundle.resources[type]?.originalFilename)
        ),
        cause: error
      )
    }
  }

  func copyAsset(
    _ file: ResourceFile, type: AssetType, bundle: AssetBundle, livePhotoId: String?
  ) async -> String? {
    let oldAsset: Components.Schemas.AssetResponseDto?
    do {
      oldAsset = try await assetCache.resolve(localIdentifier: bundle.asset.localIdentifier, type: type)
    } catch {
      Self.log.error(
        "During copy asset, error fetching old asset by local identifier",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.localIdentifier, bundle.asset.localIdentifier),
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, type.rawValue),
          (.filename, file.originalFileName)
        ),
        cause: error
      )
      return nil
    }
    guard let oldAsset else {
      Self.log.error(
        "During copy asset, unexpected result, fetching old asset by local identifier returned nil.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.localIdentifier, bundle.asset.localIdentifier),
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, type.rawValue),
          (.filename, file.originalFileName)
        )
      )
      return nil
    }

    // Upload the new asset.
    let newId = await uploadNewFile(file, type: type, bundle: bundle, livePhotoId: livePhotoId)
    guard let newId else {
      Self.log.error(
        "During copy asset, asset upload failed.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.localIdentifier, bundle.asset.localIdentifier),
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, type.rawValue),
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
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, type.rawValue),
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
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, type.rawValue),
          (.filename, file.originalFileName)
        )
      )
    }
    return newId
  }

  func syncAssetResource(
    hashCheck: Components.Schemas.AssetBulkUploadCheckResult?, knownAsset: Bool, bundle: AssetBundle, type: AssetType,
    resourceFile: ResourceFile, livePhotoId: String?
  ) async -> String? {
    var immichAssetId: String? = nil

    if hashCheck == nil || (hashCheck!.action == .accept && !knownAsset) {
      // Hash check is good (or missing), and we don't know about the asset already
      // So this is a net-new file, and we can cleanly upload it.
      immichAssetId = await self.uploadNewFile(
        resourceFile,
        type: type,
        bundle: bundle,
        livePhotoId: livePhotoId
      )
    } else if hashCheck!.action == .accept && knownAsset {
      // Immich thinks it's a new file, but we know about the asset id already.
      // It's possible the underlying asset changed somehow. This is _odd_, but handlable.
      // Perform a copy operation.
      immichAssetId = await self.copyAsset(
        resourceFile,
        type: type,
        bundle: bundle,
        livePhotoId: livePhotoId
      )
    } else if hashCheck!.action == .reject && hashCheck!.reason == .duplicate {
      // Immich says it has the file, and the identifier matches, so this is just a metadata update.
      guard let id = hashCheck?.assetId else {
        Self.log.error(
          "During Asset Sync: Known duplicate found, attempted to update asset info, but could not resolve ImmichId",
          stage: .uploadAsset,
          context: Self.errorContext(
            (.localIdentifier, bundle.asset.localIdentifier),
            (.cloudIdentifier, bundle.cloudIdentifier),
            (.assetType, type.rawValue),
            (.filename, resourceFile.originalFileName)
          )
        )
        return nil
      }
      await self.updateFileInfo(id, bundle: bundle, type: type, livePhotoId: livePhotoId)
      immichAssetId = id
    } else {
      Self.log.warning(
        "During Asset Sync: Immich rejected upload with unknown reason.",
        stage: .uploadAsset,
        context: Self.errorContext(
          (.immichId, hashCheck?.assetId),
          (.localIdentifier, bundle.asset.localIdentifier),
          (.cloudIdentifier, bundle.cloudIdentifier),
          (.assetType, type.rawValue),
          (.filename, resourceFile.originalFileName)
        )
      )
    }

    return immichAssetId
  }

  func syncAssetBundle(bundle: AssetBundle, files: [AssetType: ResourceFile]) async -> [String] {
    let bulkUploadCheckItems: [Components.Schemas.AssetBulkUploadCheckItem] = files.map { resourceItem in
      Components.Schemas.AssetBulkUploadCheckItem(
        checksum: resourceItem.value.hash,
        id: bundle.getAssetIdentifier(for: resourceItem.key)
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
      let assetIdentifier = bundle.getAssetIdentifier(for: type)
      let hashCheck = hashes[assetIdentifier]
      let immichAssetId: String? = await syncAssetResource(
        hashCheck: hashCheck,
        knownAsset: await assetCache.isKnownIdentifier(assetIdentifier: assetIdentifier),
        bundle: bundle,
        type: type,
        resourceFile: resourceFile,
        livePhotoId: livePhotoId
      )

      guard let immichAssetId else {
        continue
      }

      // We've finished syncing the file (either an upload, update, or copy/delete).
      resultImmichIds.append(immichAssetId)
      // Add our id to our asset cache
      await assetCache.add(immichId: immichAssetId, bundle: bundle, type: type)
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

  func buildCreateDto(file: ResourceFile, type: AssetType, assetBundle bundle: AssetBundle, livePhotoId: String?)
    throws
    -> [Components.Schemas.AssetMediaCreateDto]
  {
    var data: [Components.Schemas.AssetMediaCreateDto] = []
    // Asset File Data, streamed in chunks with an AsyncStream
    do {
      let size = try fs.fileSize(at: file.url)
      let body = OpenAPIRuntime.HTTPBody(
        FileByteSequence(url: file.url),
        length: .known(size),
        iterationBehavior: .multiple)
      data.append(
        .assetData(.init(payload: .init(body: body), filename: file.originalFileName)))
    } catch {
      throw error
    }
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

    var immichIds: [String] = []
    // When an asset is deleted from Photos, we only get the localIdentifier, and can't lookup data about it.
    // So we just lookup any possible assets based on the identifier.
    for localIdentifier in assetIds {
      for type in AssetType.allCases {
        guard let immichId = await assetCache.cachedImmichId(localIdentifier: localIdentifier, type: type) else {
          Self.log.info(
            "No asset found to delete.",
            stage: .deleteAsset,
            context: Self.errorContext(
              (.localIdentifier, localIdentifier),
              (.assetType, type.rawValue)
            )
          )
          continue
        }
        immichIds.append(immichId)
      }
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

  func pruneOrphanAssets(bundles: [AssetBundle]) async {
    guard config.assets.delete else {
      Self.log.progress("Asset deletion is disabled. Skipping.")
      return
    }

    // Reuse the managed set already loaded by `prefetchManagedMetadata()` (this method is
    // only called when that prefetch succeeded), avoiding a second full enumeration.
    let orphanIds = await assetCache.orphanImmichIds(expectedAssetIds: expectedAssetIdentifiers(bundles))

    guard !orphanIds.isEmpty else {
      Self.log.progress("No orphan assets to prune.")
      return
    }

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
    for localidentifier in keyword.assetIds {
      do {
        if let ids = try await resolvePrimaryStackedIds(
          localIdentifier: localidentifier,
          primaryOnly: config.tags.stackPrimaryOnly)
        {
          resolvedIds.formUnion(ids)
        } else {
          Self.log.warning(
            "Unable to resolve asset for tagging. Tagging may be incomplete.",
            stage: .syncTag,
            context: Self.errorContext(
              (.localIdentifier, localidentifier),
              (.tagId, tagId),
              (.tagName, tagValue)
            )
          )
        }
      } catch {
        Self.log.warning(
          "Error resolving asset for tagging. Tagging may be incomplete.",
          stage: .syncTag,
          context: Self.errorContext(
            (.localIdentifier, localidentifier),
            (.tagId, tagId),
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
    // Deletion must retain every tag whose keyword still exists in Photos — not only those
    // whose assets changed this run. In a delta, buildKeywordMap yields empty assetIds for
    // unchanged keywords and drops them; deleting on that basis would wipe tags whose photos
    // simply weren't touched. `keywords` always holds the full keyword list, so derive the
    // retain set from all of them.
    let retainedTagValues = Set(keywords.map { "\(tagPrefix)\($0.keyword)" })
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
        .filter({ shouldDeleteTag(tagValue: $0, desiredTagValues: retainedTagValues) })
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
    } else {
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

          // Resolve the keyword local identifiers into Immich ids, and ensure we're referencing the primary id for any stack
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
              Components.Schemas.MetadataSearchDto(tagIds: [tagId]))
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

  private func resolvePrimaryStackedIds(localIdentifier: String, primaryOnly: Bool) async throws -> [String]? {
    guard let asset = try await assetCache.resolve(localIdentifier: localIdentifier, type: AssetType.original) else { return nil }
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
    for localIdentifier in album.assetIds {
      do {
        if let resolved = try await resolvePrimaryStackedIds(
          localIdentifier: localIdentifier,
          primaryOnly: config.albums.stackPrimaryOnly)
        {
          idsToAdd.append(contentsOf: resolved)
        } else {
          Self.log.warning(
            "Unable to find Immich asset for localIdentifier",
            stage: .createAlbum,
            context: Self.errorContext(
              (.localIdentifier, localIdentifier),
              (.albumLocalidentifier, album.localIdentifier),
              (.albumName, albumName)
            )
          )
        }
      } catch {
        Self.log.error(
          "Error fetching Immich asset for localIdentifier.",
          stage: .createAlbum,
          context: Self.errorContext(
            (.localIdentifier, localIdentifier),
            (.albumLocalidentifier, album.localIdentifier),
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
          (.albumLocalidentifier, album.localIdentifier),
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
      } catch {
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
    }
    // Be sure we're not JUST changing the album name
    guard !photosAlbum.nameChangeOnly else {
      Self.log.progress("Updated Album Name: \(albumName)")
      return
    }

    // Resolve our localIdentifiers into Immich Asset Ids.
    let immichIdsToAdd = await withTaskGroup(of: [String].self) { group in
      for localIdentifier in photosAlbum.assetIds {
        group.addTask {
          do {
            if let resolved = try await self.resolvePrimaryStackedIds(
              localIdentifier: localIdentifier, primaryOnly: self.config.albums.stackPrimaryOnly)
            {
              return resolved
            } else {
              Self.log.warning(
                "Unable to find Immich asset for localIdentifier",
                stage: .syncAlbum,
                context: Self.errorContext(
                  (.localIdentifier, localIdentifier),
                  (.albumId, immichAlbum.id),
                  (.albumName, immichAlbum.albumName)
                )
              )
            }
          } catch {
            Self.log.error(
              "Error fetching Immich asset for localIdentifier.",
              stage: .syncAlbum,
              context: Self.errorContext(
                (.localIdentifier, localIdentifier),
                (.albumId, immichAlbum.id),
                (.albumName, immichAlbum.albumName)
              ),
              cause: error
            )
          }
          return []
        }
      }
      return await group.reduce(into: [String]()) { $0.append(contentsOf: $1) }
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
            (.albumName, immichAlbum.albumName),
            (.albumLocalidentifier, photosAlbum.localIdentifier)
          ),
          cause: error
        )
      }
    }

    // Check for Assets to Remove
    let desiredAssetIds = Set(photosAlbum.assetIds)
    var immichIdsToRemove: [String] = []

    // First load the album's assets.
    let albumAssets: [Components.Schemas.AssetResponseDto]?
    do {
      albumAssets = try await client.searchByAlbum(immichAlbum.id)
    } catch {
      albumAssets = nil
      Self.log.warning(
        "Error fetching album assets. Skipping removing assets from album.",
        stage: .syncAlbum,
        context: Self.errorContext(
          (.albumId, immichAlbum.id),
          (.albumName, immichAlbum.albumName),
          (.albumLocalidentifier, photosAlbum.localIdentifier)
        )
      )
    }

    if let albumAssets {
      // Find assets to remove from the album, using the prefetched managed metadata.
      // A cache miss means the asset is not managed by us, so we never remove it.
      for asset in albumAssets {
        guard let metadata = await assetCache.metadata(forImmichId: asset.id),
          let localId = metadata.phAssetLocalIdentifier,
          !desiredAssetIds.contains(localId)
        else { continue }
        immichIdsToRemove.append(asset.id)
      }
    }

    // Then remove them
    if !immichIdsToRemove.isEmpty {
      do {
        let result = try await self.client.removeAssetsFromAlbum(immichAlbum.id, assetIds: immichIdsToRemove)
        numAssetsRemoved = result.filter(\.success).count
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
      immichAlbums.compactMap { album -> (String, Components.Schemas.AlbumResponseDto)? in
        guard let marker = client.extractAlbumTagValue(album.description) else { return nil }
        return (marker, album)
      }
    ) { existing, duplicate in
      Self.log.warning(
        "syncAlbums: duplicate album marker; keeping album \(existing.id), ignoring \(duplicate.id)",
        stage: .syncAlbum
      )
      return existing
    }

    await withDiscardingTaskGroup { group in
      for album in photosAlbums {
        group.addTask {
          if let immichAlbum = immichAlbumMap[album.localIdentifier] {
            await self.syncExistingAlbum(photosAlbum: album, immichAlbum: immichAlbum)
          } else {
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
