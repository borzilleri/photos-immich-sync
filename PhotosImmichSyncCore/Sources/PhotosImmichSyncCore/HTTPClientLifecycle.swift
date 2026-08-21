import AsyncHTTPClient

/// Construction and teardown shared by the Immich and metadata API clients, which
/// each own the HTTPClient behind their transport.
extension HTTPClient {
  /// Builds an HTTPClient with the timeouts and pool limits from the api config.
  static func make(for config: ImmichApiConfig) -> HTTPClient {
    var httpConfig = HTTPClient.Configuration.singletonConfiguration
    httpConfig.timeout.connect = config.connectTimeout.toTimeAmount()
    let idleTimeout = config.connectionIdleTimeout.map({ $0.toTimeAmount() })
    httpConfig.timeout.read = idleTimeout
    httpConfig.timeout.write = idleTimeout
    httpConfig.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = max(1, config.maxConcurrentRequests)
    return HTTPClient(
      eventLoopGroup: HTTPClient.defaultEventLoopGroup,
      configuration: httpConfig
    )
  }

  /// Best-effort shutdown: failures are logged, never thrown, so teardown can't mask
  /// the run's real error.
  func shutdownQuietly(log: CategoryLog) async {
    do {
      try await shutdown()
    } catch {
      log.debug("HTTPClient shutdown failed: \(error)")
    }
  }
}
