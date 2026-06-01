import ArgumentParser
import Foundation
import Photos

private struct Services {
  let fileService: FileService
  let exporter: PhotosExporter
  let immichClient: ImmichApiClient
  let immichService: ImmichService
}

struct GlobalOptions: ParsableArguments {
  @Flag(help: "Suppress non-error output.") var quiet: Bool = false
  @Flag(name: .shortAndLong, help: "Increase output verbosity, may be specified multiple times.") var verbose: Int
}

struct SyncOptions: ParsableArguments {
  @Option(help: "Path to configuration file.") var configFile: String = DEFAULT_CONFIG_PATH
  @Flag(help: "Request Photos authorization, allows requesting auth at the same time as an export run.") var requestAuth: Bool = false
}

@main
struct PhotosImmichSync: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: APP_NAME,
    version: APP_VERSION,
    subcommands: [RequestAuth.self, ImmichFull.self, ImmichDelta.self]
  )
}

extension PhotosImmichSync {
  struct RequestAuth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "request-auth",
      abstract: "Request Photos authorization."
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
      Log.configure(verbosity: Verbosity.fromFlags(quiet: global.quiet, verbose: global.verbose))
      let log = Log.forCategory(APP_NAME)
      do {
        try PhotosCore.checkAuthorization(requireAuth: false, requestAuth: true)
        if Log.summary().hasErrors {
          throw ExitCode.failure
        }
      } catch let exit as ExitCode {
        throw exit
      } catch {
        log.error("Fatal: \(error)")
        throw ExitCode.failure
      }
    }
  }

  struct ImmichFull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "immich-full",
      abstract: "Run a full sync to Immich."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var sync: SyncOptions

    func run() async throws {
      try await runSync(global: global, sync: sync) { config, services in
        try await immichFullSync(config: config, services: services)
      }
    }
  }

  struct ImmichDelta: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "immich-delta",
      abstract: "Run a delta sync to Immich."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var sync: SyncOptions

    func run() async throws {
      try await runSync(global: global, sync: sync) { config, services in
        try await immichDeltaSync(config: config, services: services)
      }
    }
  }
}

private func makeSyncStack(config: AppConfig, fileService: FileService) throws -> Services {
  let client = try ImmichApiClient(config.immich.api)
  let downloadLimiter = AsyncSemaphore(
    maxConcurrentTasks: max(1, config.immich.assets.maxConcurrentDownloads))
  let downloader = PhotosDownloader(fileService: fileService, retry: config.photos.download.retryConfig)
  let service = ImmichService(
    client: client,
    config: config.immich,
    fileService: fileService,
    photoDownloader: downloader,
    downloadLimiter: downloadLimiter
  )
  let exporter = PhotosExporter(
    fileService: fileService,
    exportConcurrency: config.photos.export.exportConcurrency
  )
  return Services(fileService: fileService, exporter: exporter, immichClient: client, immichService: service)
}

private func immichFullSync(config: AppConfig, services: Services) async throws -> Bool {
  try await services.immichClient.checkServerVersion()
  try await services.immichClient.validateApiKey(config: config.immich)

  let exportData: FullPhotosExport = await services.exporter.generateFullExport(config: config.photos.export)
  if config.exportOnly {
    return false
  }
  await services.immichService.performFullSync(exportData)
  return true
}

private func immichDeltaSync(config: AppConfig, services: Services) async throws -> Bool {
  let log = Log.forCategory(APP_NAME)
  try await services.immichClient.checkServerVersion()
  try await services.immichClient.validateApiKey(config: config.immich)

  let token: PHPersistentChangeToken?
  do {
    token = try services.fileService.loadChangeToken()
  } catch {
    log.error("Saved Photos change token is unreadable. Please run a full sync to recover.", cause: error)
    return false
  }
  guard let token else {
    log.warning("No saved Photos change token. Please run a full sync first.")
    return false
  }
  guard let changes = await services.exporter.generateDeltaExport(token, config: config.photos.export) else {
    // `fetchChanges` already logged a per-PHPhotosError-code message.
    return false
  }
  if config.exportOnly {
    return false
  }
  await services.immichService.performDeltaSync(changes)
  return true
}

private func runSync(
  global: GlobalOptions,
  sync: SyncOptions,
  perform: (AppConfig, Services) async throws -> Bool
) async throws {
  Log.configure(verbosity: Verbosity.fromFlags(quiet: global.quiet, verbose: global.verbose))
  let log = Log.forCategory(APP_NAME)
  do {
    let config = try AppConfig.load(fromFile: sync.configFile)

    let fileService = try FileService()
    defer { fileService.cleanup() }

    // Snapshot a new persistent change token here, so we don't lose changes that may occur while we export/upload.
    let currentChangeToken = PhotosCore.getPersistentChangeToken()

    try PhotosCore.checkAuthorization(requireAuth: true, requestAuth: sync.requestAuth)
    let services = try makeSyncStack(config: config, fileService: fileService)

    // TODO: Make this more robust, rather than specific to the immich client.
    try await withAsyncCleanup({ await services.immichClient.shutdown() }) {
      let changeTokenCandidate = try await perform(config, services)

      let hasFatalErrors = Log.summary().hasErrors
      if changeTokenCandidate && !hasFatalErrors {
        try fileService.writeChangeToken(currentChangeToken)
      }
      if hasFatalErrors {
        throw ExitCode.failure
      }
    }
  } catch let exit as ExitCode {
    throw exit
  } catch {
    log.error("Fatal: \(error)")
    throw ExitCode.failure
  }
}
