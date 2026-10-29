<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

# Changelog

All notable changes to Steam Clip Converter for Mac are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Convert Video Files…** (toolbar, or ⇧⌘O) converts video files that aren't
  Steam recordings, including OBS recordings (`.mkv`), which no Mac app opens.
  Streams are copied, not re-encoded: a 9-minute 1080p60 OBS recording takes
  about 2 seconds. A recording cut off mid-write converts up to its last whole
  frame.
- A **3D layout** setting for games recorded in side-by-side 3D (for example
  with ReShade's SuperDepth3D). 3D exports carry the stereo tag YouTube looks
  for, so the upload plays in 3D, including in YouTube's Apple Vision Pro and
  Meta Quest apps. They also end in `.3D.HSBS`, which headset video players
  recognise. "Detect from file" reads that tag from file names, such as the
  airGPU toolkit's 3D captures, and from an `.mkv`'s own 3D flag.

## [1.1.0] - 2026-09-30

### Added

- Steam timeline events become chapters in `.mov` exports, so QuickTime
  Player and IINA can jump to them: game events ("Meet Alyx", "A Hunter
  pounced on you!"), screenshots you took, and map or chapter names. Clips
  with events show ticks on their thumbnail, and scrubbing near one shows its
  name. ([#3](https://github.com/CleverTrou/steam-clip-converter-for-mac/pull/3))

### Changed

- The download is a disk image (`.dmg`) instead of a `.zip`. Open it and drag
  the app onto the Applications shortcut inside. ([#4](https://github.com/CleverTrou/steam-clip-converter-for-mac/pull/4))

### Fixed

- The "Reveal in Finder" link under the recordings folder is readable. It was
  white text on the light sidebar. ([#2](https://github.com/CleverTrou/steam-clip-converter-for-mac/pull/2))
- Recording times are right outside UTC. Steam names recordings in UTC, and
  the app read that as local time, so a clip from 8:26 PM Central showed as
  1:26 AM the next day. Cards and exported filenames now show your local
  time, and files exported under the old names are still recognized as
  converted. ([#3](https://github.com/CleverTrou/steam-clip-converter-for-mac/pull/3))

## [1.0.1] - 2026-09-27

### Added

- A ready-to-run download on the GitHub release page. It runs natively on
  Apple silicon and Intel Macs. It is not notarized, so the README explains how
  to open it the first time. ([#1](https://github.com/CleverTrou/steam-clip-converter-for-mac/pull/1))
- Released under the MIT license. The About window shows the copyright.
  ([#1](https://github.com/CleverTrou/steam-clip-converter-for-mac/pull/1))
- The README links to Valve's guides for turning on Steam Game Recording, and
  warns that background recordings are overwritten once their disk space fills.
  ([#1](https://github.com/CleverTrou/steam-clip-converter-for-mac/pull/1))

### Fixed

- Clip cards work with the keyboard and VoiceOver. Each card is a real button
  that announces the game, date, duration, resolution, size, whether it is
  selected, and when and to which format it was converted. ([397742f](https://github.com/CleverTrou/steam-clip-converter-for-mac/commit/397742f14ba0a2bbf460368fd4b0569b4c5f84fc))
- VoiceOver announces the format picker, the destination folder, the
  conversion progress, which filters are active, and when a batch finishes. ([397742f](https://github.com/CleverTrou/steam-clip-converter-for-mac/commit/397742f14ba0a2bbf460368fd4b0569b4c5f84fc))
- Clip details, the "Converted" line, and the CONVERTED badge have enough
  contrast to read. Some were about 2:1 before. ([397742f](https://github.com/CleverTrou/steam-clip-converter-for-mac/commit/397742f14ba0a2bbf460368fd4b0569b4c5f84fc))

### Security

- Game names are looked up only for Steam app IDs made of ASCII digits. ([397742f](https://github.com/CleverTrou/steam-clip-converter-for-mac/commit/397742f14ba0a2bbf460368fd4b0569b4c5f84fc))

## [1.0.0] - 2026-08-17

First version.

### Added

- Browse Steam Game Recording captures (`session.mpd` plus `.m4s` segments) and
  convert them to QuickTime-playable files using only AVFoundation: no ffmpeg
  and no third-party dependencies.
- Lossless conversion. Steam tags HEVC as `hev1`, which AVFoundation refuses,
  so the init segment is patched to `hvc1` and the video is remuxed without
  re-encoding. A 489 MB 4K clip converts in about a second.
- `.mov` output by default, which keeps 12 metadata fields where `.mp4` keeps 6.
- Scrubbing previews that assemble only the segment under the cursor.
- A conversion ledger that marks clips already exported, including files made
  by other tools, matched by capture timestamp.
- Stream parameters are read from the bitstream, because Steam's MPD is
  unreliable.
- An app icon, with dedicated 16px and 32px variants that stay legible at small
  sizes.

[Unreleased]: https://github.com/CleverTrou/steam-clip-converter-for-mac/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/CleverTrou/steam-clip-converter-for-mac/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/CleverTrou/steam-clip-converter-for-mac/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/CleverTrou/steam-clip-converter-for-mac/releases/tag/v1.0.0
