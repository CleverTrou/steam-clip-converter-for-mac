import Foundation

/// A Matroska (.mkv) file indexed frame by frame, without copying any media.
///
/// AVFoundation cannot open Matroska at all, and it is what OBS records by
/// default because a recording cut off mid-write stays playable. This reads
/// the subset OBS writes (through FFmpeg's muxer): one H.264 or HEVC video
/// track, AAC audio, SimpleBlocks or BlockGroups without lacing or content
/// compression. Anything outside that is reported, never guessed at.
///
/// A file that ends mid-cluster - OBS killed, a forced shutdown - is read up
/// to its last complete frame, the same as a player would.
struct MatroskaFile {

    struct Track {
        enum Kind { case video, audio, other }
        var number: UInt64 = 0
        var kind: Kind = .other
        var codecID = ""
        var codecPrivate = Data()
        var width = 0
        var height = 0
        var sampleRate = 0.0
        var channels = 1
        /// Matroska's own 3D flag: 1 = side by side, left first; 3 = top and
        /// bottom, left first. Other values swap the eyes or interlace.
        var stereoMode: UInt64?
        var isCompressed = false
    }

    struct Frame {
        let track: UInt64
        let offset: Int        // payload position in the file
        let size: Int
        let time: Int64        // presentation time in nanoseconds
        let isKey: Bool
    }

    enum ReadError: LocalizedError {
        case notMatroska, unsupported(String), corrupt(String)
        var errorDescription: String? {
            switch self {
            case .notMatroska: return "This is not a Matroska (.mkv) file."
            case .unsupported(let what): return "This .mkv uses \(what), which isn't supported."
            case .corrupt(let what): return "This .mkv is damaged: \(what)."
            }
        }
    }

    let data: Data
    let tracks: [Track]
    let frames: [Frame]

    var videoTrack: Track? { tracks.first { $0.kind == .video } }
    var audioTrack: Track? { tracks.first { $0.kind == .audio } }

