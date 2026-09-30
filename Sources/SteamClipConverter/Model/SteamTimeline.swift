import Foundation

/// A moment inside one clip, from Steam's timeline for the session it was
/// recorded in: an event a game reported, or one Steam added itself.
struct ClipMarker: Hashable {
    /// Seconds from the start of the clip.
    let time: Double
    let title: String
}

/// Reads the timeline data Steam writes next to its recordings:
///
///     <gamerecordings>/gamerecording.pb        index: timeline -> recordings
///     <gamerecordings>/timelines/<id>.json      one file per game session
///     <gamerecordings>/video/bg_<appid>_...      the recordings themselves
///
/// A timeline spans a whole session and usually covers several recordings, so
/// the index's per-recording offset is what places an event inside a clip.
/// Timeline times are milliseconds from the session start. Folder names only
/// carry whole seconds, so they are never used for alignment.
enum SteamTimeline {

    /// Markers for `clip`, or none if Steam left no timeline for it.
    static func markers(for clip: Clip) -> [ClipMarker] {
        let root = clip.url.deletingLastPathComponent().deletingLastPathComponent()
        guard let placement = index(at: root)[clip.id],
              let timeline = Self.timeline(at: root.appending(path: "timelines/\(placement.timelineID).json"))
        else { return [] }

        return timeline.entries.compactMap { entry -> ClipMarker? in
            let start = (entry.time - timeline.start - placement.offset) / 1000
            let end = start + (entry.duration ?? 0) / 1000
            // A range that began before the clip still marks where the clip opens.
            guard start < clip.duration, end >= 0 else { return nil }
            return ClipMarker(time: max(start, 0), title: entry.title)
        }
        .sorted { $0.time < $1.time }
    }

    // MARK: - gamerecording.pb

    struct Placement: Equatable {
        let timelineID: String
        /// Milliseconds from the timeline start to the first frame of the recording.
        let offset: Double
    }

    /// Recording folder name -> where it sits in its timeline. Cached per root:
    /// every clip in a library shares one index.
    static func index(at root: URL) -> [String: Placement] {
        let url = root.appending(path: "gamerecording.pb")
        return cache.value(for: url) {
            guard let data = try? Data(contentsOf: url) else { return [:] }
            return parseIndex(data)
        }
    }

    /// Field numbers, read from real files (Valve publishes no schema):
    ///   1  timeline (repeated) { 1 id, 2 app ID, 3 start (unix s), 4 length (ms),
    ///                            5 recording (repeated) { 1 folder, 2 offset (ms), 3 length (ms) } }
    static func parseIndex(_ data: Data) -> [String: Placement] {
        var result: [String: Placement] = [:]
        for timeline in ProtoReader(data).messages(field: 1) {
            guard let id = timeline.string(field: 1) else { continue }
            for recording in timeline.messages(field: 5) {
                guard let folder = recording.string(field: 1) else { continue }
                result[folder] = Placement(timelineID: id, offset: Double(recording.varint(field: 2) ?? 0))
            }
        }
        return result
    }

    private static let cache = FileCache<[String: Placement]>()

    // MARK: - timelines/<id>.json

    /// A session's recordings share one timeline, so parse it once per change.
    static func timeline(at url: URL) -> Timeline? {
        timelineCache.value(for: url) { Timeline(contentsOf: url) }
    }

    private static let timelineCache = FileCache<Timeline?>()

    struct Timeline {
        struct Entry {
            let time: Double          // ms from the timeline start
            let duration: Double?     // ms, for events that span time
            let title: String
        }

        let start: Double
        let entries: [Entry]

        init?(contentsOf url: URL) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            self.init(data: data)
        }

        /// A game state held for less than this ("Loading...") is not a chapter.
        static let minimumStateLength: Double = 5_000

        /// Steam writes numbers as strings ("429813"). Entry types, as seen in
        /// Left 4 Dead 2 and Half-Life 2 timelines:
        ///
        ///   event              a game's marker: title, optional description
        ///   screenshot         a screenshot taken in the session
        ///   state_description  what the game is doing ("Dead Center - 1: Hotel",
        ///                      "Loading..."), in effect until the next one
        ///   gamemode, phase    playing/menus flags and chapter ranges; the
        ///                      games also add an event for each chapter
        ///   error              Steam's own failures ("#GameRecording_RecordingFailed")
        init?(data: Data) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            start = Self.number(json["starttime"]) ?? 0
            let end = Self.number(json["endtime"]) ?? .infinity
            let raw = (json["entries"] as? [[String: Any]] ?? [])
                .compactMap { entry in Self.number(entry["time"]).map { (time: $0, entry: entry) } }
                .sorted { $0.time < $1.time }

