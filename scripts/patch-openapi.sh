#!/bin/bash
# Refresh and/or patch the vendored Immich OpenAPI spec.
#
# The swift-openapi client is generated from the vendored spec at build time, but
# the upstream spec doesn't match what our supported servers actually send or
# accept. This script applies our local fixes so a refresh can't silently drop them:
#
#   1. AssetMediaCreateDto.metadata is retyped array -> string. Immich reads this
#      multipart field as one JSON-array string; swift-openapi-generator would
#      serialize an array-typed part as one JSON object per part (400 from Immich).
#      ImmichService.buildCreateDto encodes the array itself.
#   2. Any `required` property whose x-immich-history says it was added after
#      IMMICH_MIN_SUPPORTED_VERSION (Common.swift) is made optional, since older
#      supported servers omit it and decoding would fail (e.g.
#      ServerVersionResponseDto.featureLevel, added in v4.0.0).
#
# Patching is idempotent; with no arguments it re-patches the vendored file in place.
# OpenAPISpecTests guards both patches in `swift test`, so a hand refresh that
# skips this script fails CI.
#
# Usage:
#   scripts/patch-openapi.sh                  # re-patch the vendored spec
#   scripts/patch-openapi.sh --ref v3.2.1     # fetch upstream spec at a git ref, then patch
#   scripts/patch-openapi.sh path/or/url.json # patch a local file or URL into place
#
# SECURITY-REVIEW: downloads a JSON spec over HTTPS and transforms it with jq.
# Arguments are only used as a quoted path/URL; nothing is evaluated.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_SRC="${REPO_ROOT}/PhotosImmichSyncCore/Sources/PhotosImmichSyncCore"
SPEC="${CORE_SRC}/openapi.json"
COMMON_SWIFT="${CORE_SRC}/Common.swift"

usage() {
  sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

SOURCE="${SPEC}"
case "${1:-}" in
  -h|--help) usage ;;
  --ref)
    [[ -n "${2:-}" ]] || usage 1
    SOURCE="https://raw.githubusercontent.com/immich-app/immich/${2}/open-api/immich-openapi-specs.json"
    ;;
  "") ;;
  *) SOURCE="$1" ;;
esac

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

# Single source of truth for the minimum server version.
MIN_VERSION="$(sed -nE 's/.*IMMICH_MIN_SUPPORTED_VERSION = SemanticVersion\(major: ([0-9]+), minor: ([0-9]+), patch: ([0-9]+)\).*/\1.\2.\3/p' "${COMMON_SWIFT}")"
[[ -n "${MIN_VERSION}" ]] || { echo "error: IMMICH_MIN_SUPPORTED_VERSION not found in ${COMMON_SWIFT}" >&2; exit 1; }

PATCH='
  def semver: ltrimstr("v") | split(".") | map(tonumber) | (. + [0, 0, 0])[:3];
  def added_after($min):
    (.["x-immich-history"] // [] | map(select(.state == "Added") | .version) | first) as $v
    | $v != null and ($v | semver) > ($min | semver);
  def note: "RE-APPLY THIS PATCH whenever openapi.json is refreshed from Immich (scripts/patch-openapi.sh).";

  # Patch 1: metadata multipart field is a JSON-array string on the wire.
  .components.schemas.AssetMediaCreateDto.properties.metadata |= (
    . // error("AssetMediaCreateDto.metadata not found; upstream schema changed, revisit patch 1")
    | {
        description: ("Asset metadata items, JSON-encoded as an array of AssetMetadataUpsertItemDto. Immich'"'"'s server reads this multipart field as an opaque JSON string and parses it into an array, but the upstream spec describes it as `type: array`, which swift-openapi-generator serializes as one JSON object per part rather than a single JSON-array string. Typed as `string` here so buildCreateDto can encode the array in the exact wire format Immich expects. " + note),
        type: "string"
      })

  # Patch 2: properties newer than the minimum supported server are not required.
  | walk(
      if type == "object" and (.required | type) == "array" and (.properties | type) == "object" then
        . as $o
        | ([$o.required[] | select($o.properties[.] | added_after($min))]) as $newer
        | .required -= $newer
        | reduce $newer[] as $k (.;
            .properties[$k].description |= ((. // "")
              | . + (if . == "" or endswith(".") then "" else "." end)
              + " Removed from `required` locally: newer than the minimum supported server (v" + $min + "), which omits it. " + note
              | ltrimstr(" ")))
      else . end)
'

# Buffer the result so patching the vendored file in place doesn't truncate its input.
# -j omits the trailing newline, matching upstream and keeping diffs minimal.
if [[ "${SOURCE}" =~ ^https?:// ]]; then
  echo "Fetching ${SOURCE}"
  PATCHED="$(curl -fsSL "${SOURCE}" | jq -j --arg min "${MIN_VERSION}" "${PATCH}")"
else
  PATCHED="$(jq -j --arg min "${MIN_VERSION}" "${PATCH}" "${SOURCE}")"
fi
printf '%s' "${PATCHED}" > "${SPEC}"

echo "Patched $(jq -r '.info.version' <<<"${PATCHED}") spec (min supported server v${MIN_VERSION}) -> ${SPEC#"${REPO_ROOT}/"}"
