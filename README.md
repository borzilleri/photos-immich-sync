# Photos-Immich-Sync

`photos-immich-sync` is a macOS command-line tool that syncs your Apple Photos
library to an [Immich](https://immich.app) server. It provides a full sync
mode and an incremental delta sync mode.

## Installation

1. Download the latest signed `.pkg` from the GitHub Releases page.
2. Install it:

```bash
sudo installer -pkg photos-immich-sync-<version>.pkg -target /
```

The binary is installed to `/usr/local/bin/photos-immich-sync`.

## Configuration

1. Copy [config_template.yaml](./config_template.yaml) to the default location:

```bash
mkdir -p ~/.config/photos-immich-sync
cp config_template.yaml ~/.config/photos-immich-sync/photos-immich-sync.yaml
```

2. Edit the file and set `immich.api.url` and `immich.api.key`. These are the
    only required keys; see the template for documentation of each option.

To use a different config path, pass `--config-file /path/to/your.yaml` to
any subcommand.

## Running the app

### Requesting Photos Access

`photos-immich-sync` requires approval to access your photos library. You
should run this request-auth command first to grant library access.

```bash
photos-immich-sync request-auth
```

If your Immich server is on your local network, macOS will also prompt for 
"Local Network" access. `request-auth` surfaces and waits on that prompt
as well, so both permissions can be granted up front.

### Full Sync

```bash
photos-immich-sync immich-full [--config-file PATH] [--request-auth]
```

Syncs all assets in your Photos Library with Immich, and deletes managed assets found
remotely that do not exist locally. This operation attempts to intelligently detect assets 
and files already present in Immich and avoids duplicate work where possible. It is
safe to run a full sync repeatedly.

On a successful run, a PhotoKit `PHPersistentChangeToken` is persisted to
`~/Library/Application Support/photos-immich-sync/photos_change_token.data`
so that subsequent delta syncs can start from this snapshot.

A full sync is required before a delta sync can run.

### Delta Sync

```bash
photos-immich-sync immich-delta [--config-file PATH] [--request-auth]
```

Uses a persistant change token to read the changes to your Photos Library since the 
last successful full or delta sync, and then syncs the changes to Immich.

This requires a PhotoKit persistent change token to detect delta changes to your
Photos library. As such, it requires at least one full sync having been successfully run 
first, to generate the change token.

Critical failures during any run will not persist a new change token, so
failures during a delta sync will be retried on the next sync.

## Functionality

### Assets from Other Sources

Assets uploaded by this app are tagged with a deviceId (`io.rampant.photos-immich-sync`), 
only assets with this deviceId are managed by sync operations. You can manually
add other assets to Immich, or sync assets from other sources, and they will
remain untouched.

Similarly, Albums and Tags (assuming parentTag is set, see below) synced by
this app will be tracked and managed. Albums and Tags created manually (or by
another process) will not be touched.

### Photo Title & Caption

Title & Caption export is disabled by default (enable with `photos.export.includeTitleCaption`).

**IMPORTANT:** Photo titles and captions are not exposed by the PhotoKit API.
In order to read and export them, `photos-immich-sync` inspects your library's internal 
SQLite database. This is unsupported by Apple and may break with future 
updates to macOS/Photos. If the database schema changes, the app should handle
and log the failure, and skip updating these fields (data on existing assets
will not be touched).

Currently this feature only works for Photos libraries in the system default location: 
`~/Pictures/Photos Library.photoslibrary`

### Album Syncing

Album syncing is enabled by default (configure with `immich.albums.enabled`).

Only Regular Photos albums are synced; Smart Albums and shared albums are
skipped.

Because Immich does not support nested albums, the Photos folder hierarchy
is flattened into the an album name using `immich.albums.pathSeparator`
(default ` / `). So an album named "Iceland 2024" in the folder "Trips", 
becomes an Immich album named `Trips / Iceland 2024`.

To track renames and deletions reliably, the Photos album's
`localIdentifier` is embedded into the Immich album's description with the
marker:

```
#photos-immich-sync:<localIdentifier>#
```

If this marker is removed or changed, the sync process will not be able
to track this album for renames or deletes. It may create a duplicate album,
or fail to delete the album later.

A full sync will delete any managed Immich album (i.e. one carrying that
marker) without a matching local album. Albums without the marker are
never touched.

`immich.albums.stackPrimaryOnly` (default `true`) controls whether only the
primary asset of a stack is added to an album, or every asset in the stack, 
since Immich does not display stacks in the Album view (each asset would be
displayed independently).

### Keyword/Tag Syncing

Photos Keyword syncing (as Immich Tags) is disabled by default (configure
with `immich.tags.enabled`)

**IMPORTANT:** Photos Keywords are not exposed by the PhotoKit API. In order
to read and export them, `photos-immich-sync` inspects your library's internal
SQLite database. This is unsupported by Apple and may break with future 
updates to macOS/Photos. If the database schema changes, the app should handle
and log the failure, and simply not perform tag updates.

Currently this feature only works for Photos libraries in the system default location: 
`~/Pictures/Photos Library.photoslibrary`

When enabled Photos keywords are synced to Immich as tags. Immich creates
tags in a nested fashion, using `/` as the separator. This will apply to synced
keywords, e.g. two Photos Keywords `wallpapers/trips/sunsets` and 
`wallpapers/trips/mountains` will create a tag heirarchy of 
`wallpapers` -> `trips` -> `sunsets`, `mountains`.

The config setting `immich.tags.parentTag` (default `🍎`) namespaces every 
synced tag underneath a single parent tag in Immich. **Setting a parent tag is
strongly recommended**: it restricts tag creation and deletion to
descendants of that parent, so any Immich-only tags you maintain
are not touched by the sync.

Non-managed assets added to a synced tag will not be removed by this app.

`immich.tags.stackPrimaryOnly` performs the same task as the album setting:
when an asset stack is added to a tag, only the primary asset is added.

### Burst Photos

With the default configuration, `photos-immich-sync` will only upload
user-selected burst photos. These are members of a burst photo that you have
manually selected in the "Make a selection..." UI. They show up as separate
photos in the library.

You may change which members of a burst photo get uploaded by modifying this
the `photos.export.includeBursts` config setting. See 
[config_template.yaml](./config_template.yaml) for details on this setting.

Currently, `photos-immich-sync` will not stack burst photos. You may opt
to stack these yourself, however note that this may produce unexpected
unexpected interactions on future syncs.

### System Logs

In addition to stdout/stderr, every log line is written to the macOS
unified log system under the subsystem `photos-immich-sync`. The unified
log receives every level regardless of console verbosity.

```bash
log show   --predicate 'subsystem == "photos-immich-sync"' --info --debug --last 1h
log stream --predicate 'subsystem == "photos-immich-sync"' --level debug
```

Console verbosity is controlled with `--quiet` and repeated `-v` flags:

| flag      | what reaches stdout/stderr                       |
|-----------|--------------------------------------------------|
| `--quiet` | errors only (stderr)                             |
| (default) | + warnings, progress updates                     |
| `-v`      | + info                                           |
| `-vv`     | + debug                                          |
| `-vvv`    | + trace                                          |

## Run on a schedule (with launchd)

A LaunchAgent template that runs `photos-immich-sync immich-delta` nightly
at 03:00 local time is provided in 
[scripts/launchd/io.rampant.photos-immich-sync.delta.plist](scripts/launchd/io.rampant.photos-immich-sync.delta.plist).

This is a per-user `LaunchAgent` (not a `LaunchDaemon`): the Photos library
is gated by per-user permissions, so the job requires a logged in user session.
(A daemon that runs as `root` cannot read your Photos Library.)

For scheduled runs to work, you should have run `photos-immich-sync request-auth`
once previously to grant Photos Library access (see above).

For delta syncs (the provided plist specifies a delta sync), you need to
have run a full sync at least once first (see above).

Install the agent (the template uses `__HOME__` as a placeholder because
launchd does not expand `~` or `$HOME` in `StandardOutPath` /
`StandardErrorPath`):

```bash
mkdir -p ~/Library/Logs/photos-immich-sync ~/Library/LaunchAgents
sed "s|__HOME__|$HOME|g" \
  scripts/launchd/io.rampant.photos-immich-sync.delta.plist \
  > ~/Library/LaunchAgents/io.rampant.photos-immich-sync.delta.plist
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/io.rampant.photos-immich-sync.delta.plist
```

Inspect, trigger on demand, or uninstall:

```bash
launchctl print     gui/$(id -u)/io.rampant.photos-immich-sync.delta
launchctl kickstart -k gui/$(id -u)/io.rampant.photos-immich-sync.delta   # run now
launchctl bootout   gui/$(id -u)/io.rampant.photos-immich-sync.delta      # uninstall
```

`stdout`/`stderr` are written to log files in 
`~/Library/Logs/photos-immich-sync/delta.{out,err}.log`. By default, the 
plist specifies `--quiet`, though you can configure this as desired.

## Immich API Key Permissions

This is the list of permissions you need to grant to your Immich API key for 
`photos-immich-sync` to operate correctly:

**Core Functionality (Required)**

```
asset.upload
asset.read
asset.update
asset.delete
asset.copy
stack.create
```

**Album Syncing**

These are required only if album syncing is enabled (`immich.albums.enabled=true`).

```
album.read
album.create
album.update
album.delete
albumAsset.create
albumAsset.delete
```

**Tag Syncing**

These are required only if tag syncing is enabled (`immich.tags.enabled=true`).

```
tag.read
tag.create
tag.delete
tag.update
tag.asset
```

## Local Development & Building

**Requirements**

- macOS with a recent Xcode (the project targets `MACOSX_DEPLOYMENT_TARGET = 26.2`).
- `jq` on `PATH` for [scripts/release.sh](scripts/release.sh) (`brew install jq`).

**Running locally**

Open `photos-immich-sync.xcodeproj` in Xcode. The project ships three
schemes:

- **Full Run** — runs `immich-full` against your real Photos library.
- **Delta Run** — runs `immich-delta` against your real Photos library.
- **Release Build** — the scheme invoked by `scripts/release.sh`; not for
  day-to-day development.

Edit the scheme's launch arguments to override `--config-file` or add
verbosity flags as needed.

**Locally generating a release pkg**

```bash
./scripts/release.sh
```

Builds a universal (`arm64` + `x86_64`) binary, wraps it in a
Developer-ID-signed `.pkg`, submits it to Apple's notary service, and
staples the result. The pkg lands in `dist/photos-immich-sync-<version>.pkg`.
The marketing version is derived from `git describe --tags`.

For local-only testing without a notarization round-trip:

```bash
SKIP_NOTARIZE=1 ./scripts/release.sh
```

Do not distribute pkgs built with `SKIP_NOTARIZE=1`.

Both code paths require the "Developer ID Application" and "Developer ID
Installer" certificates in your login keychain plus notary credentials —
see the comment block at the top of [scripts/release.sh](scripts/release.sh)
for one-time setup (either `xcrun notarytool store-credentials` for local
dev or App Store Connect API key env vars for CI).

**Cutting a release through CI**

The [.github/workflows/release.yml](.github/workflows/release.yml) workflow
is manually triggered (Actions -> Release -> Run workflow). Pick a bump
type (`patch` / `minor` / `major`); the workflow computes the next semver
tag from the latest `v*` tag, builds and notarizes via `scripts/release.sh`,
pushes the tag, and publishes a GitHub Release with the `.pkg` attached.
On failure the tag is not pushed and no release is created; see the
workflow's failure-mode comments for cleanup guidance.