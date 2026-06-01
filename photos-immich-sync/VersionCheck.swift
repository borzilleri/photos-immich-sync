import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

private let GITHUB_RELEASES_LATEST_URL =
  "https://api.github.com/repos/borzilleri/photos-immich-sync/releases/latest"
private let UPDATE_CHECK_TIMEOUT: TimeAmount = .seconds(5)
private let UPDATE_CHECK_MAX_BODY = 256 * 1024

struct SemanticVersion: Comparable {
  let major: Int
  let minor: Int
  let patch: Int

  init?(parsing raw: String) {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.first == "v" || s.first == "V" { s.removeFirst() }
    if let i = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<i]) }
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return nil }
    var nums = [0, 0, 0]
    for (i, p) in parts.enumerated() {
      guard let n = Int(p), n >= 0 else { return nil }
      nums[i] = n
    }
    (major, minor, patch) = (nums[0], nums[1], nums[2])
  }

  static func < (l: SemanticVersion, r: SemanticVersion) -> Bool {
    (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
  }
}

private struct GitHubRelease: Decodable {
  let tagName: String
  let htmlUrl: String
  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlUrl = "html_url"
  }
}

enum VersionCheck {
  static func notifyIfUpdateAvailable(currentVersion: String, log: CategoryLog) async {
    guard let current = SemanticVersion(parsing: currentVersion) else {
      log.debug("Update check skipped: '\(currentVersion)' is not a semantic version.")
      return
    }
    do {
      var request = HTTPClientRequest(url: GITHUB_RELEASES_LATEST_URL)
      // The GitHub API requires a User-Agent header; without it the request is rejected.
      request.headers.add(name: "User-Agent", value: "\(APP_NAME)/\(currentVersion)")
      request.headers.add(name: "Accept", value: "application/vnd.github+json")

      let response = try await HTTPClient.shared.execute(
        request, deadline: .now() + UPDATE_CHECK_TIMEOUT)
      guard response.status == .ok else {
        log.debug("Update check skipped: GitHub returned HTTP \(response.status.code).")
        return
      }
      let buffer = try await response.body.collect(upTo: UPDATE_CHECK_MAX_BODY)
      let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(buffer.readableBytesView))

      guard let latest = SemanticVersion(parsing: release.tagName) else {
        log.debug("Update check skipped: release tag '\(release.tagName)' is not semver.")
        return
      }
      if latest > current {
        log.progress(
          "A new version of \(APP_NAME) is available: \(release.tagName) "
            + "(you have \(currentVersion)).\nDownload: \(release.htmlUrl)")
      }
    } catch {
      log.debug("Update check failed (ignored): \(error)")
    }
  }
}
