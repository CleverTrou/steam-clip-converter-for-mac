import Foundation

/// One Steam recording folder: `bg_<appID>_<yyyyMMdd>_<HHmmss>[_n]` containing
/// `session.mpd`, `init-stream*.m4s` and numbered `chunk-stream*.m4s` segments.
struct Clip: Identifiable, Hashable {
    let id: String                  // folder name, unique within a library
    let url: URL
    let appID: String
    let recordedAt: Date?
    let kind: Kind

    // From session.mpd -- cheap, no decoding.
    let duration: Double
    let segmentDuration: Double
    let videoSegmentCount: Int
    let byteSize: Int64

    // Filled in lazily by MediaProbe: the MPD lies about these.
    var probe: ProbeResult?
    var gameName: String?

    /// Events from Steam's timeline that fall inside this clip. Exported as
    /// chapters.
    var markers: [ClipMarker] = []

    enum Kind: String, Hashable {
        case background = "Background Recording"
        case manual = "Manual Clip"
    }

    var displayName: String { gameName ?? "App \(appID)" }

    var resolutionLabel: String {
        guard let p = probe else { return "--" }
        return "\(p.width)x\(p.height)"
    }

    /// 2160p / 1440p / 1080p style label, used for filtering.
    var qualityBucket: String {
        guard let p = probe else { return "Unknown" }
        switch p.height {
        case 2000...: return "4K"
        case 1400..<2000: return "1440p"
        case 1000..<1400: return "1080p"
        case 600..<1000: return "720p"
        default: return "Low-res"
        }
    }

    /// "Aug 16, 2026 at 4:31 PM" -- shown on every card.
    var dateLabel: String {
        guard let recordedAt else { return "Date unknown" }
        return Self.dateFormatter.string(from: recordedAt)
    }

    /// Compact form for tight layouts: "Aug 16, 4:31 PM".
    var shortDateLabel: String {
        guard let recordedAt else { return "Date unknown" }
        return Self.shortDateFormatter.string(from: recordedAt)
    }

    /// The `<yyyyMMdd>_<HHmmss>` in a folder name. Steam writes it in UTC
    /// whatever the PC's time zone, matching the timeline's unix start time.
    static let folderDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return f
    }()

    var durationLabel: String {
        let total = Int(duration.rounded())
        let (m, s) = (total / 60, total % 60)
        return m > 0 ? String(format: "%d:%02d", m, s) : String(format: "0:%02d", s)
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    /// Suggested output filename stem, e.g. "SteamVR 2026-08-16 16-31-33".
    var outputStem: String {
        let stamp: String
        if let recordedAt {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH-mm-ss"
            stamp = f.string(from: recordedAt)
        } else {
            stamp = id
        }
        let safe = displayName.replacingOccurrences(of: "/", with: "-")
                              .replacingOccurrences(of: ":", with: "-")
        return "\(safe) \(stamp)"
    }
}

/// Real stream parameters, read from the assembled init segment rather than the
/// MPD -- Steam's manifests claim avc1/256x256 even for 4K HEVC captures.
struct ProbeResult: Hashable {
    var width: Int
    var height: Int
    var fps: Double
    var videoCodec: String      // fourcc, e.g. hvc1 / avc1
    var hasAudio: Bool
    var audioSampleRate: Double
    var audioChannels: Int
    var isHEVC: Bool { videoCodec.lowercased().hasPrefix("hvc") || videoCodec.lowercased().hasPrefix("hev") }
}
