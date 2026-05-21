import Foundation
import Photos

struct DownloadResult {
  let files: [AssetType: ResourceFile]
}

public struct ResourceFile : Sendable {
  let url: URL
  let assetType: AssetType
  let originalFileName: String
  let hash: String
}

private actor DownloadTracker {
  var urls: [AssetType: ResourceFile] = [:]
  var errors: [(Error, ResourceFile)] = []

  func track(_ error: Error, for file: ResourceFile) {
    errors.append((error, file))
  }
  func track(_ type: AssetType, _ file: ResourceFile) {
    urls[type] = file
  }
}

struct PhotosDownloader {
  private static let log = Log.forCategory("Downloader")
  let fileService: FileService
  let retry: RetryConfig

  func downloadBundle(
    _ bundle: AssetBundle,
    callback: (Result<DownloadResult, Error>) async -> Void
  ) async {
    let result = await downloadAllResources(bundle)
    await callback(result.map({ DownloadResult(files: $0) }))
    switch result {
    case .success(let urlMap):
      await cleanupFiles(Array(urlMap.values))
    case .failure(let error):
      // The original `case .failure` in `ImmichService.processBundle` already
      // records this as `.critical`; emit at `.warning` here so the run summary
      // counts the failure once, not twice.
      Self.log.warning(
        "Error during bundle download; manual cleanup may be necessary.",
        stage: .uploadAsset,
        cause: error
      )
    }
  }

  private func downloadAllResources(_ bundle: AssetBundle) async -> Result<[AssetType: ResourceFile], Error> {
    let tracker = DownloadTracker()
    do {
      var result: [AssetType:ResourceFile] = [:]
      for (assetType, resource) in bundle.resources {
        let file = try await self.downloadSingleResource(resource, type: assetType, asset: bundle.asset)
        await tracker.track(assetType, file)
        result[assetType] = file
      }
      return .success(result)
    } catch {
      await cleanupFiles(Array(await tracker.urls.values))
      return .failure(error)
    }
  }

  private func downloadSingleResource(
    _ resource: PHAssetResource, type: AssetType, asset: PHAsset
  ) async throws -> ResourceFile {
    let safeName = FileService.sanitizeFilename(resource.originalFilename)
    let tempFileName = "\(UUID().uuidString)_\(type.rawValue)_\(safeName)"
    let destination = fileService.workDir.appendingPathComponent(tempFileName, isDirectory: false)

    if type == .edited {
      let (hash, resultURL) = try await fileService.downloadAndHashImage(
        asset, to: destination, withRetry: retry
      )
      let filename =
        "\((resource.originalFilename as NSString).deletingPathExtension)_edited.\(resultURL.pathExtension)"
      return ResourceFile(
        url: resultURL,
        assetType: type,
        originalFileName: filename,
        hash: hash
      )
    } else {
      let hash = try await fileService.downloadAndHashResource(
        resource, to: destination, withRetry: retry
      )
      return ResourceFile(
        url: destination,
        assetType: type,
        originalFileName: resource.originalFilename,
        hash: hash,
      )
    }
  }

  private func cleanupFiles(_ files: [ResourceFile]) async {
    for file in files {
      try? FileManager.default.removeItem(at: file.url)
    }
  }
}
