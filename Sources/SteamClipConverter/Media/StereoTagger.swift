import Foundation

/// Marks an MP4 or QuickTime file as stereoscopic 3D by writing Google's `st3d`
/// box (Spherical Video V2 spec) into the video track's sample entry.
///
/// YouTube's "Upload 3D videos" help names exactly this box as how a .mp4 or
/// .mov says "left-right 3D"; its Vision Pro and Quest apps then play the
/// upload in 3D. AVFoundation has no API for the box, so it is written into the
/// finished file directly. Only the `moov` box changes: the 13 new bytes grow
/// the sample entry and every box around it, and if media data follows `moov`
/// its chunk offsets move by the same 13 bytes.
enum StereoTagger {

    enum TagError: LocalizedError {
        case notAMovie(String), noVideoTrack, offsetOverflow
        var errorDescription: String? {
            switch self {
            case .notAMovie(let why): return "Could not add the 3D tag: \(why)"
            case .noVideoTrack: return "Could not add the 3D tag: the file has no video track."
            case .offsetOverflow: return "Could not add the 3D tag: the file is too large for its 32-bit chunk offsets."
            }
        }
    }

    static let boxSize = 13   // size(4) + 'st3d'(4) + version/flags(4) + stereo_mode(1)

    /// Tags `url` in place. Flat is a no-op. Retagging replaces the mode.
    static func tag(_ url: URL, layout: StereoLayout) throws {
        guard layout != .flat else { return }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        let top = try topLevelBoxes(handle, fileSize: fileSize)
        guard let moovIndex = top.firstIndex(where: { $0.type == "moov" }) else {
            throw TagError.notAMovie("no movie box")
        }
        let moov = top[moovIndex]
        try handle.seek(toOffset: moov.offset)
        guard var moovData = try handle.read(upToCount: Int(moov.size)), moovData.count == Int(moov.size) else {
            throw TagError.notAMovie("the movie box is truncated")
        }

        let added = try insertBox(into: &moovData, mode: layout.st3dMode)
        if added > 0 {
            // Offsets are absolute file positions; only data after moov moves.
            try shiftChunkOffsets(in: &moovData, from: moov.offset, by: UInt64(added))
        }

        if moovIndex == top.count - 1 || added == 0 {
            // The usual case: AVFoundation writes moov last, so the file only
            // grows at the end. A mode change keeps the size, so it overwrites
            // in place wherever moov sits - never truncate here, or a movie
            // box that precedes the media takes the media with it.
            try handle.seek(toOffset: moov.offset)
            try handle.write(contentsOf: moovData)
        } else {
            try handle.close()
            try rewrite(url, replacing: moov.offset..<(moov.offset + moov.size), with: moovData)
        }
    }

