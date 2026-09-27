<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

# Changelog

All notable changes to Steam Clip Converter for Mac are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
