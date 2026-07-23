import Photos

public enum PhotosAuthorizationError: Error, CustomStringConvertible {
  case fullAccessRequired
  case authorizationRequired
  case notDeterminedAfterRequest
  case unknownStatus(PHAuthorizationStatus)

  public var description: String {
    switch self {
    case .fullAccessRequired:
      return "Photos permission required. Full access is required (limited access not allowed)."
    case .authorizationRequired:
      return "Photos permission required. Use the 'request-auth' subcommand to request authorization."
    case .notDeterminedAfterRequest:
      return "Photos permission could not be determined."
    case .unknownStatus:
      return "Unknown Photos authorization status."
    }
  }
}

public struct PhotosCore {
  private static func validate(
    _ status: PHAuthorizationStatus,
    notDeterminedError: PhotosAuthorizationError?
  ) throws {
    switch status {
    case .authorized:
      return
    case .limited, .denied, .restricted:
      throw PhotosAuthorizationError.fullAccessRequired
    case .notDetermined:
      if let err = notDeterminedError { throw err }
    @unknown default:
      throw PhotosAuthorizationError.unknownStatus(status)
    }
  }

  public static func checkAuthorization(requireAuth: Bool, requestAuth: Bool) throws {
    var current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var notDeterminedError: PhotosAuthorizationError? = requireAuth ? .authorizationRequired : nil

    if requestAuth && current == .notDetermined {
      current = requestAuthorization()
      // We prompted; a still-undetermined result is now a post-request failure.
      notDeterminedError = .notDeterminedAfterRequest
    }

    try validate(current, notDeterminedError: notDeterminedError)
  }

  private static func requestAuthorization() -> PHAuthorizationStatus {
    let sema = DispatchSemaphore(value: 0)
    var result: PHAuthorizationStatus = .notDetermined
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
      result = status
      sema.signal()
    }
    sema.wait()
    return result
  }

  public static func getPersistentChangeToken() -> PHPersistentChangeToken {
    PHPhotoLibrary.shared().currentChangeToken
  }
}
