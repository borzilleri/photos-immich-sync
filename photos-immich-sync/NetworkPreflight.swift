import Foundation
import NIOConcurrencyHelpers
import Network

/// Warms up macOS Local Network access before the app issues any HTTP traffic.
///
/// The first connection to a local network address triggers the macOS "Local Network"
/// permission prompt. The connection that triggers the prompt is held by the system and
/// dropped while the prompt is shown, so it times out even if the user clicks "Allow".
///
/// AsyncHTTPClient doesn't provide any insight into this state, it just hangs until the connect
/// timeout. `NWConnection` does expose this, it stays `.preparing`/`.waiting`
/// while the prompt is up, and becomes `.ready` once the user allows access.
/// This lets us block until the user responds, so subsequent HTTP requests succeed.
enum NetworkPreflight {
  fileprivate static let log = Log.forCategory("NetworkPreflight")
  static let defaultTimeout = Duration.seconds(30)

  static func warmUpLocalNetwork(serverURL: String, timeout: Duration = defaultTimeout) async {
    let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let host = url.host, let scheme = url.scheme else {
      // The URL was already validated when constructing the client; nothing to probe.
      return
    }
    let port = url.port ?? (scheme == "https" ? 443 : 80)
    guard let portValue = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: portValue) else {
      return
    }

    log.progress("Checking connectivity to \(host):\(port)\u{2026}")
    let probe = TCPProbe(host: host, port: nwPort)
    defer { probe.cancel() }
    do {
      try await performWithTimeout(of: timeout) {
        try await probe.run()
      }
      log.debug("Network reachable; Local Network access granted.")
    } catch is TimeoutError {
      let seconds = Int(timeout.components.seconds)
      log.warning(
        "Timed out after \(seconds)s waiting for network access to \(host):\(port). "
          + "If macOS prompted for Local Network access, allow it and re-run. Continuing anyway\u{2026}")
    } catch is CancellationError {
      // The surrounding task was cancelled; `run()`'s onCancel already finished the probe.
    } catch {
      log.warning("Network preflight to \(host):\(port) failed; continuing anyway.", cause: error)
    }
  }
}

private final class TCPProbe: @unchecked Sendable {
  private struct State {
    var continuation: CheckedContinuation<Void, Error>?
    var finished = false
    var loggedWaiting = false
  }

  private let connection: NWConnection
  private let queue = DispatchQueue(label: "\(APP_NAME).network-preflight")
  private let state = NIOLockedValueBox(State())

  init(host: String, port: NWEndpoint.Port) {
    connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
  }

  func run() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        let alreadyFinished = state.withLockedValue { s -> Bool in
          if s.finished { return true }
          s.continuation = cont
          return false
        }
        if alreadyFinished {
          cont.resume(throwing: CancellationError())
          return
        }
        connection.stateUpdateHandler = { [weak self] newState in
          guard let self else { return }
          switch newState {
          case .ready:
            self.finish(.success(()))
          case .failed(let error):
            self.finish(.failure(error))
          case .waiting(let error):
            self.logWaitingOnce(error)
          case .cancelled:
            self.finish(.failure(CancellationError()))
          default:
            break
          }
        }
        connection.start(queue: queue)
      }
    } onCancel: {
      finish(.failure(CancellationError()))
    }
  }

  func cancel() {
    finish(.failure(CancellationError()))
  }

  private func finish(_ result: Result<Void, Error>) {
    let cont = state.withLockedValue { s -> CheckedContinuation<Void, Error>? in
      if s.finished { return nil }
      s.finished = true
      defer { s.continuation = nil }
      return s.continuation
    }
    connection.cancel()
    cont?.resume(with: result)
  }

  private func logWaitingOnce(_ error: NWError) {
    let shouldLog = state.withLockedValue { s -> Bool in
      if s.loggedWaiting { return false }
      s.loggedWaiting = true
      return true
    }
    if shouldLog {
      NetworkPreflight.log.progress(
        "Waiting for Local Network access \u{2014} if macOS is prompting, please click \"Allow\". (\(error))")
    }
  }
}
