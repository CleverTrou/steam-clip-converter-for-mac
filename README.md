# Steam Clip Converter for Mac

A native macOS app for browsing Steam Game Recording captures and converting them
into files QuickTime, Photos, Final Cut and Premiere will actually open.

Steam stores recordings as DASH segments — a `session.mpd` manifest plus dozens of
`.m4s` chunks — which no Mac app can play. This converts them losslessly.

**No ffmpeg. No third-party dependencies.** The entire pipeline is AVFoundation.

## Download

Get the latest `.zip` from
[Releases](https://github.com/CleverTrou/steam-clip-converter-for-mac/releases/latest),
unzip it, and move the app to Applications. It needs macOS 15 or later and runs
natively on both Apple silicon and Intel Macs.

The app is not notarized by Apple, so the first launch is blocked with "Apple
could not verify … is free of malware". To open it once, and from then on:

1. Try to open the app, then click **Done** on the warning.
2. Open **System Settings → Privacy & Security**, scroll to the bottom, and click
   **Open Anyway** next to Steam Clip Converter for Mac.
3. Confirm with your password or Touch ID.

On macOS 15, Control-clicking the app and choosing **Open** no longer bypasses
the warning. You can also clear the quarantine flag in Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/Steam Clip Converter for Mac.app"
```

If you'd rather not run a prebuilt download, [build it from source](#build). It
takes one command. A local build is also ad-hoc signed and unnotarized, but
macOS doesn't quarantine apps you build yourself, so it opens without the
warning.

## Recording with Steam

This app converts recordings; the Steam client makes them. To turn recording on,
open **Steam > Settings > Game Recording** and choose **Record in Background**,
which captures everything you play, or **Record on Demand**, which captures only
when you start it. Valve's own guides cover the rest, including disk limits,
per-game settings and shortcut keys:

- [Steam Game Recording](https://help.steampowered.com/en/faqs/view/23B7-49AD-4A28-9590)
  on Steam Support
- [Steam Game Recording](https://store.steampowered.com/gamerecording), Valve's
  overview of the feature

Background recordings are temporary. Once the disk space you gave them fills up,
Steam overwrites the oldest footage, so convert anything you want to keep before
then, or save it as a clip in Steam.

The same settings page shows where recordings are saved and lets you pick
another folder. Point this app at that folder, or at a synced copy of it if you
record on a different machine.

## Why the output of other tools won't play in QuickTime

HEVC in MP4 has two possible sample-entry fourccs:

| | `hvc1` | `hev1` |
|---|---|---|
| Parameter sets (VPS/SPS/PPS) | in the `hvcC` box only | may also appear in-band, may change mid-stream |
| QuickTime / Quick Look / Photos / Final Cut | ✅ | ❌ |
| VLC | ✅ | ✅ |

Steam writes `hev1`, and generic remuxers preserve it — which is why converted
Steam clips typically play in VLC but not QuickTime. Since the parameter sets
already live in the `hvcC` box, rewriting those four bytes in the init segment is
lossless and sufficient. This app patches them at assembly time, so correct
tagging propagates through probing, thumbnails, scrubbing and export alike.

## What it does

- **Finds recordings** — scans `userdata/*/gamerecordings` and reads
  `BackgroundRecordPath` out of `localconfig.vdf`; any folder can be chosen
  manually (useful when clips are synced from another machine).
- **Reads real metadata** — resolution, codec and frame rate come from the
  bitstream, never the manifest. Steam's manifests claim `avc1` / 256x256 even for
  4K HEVC captures.
- **Resolves game names** from the Steam store API, cached on disk for offline use.
- **Scrubbable previews** — dragging across a thumbnail assembles only the DASH
  segment under the cursor, so scrubbing a 500 MB clip reads a few MB, ~30ms/frame.
- **Filters** by game, quality bucket, and conversion status; sorts by date,
  duration or file size in both directions.
- **Converts by passthrough remux** — the bitstream is copied, never re-encoded.
  A 489 MB 4K clip converts in about a second.
- **Marks what's already converted** and leaves it in place, including files
  produced by other tools (matched on capture timestamp).

## Container choice

`.mov` is the default because it round-trips more metadata. Measured, same
composition, same passthrough export:

| Container / keyspace | Sent | Survived |
|---|---|---|
| mp4 + `quickTimeMetadata` | 7 | 0 |
| mp4 + `isoUserData` | 7 | 0 |
| mp4 + `common` | 7 | 6 |
| **mov + `common`** | 7 | **7** |

`.mov` also keeps custom `mdta` keys, so exports carry 12 fields: title,
description, software, author, publisher, creation date, plus app ID, game, source
folder, kind, capture format and codec. `.mp4` remains available for sharing.

## App icon

Source artwork lives in `design/app-icon/` as SVG. `make-app.sh` copies the
committed `AppIcon.icns` into the bundle, and regenerates it from the SVG first if
the SVG is newer and `rsvg-convert` is installed. The icon is placed before
`codesign` runs, since the signature covers `Contents/Resources`.

An `.icns` is a set of independent rasters rather than one image scaled, so the
small slots carry simplified geometry without affecting the large ones. Anything
rendered into 32 physical pixels or fewer uses a size-specific variant:

| Slot | Pixels | Source |
|---|---|---|
| `icon_16x16` | 16 | `icon-16.svg` |
| `icon_16x16@2x`, `icon_32x32` | 32 | `icon-32.svg` |
| `icon_32x32@2x` and up | 64–1024 | `icon-sequoia-1024.svg` |

The full artwork collapses to a featureless lozenge at 16 px: the face buttons and
centre pill fill in, the 3.1u knockout gap closes, and seven sprockets per row land
below one pixel each. Both variants drop the face buttons and centre pill, keep the
d-pad, and open the knockout gap to 4u, per the handoff. Measurement drove three
further adaptations: the cast shadow is removed (a 3.4u blur is mush at this size),
the glyph is scaled up (5.109 → 5.85 at 32 px, → 6.4 at 16 px), and the sprockets
are reduced to four larger ones at 32 px and dropped entirely at 16 px. Container
geometry, gradients and palette are untouched, so there is no visible seam at the
switch point.

macOS 26 note: a flat `.icns` still renders, but gets no Liquid Glass treatment,
no dark/clear/tinted adaptation and no parallax. `design/app-icon/layers/` holds
pre-positioned back/front SVGs ready for Icon Composer if that becomes relevant.

## Build

```sh
./make-app.sh          # -> build/Steam Clip Converter for Mac.app
```

Requires macOS 15 and a Swift 6 toolchain (Xcode 16 or later). The script builds
Apple silicon and Intel separately and joins them into one universal binary with
`lipo`. `UNIVERSAL=0 ./make-app.sh` builds for your own Mac only, which is
faster.

The bundle is ad-hoc signed and unsandboxed, so it can read cloud-synced folders
without security-scoped bookmarks. That is also why the published download is not
notarized: notarization needs a paid Apple Developer ID. See [Download](#download).

The app's version lives in the `Info.plist` written by `make-app.sh`, not in
`Package.swift`. Bump `CFBundleShortVersionString` and `CFBundleVersion` there in
every release.

## Layout

```
Sources/SteamClipConverter/
  Model/  Clip · ClipScanner (+MPD parser) · SteamLibrary · ConversionLedger
          SupportDirectory · AppModel
  Media/  DashAssembler · MediaProbe · ClipConverter
  Views/  ContentView · ClipCard
```

## AVFoundation notes

Three things cost real debugging time and are easy to hit again:

1. **`AVAssetTrack` does not retain its `AVAsset`.** Creating an asset inline
   inside an `if let` lets it deallocate while the track is still in use; every
   later call fails with an opaque `-11800 / -12780` that looks like a codec error.
2. **Insert each track over its own `timeRange`.** Audio and video differ by up to
   ~0.1s because segment boundaries don't align; overrunning the audio track fails
   the export with the same unexplained error.
3. **Fragmented MP4 needs `AVURLAssetPreferPreciseDurationAndTimingKey`,** or the
   duration is approximate and composition inserts can misbehave.

## Safety and privacy

The app only ever reads source recordings. It writes to a temp scratch directory
and to the destination folder you choose. Nothing in a recordings folder is
modified or deleted.

Its only network request asks the Steam store for game names, sending just the
numeric app IDs of the games you recorded. There are no analytics and no
accounts. Everything else stays on your Mac:

- `~/Library/Application Support/Steam Clip Converter/Conversions.json` records
  each converted clip: its full output path, when it was converted, and the
  format.
- `GameNames.json` in the same folder caches app ID → game name lookups.
- The recordings folder you choose is remembered, as a full path, in the app's
  preferences (`UserDefaults`).

Exported files carry the game and its Steam app ID as metadata, plus the capture
time when the recording's folder name includes one, as Steam's normally do.
`.mov` exports also carry the recording's folder name (e.g.
`bg_250820_20260816_163103`). Exports never include your username or any file
path.

## License

[MIT](LICENSE) © 2026 Trevor Nelson. You're free to use, modify and redistribute
it, as long as the copyright notice and license stay with every copy.