            var entries: [Entry] = []
            var lastState: String?
            for (i, (time, entry)) in raw.enumerated() {
                switch entry["type"] as? String ?? "" {
                case "error", "gamemode", "phase":
                    continue
                case "screenshot":
                    entries.append(Entry(time: time, duration: nil, title: "Screenshot"))
                case "state_description":
                    guard let state = Self.text(entry["title"]), state != lastState else { continue }
                    let next = raw[(i + 1)...].first { $0.entry["type"] as? String == "state_description" }?.time ?? end
                    guard next - time >= Self.minimumStateLength else { continue }
                    lastState = state
                    // Half-Life 2 names each chapter in an event a second
                    // before the state: "New Chapter: POINT INSERTION".
                    if let previous = entries.last, time - previous.time < Self.minimumStateLength,
                       previous.title.localizedCaseInsensitiveContains(state) { continue }
                    entries.append(Entry(time: time, duration: nil, title: state))
                default:
                    // "Achievement Progress: Lambda Locator (1/45)"
                    let parts = [entry["title"], entry["description"]].compactMap(Self.text)
                    guard !parts.isEmpty else { continue }
                    entries.append(Entry(time: time, duration: Self.number(entry["duration"]),
                                         title: parts.joined(separator: ": ")))
                }
            }
            self.entries = entries
        }

        private static func number(_ value: Any?) -> Double? {
            switch value {
            case let n as NSNumber: return n.doubleValue
            case let s as String: return Double(s)
            default: return nil
            }
        }

        /// Readable single-line text, or nil if there is none. Games pad their
        /// strings ("Rise and shine. "), and chapter titles are one line.
        private static func text(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let words = string.split(whereSeparator: \.isWhitespace)
            return words.isEmpty ? nil : SteamTimeline.readable(words.joined(separator: " "))
        }
    }

    /// Steam stores its own strings as localization tokens. Turn
    /// "#GameRecording_UserMarker" into "User marker"; leave real text alone.
    static func readable(_ text: String) -> String {
        guard text.hasPrefix("#") else { return text }
        let token = text.dropFirst().split(separator: "_").last.map(String.init) ?? String(text.dropFirst())
        var words: [String] = []
        for character in token {
            if character.isUppercase || words.isEmpty { words.append(String(character)) }
            else { words[words.count - 1].append(character) }
        }
        let sentence = words.joined(separator: " ").lowercased()
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
}

/// Just enough protobuf to walk Steam's index: varints, and length-delimited
/// fields read as strings or nested messages. Unknown fields are skipped.
struct ProtoReader {
    private var fields: [(number: Int, varint: UInt64?, bytes: Data?)] = []

    init(_ data: Data) {
        let bytes = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.count, shift < 64 {
                let byte = bytes[i]; i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < bytes.count, let key = varint() {
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return }
                fields.append((number, value, nil))
            case 1:
                guard bytes.count - i >= 8 else { return }
                i += 8
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - i) else { return }
                fields.append((number, nil, Data(bytes[i..<i + Int(length)])))
                i += Int(length)
            case 5:
                guard bytes.count - i >= 4 else { return }
                i += 4
            default: return   // groups and anything else: stop rather than misread
            }
        }
    }

    func varint(field: Int) -> UInt64? { fields.first { $0.number == field }?.varint }

    func string(field: Int) -> String? {
        fields.first { $0.number == field }?.bytes.flatMap { String(data: $0, encoding: .utf8) }
    }

    func messages(field: Int) -> [ProtoReader] {
        fields.filter { $0.number == field }.compactMap { $0.bytes.map(ProtoReader.init) }
    }
}

/// Parses a file once per modification date, so a rescan picks up changes
/// without re-reading an unchanged index for every clip.
final class FileCache<Value>: @unchecked Sendable {
    private var entries: [URL: (modified: Date?, value: Value)] = [:]
    private let lock = NSLock()

    func value(for url: URL, load: () -> Value) -> Value {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lock.lock(); defer { lock.unlock() }
        if let hit = entries[url], hit.modified == modified { return hit.value }
        let value = load()
        entries[url] = (modified, value)
        return value
    }
}
