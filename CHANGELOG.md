<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

# Changelog

All notable changes to Steam Clip Converter for Mac are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.1] - 2026-09-27

### Added

- A ready-to-run download on the GitHub release page. It runs natively on
  Apple silicon and Intel Macs. It is not notarized, so the README explains how
  to open it the first time. ([#1](https://github.com/CleverTrou/steam-clip-converter-for-mac/pull/1))
- Released under the MIT license. The About window shows the copyright.
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

[Unreleased]: https://github.com/CleverTrou/steam-clip-converter-for-mac/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/CleverTrou/steam-clip-converter-for-mac/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/CleverTrou/steam-clip-converter-for-mac/releases/tag/v1.0.0
