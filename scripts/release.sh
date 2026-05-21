#!/bin/bash
# Build, sign, package, and notarize a distributable .pkg of photos-immich-sync.
#
# This script is intentionally idempotent and safe to run repeatedly. It is
# designed to work both for local devs (with `xcrun notarytool store-credentials`)
# and for CI runners (with App Store Connect API key env vars). See the
# Notary auth section below.
#
# SECURITY-REVIEW: shells out to xcodebuild/codesign/pkgbuild/notarytool/stapler
# with values that are either build-machine local (paths, version strings derived
# from `git describe`) or come from operator-supplied env vars. No external/user
# input is interpolated into shell commands without quoting.

set -euo pipefail

# -----------------------------------------------------------------------------
# Config (env-var overridable)
# -----------------------------------------------------------------------------

: "${DEVELOPER_ID_APP:=Developer ID Application: Jonathan Borzilleri (7VW63UWXDW)}"
: "${DEVELOPER_ID_INSTALLER:=Developer ID Installer: Jonathan Borzilleri (7VW63UWXDW)}"
: "${NOTARY_PROFILE:=AC_NOTARY}"

: "${OUTPUT_DIR:=dist}"
: "${SKIP_NOTARIZE:=0}"
: "${ALLOW_DIRTY:=1}"

# `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are derived from git below
# unless explicitly set in the env.

PROJECT="photos-immich-sync.xcodeproj"
SCHEME="Release Build"
CONFIGURATION="Release"
TARGET_NAME="photos-immich-sync"
BUNDLE_ID="io.rampant.photos-immich-sync"
INSTALL_PREFIX="/usr/local/bin"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build/release"
ARCHIVE_PATH="$BUILD_DIR/$TARGET_NAME.xcarchive"
STAGING="$BUILD_DIR/staging"
DERIVED_DATA="$BUILD_DIR/DerivedData"

OUTPUT_DIR="$REPO_ROOT/$OUTPUT_DIR"

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""; C_BOLD=""
fi