    /// The `stereo_mode` of the first video track's `st3d` box, or nil if it
    /// has none. Used by tests and to confirm a write.
    static func readMode(_ url: URL) throws -> UInt8? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard let moov = try topLevelBoxes(handle, fileSize: fileSize).first(where: { $0.type == "moov" }) else {
            throw TagError.notAMovie("no movie box")
        }
        try handle.seek(toOffset: moov.offset)
        let data = try handle.read(upToCount: Int(moov.size)) ?? Data()
        let entry = try videoSampleEntry(in: data)
        return children(of: entry.payload(skipping: visualEntryFields), in: data)
            .first { $0.type == "st3d" }
            .map { data[$0.start + 12] }
    }

    // MARK: - Box walking

    /// One box inside an in-memory buffer. `start` is its first byte.
    struct Box {
        let type: String
        let start: Int
        let header: Int     // 8, or 16 with a 64-bit size
        let end: Int

        var size: Int { end - start }
        func payload(skipping extra: Int = 0) -> Range<Int> { (start + header + extra)..<end }
    }

    /// VisualSampleEntry fields after the box header (ISO 14496-12 12.1.3),
    /// laid out identically in QuickTime's video sample description. Child
    /// boxes such as avcC, hvcC and st3d follow them.
    static let visualEntryFields = 78

    static func children(of range: Range<Int>, in data: Data) -> [Box] {
        var boxes: [Box] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            var size = Int(data.uint32(at: pos))
            var header = 8
            if size == 1, pos + 16 <= range.upperBound {
                size = Int(data.uint64(at: pos + 8))
                header = 16
            }
            // Inside a box, a zero size is QuickTime's 4-byte terminator, which
            // AVFoundation writes at the end of a .mov sample description. It
            // ends the list; it is not a box running to the end of the parent.
            if size == 0 { break }
            guard size >= header, pos + size <= range.upperBound else { break }
            boxes.append(Box(type: data.fourCC(at: pos + 4), start: pos, header: header, end: pos + size))
            pos += size
        }
        return boxes
    }

    private static func child(_ type: String, of box: Box, in data: Data, skipping extra: Int = 0) -> Box? {
        children(of: box.payload(skipping: extra), in: data).first { $0.type == type }
    }

    /// The first video track's sample entry, plus the chain of boxes that
    /// contain it (moov is the whole buffer and has no Box of its own).
    private static func videoPath(in moov: Data) throws -> [Box] {
        let moovBox = children(of: 0..<moov.count, in: moov).first { $0.type == "moov" }
        guard let moovBox else { throw TagError.notAMovie("unreadable movie box") }
        for trak in children(of: moovBox.payload(), in: moov) where trak.type == "trak" {
            guard let mdia = child("mdia", of: trak, in: moov),
                  let hdlr = child("hdlr", of: mdia, in: moov),
                  hdlr.payload().count >= 12,
                  // version/flags(4), pre_defined or QuickTime component type(4), then the handler.
                  moov.fourCC(at: hdlr.payload().lowerBound + 8) == "vide",
                  let minf = child("minf", of: mdia, in: moov),
                  let stbl = child("stbl", of: minf, in: moov),
                  let stsd = child("stsd", of: stbl, in: moov),
                  // version/flags(4) + entry_count(4) precede the entries.
                  let entry = children(of: stsd.payload(skipping: 8), in: moov).first,
                  entry.size >= entry.header + visualEntryFields
            else { continue }
            return [moovBox, trak, mdia, minf, stbl, stsd, entry]
        }
        throw TagError.noVideoTrack
    }

    private static func videoSampleEntry(in moov: Data) throws -> Box {
        try videoPath(in: moov).last!
    }

    /// Adds or updates the st3d box. Returns how many bytes the buffer grew.
    static func insertBox(into moov: inout Data, mode: UInt8) throws -> Int {
        let path = try videoPath(in: moov)
        let entry = path.last!
        let existingChildren = children(of: entry.payload(skipping: visualEntryFields), in: moov)
        if let existing = existingChildren.first(where: { $0.type == "st3d" }) {
            moov[existing.start + 12] = mode
            return 0
        }
        // After the last real child, so ahead of a QuickTime terminator. A box
        // after the terminator is invisible to every parser, ffprobe included.
        let insertAt = existingChildren.last?.end ?? entry.payload(skipping: visualEntryFields).lowerBound

        var box = Data()
        box.appendUInt32(UInt32(boxSize))
        box.append(contentsOf: Array("st3d".utf8))
        box.appendUInt32(0)        // version 0, flags 0
        box.append(mode)
        moov.insert(contentsOf: box, at: insertAt)

        // Every box on the path ends after the insertion point, so each one
        // grows; none of their starts move.
        for ancestor in path {
            if ancestor.header == 16 {
                moov.setUInt64(moov.uint64(at: ancestor.start + 8) + UInt64(boxSize), at: ancestor.start + 8)
            } else {
                moov.setUInt32(moov.uint32(at: ancestor.start) + UInt32(boxSize), at: ancestor.start)
            }
        }
        return boxSize
    }

    /// Adds `delta` to every chunk offset at or past `threshold`, in every
    /// track: stco (32-bit) and co64 (64-bit) tables.
    static func shiftChunkOffsets(in moov: inout Data, from threshold: UInt64, by delta: UInt64) throws {
        guard let moovBox = children(of: 0..<moov.count, in: moov).first(where: { $0.type == "moov" }) else { return }
        for trak in children(of: moovBox.payload(), in: moov) where trak.type == "trak" {
            guard let mdia = child("mdia", of: trak, in: moov),
                  let minf = child("minf", of: mdia, in: moov),
                  let stbl = child("stbl", of: minf, in: moov) else { continue }
            for table in children(of: stbl.payload(), in: moov) where table.type == "stco" || table.type == "co64" {
                let base = table.payload().lowerBound
                let count = Int(moov.uint32(at: base + 4))
                let wide = table.type == "co64"
                for i in 0..<count {
                    let at = base + 8 + i * (wide ? 8 : 4)
                    guard at + (wide ? 8 : 4) <= table.end else { break }
                    if wide {
                        let value = moov.uint64(at: at)
                        if value >= threshold { moov.setUInt64(value + delta, at: at) }
                    } else {
                        let value = UInt64(moov.uint32(at: at))
                        guard value >= threshold else { continue }
                        guard value + delta <= UInt64(UInt32.max) else { throw TagError.offsetOverflow }
                        moov.setUInt32(UInt32(value + delta), at: at)
                    }
                }
            }
        }
    }

    // MARK: - File level

    private struct TopBox { let type: String; let offset: UInt64; let size: UInt64 }

    private static func topLevelBoxes(_ handle: FileHandle, fileSize: UInt64) throws -> [TopBox] {
        var boxes: [TopBox] = []
        var pos: UInt64 = 0
        while pos + 8 <= fileSize {
            try handle.seek(toOffset: pos)
            guard let head = try handle.read(upToCount: 16), head.count >= 8 else { break }
            var size = UInt64(head.uint32(at: 0))
            if size == 1 {
                guard head.count >= 16 else { throw TagError.notAMovie("truncated box header") }
                size = head.uint64(at: 8)
            } else if size == 0 {
                size = fileSize - pos
            }
            guard size >= 8, pos + size <= fileSize else {
                throw TagError.notAMovie("a '\(head.fourCC(at: 4))' box runs past the end of the file")
            }
            boxes.append(TopBox(type: head.fourCC(at: 4), offset: pos, size: size))
            pos += size
        }
        return boxes
    }

    /// Writes a copy with `range` replaced, then swaps it in. Only reached for
    /// files whose movie box precedes other boxes, which this app never writes.
    private static func rewrite(_ url: URL, replacing range: Range<UInt64>, with replacement: Data) throws {
        let temp = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).st3d-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        do {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            func copy(_ from: UInt64, _ to: UInt64) throws {
                try input.seek(toOffset: from)
                var left = to - from
                while left > 0 {
                    let chunk = try autoreleasepool { try input.read(upToCount: Int(min(left, 8 << 20))) } ?? Data()
                    guard !chunk.isEmpty else { break }
                    try output.write(contentsOf: chunk)
                    left -= UInt64(chunk.count)
                }
            }
            try copy(0, range.lowerBound)
            try output.write(contentsOf: replacement)
            try copy(range.upperBound, try input.seekToEnd())
            try output.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

// MARK: - Big-endian helpers

extension Data {
    func uint32(at i: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v = v << 8 | UInt32(self[startIndex + i + k]) }
        return v
    }
    func uint64(at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = v << 8 | UInt64(self[startIndex + i + k]) }
        return v
    }
    func fourCC(at i: Int) -> String {
        String(decoding: self[(startIndex + i)..<(startIndex + i + 4)], as: UTF8.self)
    }
    mutating func setUInt32(_ v: UInt32, at i: Int) {
        for k in 0..<4 { self[startIndex + i + k] = UInt8(truncatingIfNeeded: v >> (24 - 8 * k)) }
    }
    mutating func setUInt64(_ v: UInt64, at i: Int) {
        for k in 0..<8 { self[startIndex + i + k] = UInt8(truncatingIfNeeded: v >> (56 - 8 * k)) }
    }
    mutating func appendUInt32(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16),
                            UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
    }
}
