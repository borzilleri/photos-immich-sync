import Photos
import Testing

@testable import PhotosImmichSyncCore

@Suite struct PhotosAuthValidateTests {
  @Test func authorizedPasses() throws {
    try PhotosCore.validate(.authorized, notDeterminedError: nil)
  }

  @Test(arguments: [PHAuthorizationStatus.limited, .denied, .restricted])
  func nonFullAccessStatusesRequireFullAccess(status: PHAuthorizationStatus) {
    #expect(throws: PhotosAuthorizationError.self) {
      try PhotosCore.validate(status, notDeterminedError: nil)
    }
  }

  @Test func limitedAccessIsExplicitlyRejected() {
    // Limited-library access can't drive a full sync; pinned as fullAccessRequired.
    do {
      try PhotosCore.validate(.limited, notDeterminedError: nil)
      Issue.record("expected fullAccessRequired")
    } catch PhotosAuthorizationError.fullAccessRequired {
      // expected
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test func notDeterminedThrowsTheProvidedErrorOrNothing() throws {
    // With an error configured, .notDetermined surfaces it…
    do {
      try PhotosCore.validate(.notDetermined, notDeterminedError: .authorizationRequired)
      Issue.record("expected authorizationRequired")
    } catch PhotosAuthorizationError.authorizationRequired {
      // expected
    }
    // …and without one, .notDetermined is allowed through (the request-auth flow).
    try PhotosCore.validate(.notDetermined, notDeterminedError: nil)
  }
}