    /// The layout Matroska's StereoMode declares, if any.
    var declaredStereoLayout: StereoLayout? {
        switch videoTrack?.stereoMode {
        case 1: return .sideBySide
        case 3: return .topBottom
        default: return nil
        }
    }

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        self.data = data
        var parser = Parser(data: data)
        try parser.parse()
        tracks = parser.tracks
        frames = parser.frames
    }

    // MARK: - Element IDs (Matroska spec, RFC 9559)

    fileprivate enum ID {
        static let ebml: UInt64 = 0x1A45DFA3
        static let segment: UInt64 = 0x18538067
        static let info: UInt64 = 0x1549A966
        static let timecodeScale: UInt64 = 0x2AD7B1
        static let tracks: UInt64 = 0x1654AE6B
        static let trackEntry: UInt64 = 0xAE
        static let trackNumber: UInt64 = 0xD7
        static let trackType: UInt64 = 0x83
        static let codecID: UInt64 = 0x86
        static let codecPrivate: UInt64 = 0x63A2
        static let video: UInt64 = 0xE0
        static let pixelWidth: UInt64 = 0xB0
        static let pixelHeight: UInt64 = 0xBA
        static let stereoMode: UInt64 = 0x53B8
        static let audio: UInt64 = 0xE1
        static let samplingFrequency: UInt64 = 0xB5
        static let channels: UInt64 = 0x9F
        static let contentEncodings: UInt64 = 0x6D80
        static let cluster: UInt64 = 0x1F43B675
        static let timecode: UInt64 = 0xE7
        static let simpleBlock: UInt64 = 0xA3
        static let blockGroup: UInt64 = 0xA0
        static let block: UInt64 = 0xA1
        static let referenceBlock: UInt64 = 0xFB
        /// Level-1 elements: an unknown-size cluster ends where one begins.
        static let segmentChildren: Set<UInt64> = [
            0x114D9B74, info, tracks, cluster, 0x1C53BB6B, 0x1043A770, 0x1254C367, 0x1941A469,
        ]
    }

    // MARK: - Parser

    private struct Parser {
        let data: Data
        var timecodeScale: UInt64 = 1_000_000   // ns per tick, Matroska's default
        var tracks: [Track] = []
        var frames: [Frame] = []

        struct Element { let id: UInt64; let start: Int; let end: Int; let sizeKnown: Bool }

        init(data: Data) { self.data = data }

        mutating func parse() throws {
            var pos = 0
            guard let header = try element(at: &pos, limit: data.count), header.id == ID.ebml else {
                throw ReadError.notMatroska
            }
            pos = header.end
            while let element = try element(at: &pos, limit: data.count) {
                if element.id == ID.segment {
                    try parseSegment(element)
                    break
                }
                pos = element.end
            }
            guard !tracks.isEmpty else { throw ReadError.corrupt("it has no track list") }
        }

        mutating func parseSegment(_ segment: Element) throws {
            var pos = segment.start
            while pos < segment.end, let element = try element(at: &pos, limit: segment.end) {
                switch element.id {
                case ID.info: try parseInfo(element)
                case ID.tracks: try parseTracks(element)
                case ID.cluster:
                    pos = try parseCluster(element, segmentEnd: segment.end)
                    continue
                default: break
                }
                guard element.sizeKnown else { break }   // nothing to skip by
                pos = element.end
            }
        }

        mutating func parseInfo(_ info: Element) throws {
            var pos = info.start
            while pos < info.end, let e = try element(at: &pos, limit: info.end) {
                if e.id == ID.timecodeScale { timecodeScale = max(1, uint(e)) }
                pos = e.end
            }
        }

        mutating func parseTracks(_ list: Element) throws {
            var pos = list.start
            while pos < list.end, let entry = try element(at: &pos, limit: list.end) {
                defer { pos = entry.end }
                guard entry.id == ID.trackEntry else { continue }
                var track = Track()
                var p = entry.start
                while p < entry.end, let e = try element(at: &p, limit: entry.end) {
                    switch e.id {
                    case ID.trackNumber: track.number = uint(e)
                    case ID.trackType:
                        let type = uint(e)
                        track.kind = type == 1 ? .video : type == 2 ? .audio : .other
                    case ID.codecID: track.codecID = string(e)
                    case ID.codecPrivate: track.codecPrivate = data.subdata(in: e.start..<e.end)
                    case ID.contentEncodings: track.isCompressed = true
                    case ID.video:
                        var q = e.start
                        while q < e.end, let v = try element(at: &q, limit: e.end) {
                            switch v.id {
                            case ID.pixelWidth: track.width = Int(uint(v))
                            case ID.pixelHeight: track.height = Int(uint(v))
                            case ID.stereoMode: track.stereoMode = uint(v)
                            default: break
                            }
                            q = v.end
                        }
                    case ID.audio:
                        var q = e.start
                        while q < e.end, let a = try element(at: &q, limit: e.end) {
                            switch a.id {
                            case ID.samplingFrequency: track.sampleRate = float(a)
                            case ID.channels: track.channels = Int(uint(a))
                            default: break
                            }
                            q = a.end
                        }
                    default: break
                    }
                    p = e.end
                }
                tracks.append(track)
            }
        }

        /// Returns where parsing should continue: the cluster's end, or for an
        /// unknown-size cluster the first level-1 element after its blocks.
        mutating func parseCluster(_ cluster: Element, segmentEnd: Int) throws -> Int {
            var clusterTime: Int64 = 0
            var pos = cluster.start
            let limit = cluster.sizeKnown ? cluster.end : segmentEnd
            while pos < limit {
                let before = pos
                guard let e = try element(at: &pos, limit: limit) else { return limit }
                if !cluster.sizeKnown, ID.segmentChildren.contains(e.id) { return before }
                // A block's size is always written, so one that runs past the
                // data is where a cut-off recording ends. Half a frame would
                // decode as garbage; stop at the last whole one.
                if e.id == ID.simpleBlock || e.id == ID.blockGroup, !e.sizeKnown { return limit }
                switch e.id {
                case ID.timecode: clusterTime = Int64(uint(e))
                case ID.simpleBlock:
                    try addBlock(e, clusterTime: clusterTime, keyFlag: true, hasReference: false)
                case ID.blockGroup:
                    var block: Element?
                    var referenced = false
                    var p = e.start
                    while p < e.end, let child = try element(at: &p, limit: e.end) {
                        if child.id == ID.block { block = child }
                        if child.id == ID.referenceBlock { referenced = true }
                        p = child.end
                    }
                    if let block { try addBlock(block, clusterTime: clusterTime, keyFlag: false, hasReference: referenced) }
                default: break
                }
                pos = e.end
            }
            return limit
        }

        mutating func addBlock(_ e: Element, clusterTime: Int64, keyFlag: Bool, hasReference: Bool) throws {
            var pos = e.start
            guard let track = vint(at: &pos, limit: e.end, keepMarker: false), pos + 3 <= e.end else {
                throw ReadError.corrupt("a block header is cut short")
            }
            let relative = Int16(bitPattern: UInt16(data[pos]) << 8 | UInt16(data[pos + 1]))
            let flags = data[pos + 2]
            pos += 3
            guard flags & 0x06 == 0 else { throw ReadError.unsupported("laced blocks") }
            // SimpleBlock carries a keyframe bit; a BlockGroup is a keyframe
            // exactly when nothing is referenced.
            let isKey = keyFlag ? (flags & 0x80 != 0) : !hasReference
            let ticks = clusterTime + Int64(relative)
            frames.append(Frame(track: track.value, offset: pos, size: e.end - pos,
                                time: ticks * Int64(timecodeScale), isKey: isKey))
        }

        // MARK: EBML primitives

        /// Reads an element header. nil at a clean end of data; a header that
        /// runs past `limit` is treated as the end too (a truncated file).
        func element(at pos: inout Int, limit: Int) throws -> Element? {
            var p = pos
            guard p < limit,
                  let id = vint(at: &p, limit: limit, keepMarker: true),
                  let size = vint(at: &p, limit: limit, keepMarker: false) else { return nil }
            let known = !size.allOnes
            let end = known ? p + Int(clamping: size.value) : limit
            guard end >= p else { throw ReadError.corrupt("an element has a negative size") }
            pos = p
            return Element(id: id.value, start: p, end: min(end, limit), sizeKnown: known && end <= limit)
        }

        func vint(at pos: inout Int, limit: Int, keepMarker: Bool) -> (value: UInt64, allOnes: Bool)? {
            guard pos < limit else { return nil }
            let first = data[pos]
            guard first != 0 else { return nil }
            let length = first.leadingZeroBitCount + 1
            guard pos + length <= limit else { return nil }
            let mask: UInt8 = length == 8 ? 0 : 0xFF >> length
            var value = UInt64(keepMarker ? first : first & mask)
            var allOnes = (first & mask) == mask
            for i in 1..<length {
                let byte = data[pos + i]
                value = value << 8 | UInt64(byte)
                allOnes = allOnes && byte == 0xFF
            }
            pos += length
            return (value, !keepMarker && allOnes)
        }

        func uint(_ e: Element) -> UInt64 {
            var value: UInt64 = 0
            for i in e.start..<min(e.end, e.start + 8) { value = value << 8 | UInt64(data[i]) }
            return value
        }

        func float(_ e: Element) -> Double {
            let bits = uint(e)
            switch e.end - e.start {
            case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
            case 8: return Double(bitPattern: bits)
            default: return 0
            }
        }

        func string(_ e: Element) -> String {
            String(decoding: data[e.start..<e.end].prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