step() { printf "\n%s==>%s %s%s%s\n" "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf "%s[err]%s  %s\n"  "$C_RED"    "$C_RESET" "$*" >&2; }
ok()   { printf "%s[ok]%s   %s\n"  "$C_GREEN"  "$C_RESET" "$*"; }

die() { err "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Version derivation from git
# -----------------------------------------------------------------------------

derive_versions() {
  local raw
  raw="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)"
  RAW_DESCRIBE="$raw"

  if [[ -z "${MARKETING_VERSION:-}" ]]; then
    # Strip leading `v`, then take the part before the first `-`.
    local cleaned="${raw#v}"
    cleaned="${cleaned%%-*}"
    if [[ "$cleaned" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
      MARKETING_VERSION="$cleaned"
    else
      warn "Could not derive a semver MARKETING_VERSION from \`git describe\` output \"$raw\"; falling back to 0.0.0."
      MARKETING_VERSION="0.0.0"
    fi
  fi

  if [[ -z "${CURRENT_PROJECT_VERSION:-}" ]]; then
    local latest_tag commits
    latest_tag="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
    if [[ -n "$latest_tag" ]]; then
      commits="$(git -C "$REPO_ROOT" rev-list --count "${latest_tag}..HEAD" 2>/dev/null || echo 0)"
      CURRENT_PROJECT_VERSION="${MARKETING_VERSION}.${commits}"
    else
      commits="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
      CURRENT_PROJECT_VERSION="0.0.0.${commits}"
    fi
  fi

  [[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || \
    die "MARKETING_VERSION '$MARKETING_VERSION' must match ^[0-9]+(\\.[0-9]+){0,2}\$"
  [[ "$CURRENT_PROJECT_VERSION" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] || \
    die "CURRENT_PROJECT_VERSION '$CURRENT_PROJECT_VERSION' must match ^[0-9]+(\\.[0-9]+){0,3}\$"
}

# -----------------------------------------------------------------------------
# Notary auth resolution
#
# Two supported modes; the script auto-selects based on env vars. API-key mode
# is preferred when both are configured, so CI never accidentally falls back
# to a stale local keychain profile.
#
# - API-key mode (CI-friendly):
#     NOTARY_KEY_PATH    Filesystem path to the AuthKey_<KEYID>.p8 private key
#     NOTARY_KEY_ID      10-character Key ID from App Store Connect
#     NOTARY_ISSUER_ID   Issuer UUID from App Store Connect
#
# - Keychain-profile mode (local-friendly):
#     NOTARY_PROFILE     Defaults to AC_NOTARY; created via
#                        `xcrun notarytool store-credentials`.
# -----------------------------------------------------------------------------

resolve_notary_auth() {
  NOTARY_AUTH_ARGS=()
  NOTARY_AUTH_MODE=""

  if [[ -n "${NOTARY_KEY_PATH:-}" || -n "${NOTARY_KEY_ID:-}" || -n "${NOTARY_ISSUER_ID:-}" ]]; then
    if [[ -z "${NOTARY_KEY_PATH:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
      die "API-key notary auth requires all three of NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID."
    fi
    [[ -r "$NOTARY_KEY_PATH" ]] || die "NOTARY_KEY_PATH is not a readable file: $NOTARY_KEY_PATH"
    NOTARY_AUTH_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    NOTARY_AUTH_MODE="api-key (key-id=$NOTARY_KEY_ID)"
    return 0
  fi

  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    NOTARY_AUTH_MODE="keychain-profile ($NOTARY_PROFILE)"
    return 0
  fi

  cat >&2 <<EOF
${C_RED}[err]${C_RESET}   No notarization credentials available.

Configure ONE of the following before re-running, or set SKIP_NOTARIZE=1 to
build an unnotarized pkg for local testing.

  Local dev (one-time setup):
    xcrun notarytool store-credentials AC_NOTARY \\
      --apple-id you@example.com \\
      --team-id 7VW63UWXDW \\
      --password APP_SPECIFIC_PASSWORD

  CI / headless (App Store Connect API key):
    Generate a key at App Store Connect -> Users and Access ->
    Integrations -> App Store Connect API. Then export:
      NOTARY_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
      NOTARY_KEY_ID=XXXXXXXXXX
      NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000
EOF
  return 1
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

preflight() {
  step "Preflight checks"

  command -v xcodebuild  >/dev/null || die "xcodebuild not found"
  command -v xcrun       >/dev/null || die "xcrun not found"
  command -v pkgbuild    >/dev/null || die "pkgbuild not found"
  command -v codesign    >/dev/null || die "codesign not found"
  command -v jq          >/dev/null || die "jq not found (install via \`brew install jq\`)"
  command -v plutil      >/dev/null || die "plutil not found"
  command -v lipo        >/dev/null || die "lipo not found"
  command -v otool       >/dev/null || die "otool not found"

  if ! security find-identity -v -p codesigning 2>/dev/null | grep -F -q "$DEVELOPER_ID_APP"; then
    die "Code-signing identity not in keychain: $DEVELOPER_ID_APP"
  fi
  ok "Found Application identity: $DEVELOPER_ID_APP"

  if ! security find-identity -v 2>/dev/null | grep -F -q "$DEVELOPER_ID_INSTALLER"; then
    die "Installer identity not in keychain: $DEVELOPER_ID_INSTALLER"
  fi
  ok "Found Installer identity:   $DEVELOPER_ID_INSTALLER"

  if [[ "$SKIP_NOTARIZE" != "1" ]]; then
    resolve_notary_auth || exit 1
    ok "Notary auth: $NOTARY_AUTH_MODE"
  else
    warn "SKIP_NOTARIZE=1; the resulting pkg will not be notarized or stapled."
  fi

  if ! git -C "$REPO_ROOT" diff --quiet HEAD -- 2>/dev/null \
      || [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    if [[ "$ALLOW_DIRTY" == "1" ]]; then
      warn "Working tree is dirty. The pkg's MARKETING_VERSION will still use the clean tag,"
      warn "but APP_VERSION inside the binary will carry a -dirty suffix for diagnostics."
    else
      die "Working tree is dirty and ALLOW_DIRTY=0. Commit or stash, or set ALLOW_DIRTY=1."
    fi
  fi

  derive_versions
  info "RAW_DESCRIBE             = $RAW_DESCRIBE"
  info "MARKETING_VERSION        = $MARKETING_VERSION"
  info "CURRENT_PROJECT_VERSION  = $CURRENT_PROJECT_VERSION"
}

# -----------------------------------------------------------------------------
# Archive
# -----------------------------------------------------------------------------

run_archive() {
  step "xcodebuild archive ($CONFIGURATION, universal, hardened, Developer ID)"

  rm -rf "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"

  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APP" \
    "DEVELOPMENT_TEAM=7VW63UWXDW" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION"

  [[ -d "$ARCHIVE_PATH" ]] || die "archive did not produce $ARCHIVE_PATH"
  ok "Archive: $ARCHIVE_PATH"
}

# -----------------------------------------------------------------------------
# Extract + verify
# -----------------------------------------------------------------------------

extract_binary() {
  step "Extract binary from archive"

  ARCHIVED_BIN="$(find "$ARCHIVE_PATH/Products" -type f -name "$TARGET_NAME" -perm -u+x | head -n1)"
  [[ -n "$ARCHIVED_BIN" && -f "$ARCHIVED_BIN" ]] || \
    die "Could not locate built $TARGET_NAME inside $ARCHIVE_PATH/Products"

  rm -rf "$STAGING"
  mkdir -p "$STAGING$INSTALL_PREFIX"
  cp "$ARCHIVED_BIN" "$STAGING$INSTALL_PREFIX/$TARGET_NAME"
  chmod 755 "$STAGING$INSTALL_PREFIX/$TARGET_NAME"
  STAGED_BIN="$STAGING$INSTALL_PREFIX/$TARGET_NAME"
  ok "Staged: $STAGED_BIN"
}

verify_binary() {
  step "Verify signed binary"

  codesign --verify --strict --verbose=4 "$STAGED_BIN"

  local sig_summary
  sig_summary="$(codesign -dvv "$STAGED_BIN" 2>&1)"
  printf '%s\n' "$sig_summary" | grep -E 'Authority|TeamIdentifier|flags' || true

  printf '%s\n' "$sig_summary" | grep -q "Authority=$DEVELOPER_ID_APP" \
    || die "Binary not signed by expected Developer ID Application identity"
  printf '%s\n' "$sig_summary" | grep -q 'TeamIdentifier=7VW63UWXDW' \
    || die "Binary TeamIdentifier mismatch (expected 7VW63UWXDW)"
  printf '%s\n' "$sig_summary" | grep -Eq 'flags=.*runtime' \
    || die "Binary is not signed with the hardened runtime"

  local entitlements_xml
  entitlements_xml="$(codesign -d --entitlements - --xml "$STAGED_BIN" 2>/dev/null || true)"
  if [[ -n "$entitlements_xml" ]] && \
     printf '%s' "$entitlements_xml" | plutil -extract com.apple.security.get-task-allow raw - >/dev/null 2>&1; then
    die "Binary has com.apple.security.get-task-allow entitlement; notarization will reject it"
  fi
  ok "Entitlements: get-task-allow not present"

  local arch_info
  arch_info="$(lipo -info "$STAGED_BIN")"
  info "$arch_info"
  printf '%s' "$arch_info" | grep -q 'arm64' || die "Binary missing arm64 slice"
  printf '%s' "$arch_info" | grep -q 'x86_64' || die "Binary missing x86_64 slice"
  ok "Universal binary (arm64 + x86_64)"

  step "Verify embedded Info.plist"
  local plist
  plist="$(otool -P "$STAGED_BIN" 2>/dev/null | sed -n '/<?xml/,/<\/plist>/p')"
  [[ -n "$plist" ]] || die "Could not read embedded Info.plist via \`otool -P\`"

  local short_version bundle_version usage
  short_version="$(printf '%s' "$plist" | plutil -extract CFBundleShortVersionString raw - 2>/dev/null || true)"
  bundle_version="$(printf '%s' "$plist" | plutil -extract CFBundleVersion raw - 2>/dev/null || true)"
  usage="$(printf '%s' "$plist" | plutil -extract NSPhotoLibraryUsageDescription raw - 2>/dev/null || true)"

  [[ "$short_version" == "$MARKETING_VERSION" ]] \
    || die "CFBundleShortVersionString in embedded Info.plist is '$short_version', expected '$MARKETING_VERSION'"
  [[ "$bundle_version" == "$CURRENT_PROJECT_VERSION" ]] \
    || die "CFBundleVersion in embedded Info.plist is '$bundle_version', expected '$CURRENT_PROJECT_VERSION'"
  [[ -n "$usage" ]] \
    || die "NSPhotoLibraryUsageDescription missing from embedded Info.plist; Photos auth will fail at runtime"
  ok "CFBundleShortVersionString = $short_version"
  ok "CFBundleVersion            = $bundle_version"
  ok "NSPhotoLibraryUsageDescription present"
}

# -----------------------------------------------------------------------------
# Build pkg
# -----------------------------------------------------------------------------

build_pkg() {
  step "Build signed component pkg"

  mkdir -p "$OUTPUT_DIR"
  PKG_PATH="$OUTPUT_DIR/$TARGET_NAME-$MARKETING_VERSION.pkg"
  rm -f "$PKG_PATH"

  pkgbuild \
    --root "$STAGING" \
    --identifier "$BUNDLE_ID" \
    --version "$MARKETING_VERSION" \
    --install-location / \
    --sign "$DEVELOPER_ID_INSTALLER" \
    "$PKG_PATH"

  pkgutil --check-signature "$PKG_PATH" >/dev/null || die "pkgutil --check-signature failed for $PKG_PATH"
  ok "Built: $PKG_PATH"
}

# -----------------------------------------------------------------------------
# Notarize + staple
# -----------------------------------------------------------------------------

notarize_and_staple() {
  if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    warn "SKIP_NOTARIZE=1; skipping notarization and stapling."
    return 0
  fi

  step "Submit to notary service (this can take a few minutes)"

  local submit_json submit_id status
  submit_json="$(xcrun notarytool submit "$PKG_PATH" \
    "${NOTARY_AUTH_ARGS[@]}" \
    --wait \
    --output-format json)"

  submit_id="$(printf '%s' "$submit_json" | jq -r '.id')"
  status="$(printf '%s' "$submit_json" | jq -r '.status')"
  info "Submission id: $submit_id"
  info "Status:        $status"

  if [[ "$status" != "Accepted" ]]; then
    err "Notarization status was \"$status\". Fetching log:"
    xcrun notarytool log "$submit_id" "${NOTARY_AUTH_ARGS[@]}" || true
    die "Notarization did not succeed."
  fi
  ok "Notarization accepted"

  step "Staple ticket to pkg"
  xcrun stapler staple "$PKG_PATH"
  xcrun stapler validate "$PKG_PATH"
  spctl --assess --type install -vv "$PKG_PATH"
  ok "Staple verified; Gatekeeper accepts the pkg"
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

print_summary() {
  step "Release summary"

  local size sha
  size="$(du -h "$PKG_PATH" | awk '{print $1}')"
  sha="$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')"

  printf "\n"
  printf "  %sPackage:%s         %s\n"  "$C_BOLD" "$C_RESET" "$PKG_PATH"
  printf "  %sSize:%s            %s\n"  "$C_BOLD" "$C_RESET" "$size"
  printf "  %sMarketing ver:%s   %s\n"  "$C_BOLD" "$C_RESET" "$MARKETING_VERSION"
  printf "  %sBuild number:%s    %s\n"  "$C_BOLD" "$C_RESET" "$CURRENT_PROJECT_VERSION"
  printf "  %sgit describe:%s    %s\n"  "$C_BOLD" "$C_RESET" "$RAW_DESCRIBE"
  printf "  %sSHA-256:%s         %s\n"  "$C_BOLD" "$C_RESET" "$sha"
  printf "\n"

  if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    warn "Pkg is NOT notarized. Do not distribute. Re-run without SKIP_NOTARIZE=1."
  else
    info "Installs to: $INSTALL_PREFIX/$TARGET_NAME"
    info "End-users can install with: sudo installer -pkg \"$(basename "$PKG_PATH")\" -target /"
  fi
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------

main() {
  preflight
  run_archive
  extract_binary
  verify_binary
  build_pkg
  notarize_and_staple
  print_summary
}

main "$@"
