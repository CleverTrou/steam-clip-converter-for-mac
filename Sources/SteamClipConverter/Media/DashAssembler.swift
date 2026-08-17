import Foundation

/// Turns Steam's DASH segment folders into files AVFoundation can open.
///
/// Two facts make this cheap:
///   * `init-stream<n>.m4s` + any subset of that stream's chunks is a valid
///     fragmented MP4. Each segment begins at a sync sample, so a single chunk
///     can be assembled on its own for a preview frame -- no need to touch the
///     other 500 MB of a clip.
///   * The only thing standing between Steam's HEVC and every Apple video API is
///     the sample-entry fourcc. Steam writes `hev1`; AVFoundation accepts only
///     `hvc1`. The parameter sets already live in the hvcC box, so rewriting
///     those four bytes in the init segment is lossless and sufficient.
enum DashAssembler {

    enum Stream: Int {
        case video = 0
        case audio = 1
    }

    /// Reads the init segment, retagging HEVC so Apple will decode it.
    static func initSegment(for clip: Clip, stream: Stream) throws -> Data? {
        let url = clip.url.appending(path: "init-stream\(stream.rawValue).m4s")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var data = try Data(contentsOf: url)
        if let range = data.range(of: Data("hev1".utf8)) {
            data.replaceSubrange(range, with: Data("hvc1".utf8))
        }
        return data
    }

    static func chunkURLs(for clip: Clip, stream: Stream) -> [URL] {
        let prefix = "chunk-stream\(stream.rawValue)-"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: clip.url.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".m4s") }
            .sorted()
        return names.map { clip.url.appending(path: $0) }
    }

    /// Assembles a stream into `destination`. Passing `chunkLimit` or
    /// `chunkRange` builds only part of the clip -- used for previews.
    @discardableResult
    static func assemble(clip: Clip,
                         stream: Stream,
                         to destination: URL,
                         chunkRange: Range<Int>? = nil) throws -> Bool {
        guard let header = try initSegment(for: clip, stream: stream) else { return false }
        var chunks = chunkURLs(for: clip, stream: stream)
        guard !chunks.isEmpty else { return false }
        if let chunkRange {
            let lower = max(0, chunkRange.lowerBound)
            let upper = min(chunks.count, chunkRange.upperBound)
            guard lower < upper else { return false }
            chunks = Array(chunks[lower..<upper])
        }

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: header)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for chunk in chunks {
            try autoreleasepool {
                try handle.write(contentsOf: Data(contentsOf: chunk, options: .mappedIfSafe))
            }
        }
        return true
    }

    /// Which segment covers `time`, 0-based.
    static func segmentIndex(for time: Double, in clip: Clip) -> Int {
        guard clip.segmentDuration > 0 else { return 0 }
        return min(max(Int(time / clip.segmentDuration), 0), clip.videoSegmentCount - 1)
    }

    static func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Steam Clip Converter")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
