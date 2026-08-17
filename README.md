# Steam Clip Converter for Mac

A native macOS app for browsing Steam Game Recording captures and converting them
into files QuickTime, Photos, Final Cut and Premiere will actually open.

Steam stores recordings as DASH segments — a `session.mpd` manifest plus dozens of
`.m4s` chunks — which no Mac app can play. This converts them losslessly.

**No ffmpeg. No third-party dependencies.** The entire pipeline is AVFoundation.

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

Known limitation: at 16 px the strip and the controller's interior detail fill in,
and the mark reads as a plain lozenge. It resolves cleanly from 32 px up. The
handoff specifies a simplified small-size variant (drop the face buttons and centre
pill, keep the d-pad, thicken the knockout gap to ~4u) if 16 px legibility matters
more than fidelity to the full artwork.

macOS 26 note: a flat `.icns` still renders, but gets no Liquid Glass treatment,
no dark/clear/tinted adaptation and no parallax. `design/app-icon/layers/` holds
pre-positioned back/front SVGs ready for Icon Composer if that becomes relevant.

## Build

```sh
./make-app.sh          # -> build/Steam Clip Converter for Mac.app
```

Requires macOS 15 and a Swift 6 toolchain. The bundle is ad-hoc signed and
unsandboxed, so it can read cloud-synced folders without security-scoped
bookmarks. Distributing it would require signing, sandboxing and notarization.

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

## Safety

The app only ever reads source recordings. It writes to a temp scratch directory
and to the destination folder you choose. Nothing in a recordings folder is
modified or deleted.
