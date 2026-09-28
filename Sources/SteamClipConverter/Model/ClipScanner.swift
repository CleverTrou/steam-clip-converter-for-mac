import Foundation

/// Scans a folder of Steam recordings. Deliberately cheap: it reads only
/// `session.mpd` and the directory listing, so a library of hundreds of clips
/// appears instantly. Real stream parameters and thumbnails are filled in later,
/// per clip, by MediaProbe.
enum ClipScanner {

    static func scan(root: URL) -> [Clip] {
        let fm = FileManager.default
        var results: [Clip] = []

        // Accept either a folder of clip folders, or a Steam-style tree
        // (<userdata>/<id>/gamerecordings/{clips,video}) if one is handed to us.
        for dir in candidateDirectories(root: root) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if let clip = makeClip(folder: entry, kind: dir.lastPathComponent == "clips" ? .manual : .background) {
                    results.append(clip)
                }
            }
        }
        return results.sorted { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
    }

    private static func candidateDirectories(root: URL) -> [URL] {
        let fm = FileManager.default
        var dirs = [root]
        // If the user pointed at a Steam userdata tree, dig out the recording dirs.
        if let userIDs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for user in userIDs where user.lastPathComponent.allSatisfy(\.isNumber) {
                for sub in ["video", "clips"] {
                    let candidate = user.appending(path: "gamerecordings").appending(path: sub)
                    if fm.fileExists(atPath: candidate.path) { dirs.append(candidate) }
                }
            }
        }
        for sub in ["video", "clips"] {
            let candidate = root.appending(path: sub)
            if fm.fileExists(atPath: candidate.path) { dirs.append(candidate) }
        }
        return dirs
    }

    static func makeClip(folder: URL, kind: Clip.Kind) -> Clip? {
        let fm = FileManager.default
        let mpd = folder.appending(path: "session.mpd")
        guard fm.fileExists(atPath: mpd.path) else { return nil }

        let manifest = MPD(contentsOf: mpd)
        let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let videoSegments = files.filter { $0.hasPrefix("chunk-stream0-") }.count
        var bytes: Int64 = 0
        for f in files {
            let attrs = try? fm.attributesOfItem(atPath: folder.appending(path: f).path)
            bytes += (attrs?[.size] as? Int64) ?? 0
        }

        let name = folder.lastPathComponent
        let parts = name.split(separator: "_").map(String.init)
        // bg_<appid>_<yyyyMMdd>_<HHmmss>[_n]
        let appID = parts.count > 1 ? parts[1] : "unknown"
        var recordedAt: Date?
        if parts.count > 3 {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd HHmmss"
            recordedAt = f.date(from: "\(parts[2]) \(parts[3])")
        }

        var clip = Clip(
            id: name,
            url: folder,
            appID: appID,
            recordedAt: recordedAt,
            kind: kind,
            duration: manifest?.duration ?? 0,
            segmentDuration: manifest?.segmentDuration ?? 3,
            videoSegmentCount: max(videoSegments, 1),
            byteSize: bytes,
            probe: nil,
            gameName: nil
        )
        clip.markers = SteamTimeline.markers(for: clip)
        return clip
    }
}

/// Minimal DASH manifest reader -- we only need timing. Codec and resolution
/// attributes in Steam's manifests are placeholders and must not be trusted.
struct MPD {
    var duration: Double
    var segmentDuration: Double

    init?(contentsOf url: URL) {
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        duration = Self.iso8601Duration(Self.attribute("mediaPresentationDuration", in: xml) ?? "") ?? 0
        if let ts = Self.attribute("timescale", in: xml).flatMap(Double.init),
           let dur = Self.attribute("duration", in: xml).flatMap(Double.init), ts > 0 {
            segmentDuration = dur / ts
        } else {
            segmentDuration = 3
        }
    }

    private static func attribute(_ name: String, in xml: String) -> String? {
        guard let r = xml.range(of: "\(name)=\"") else { return nil }
        let rest = xml[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// "PT3M17.993S" -> 197.993
    static func iso8601Duration(_ s: String) -> Double? {
        guard s.hasPrefix("PT") else { return nil }
        var total = 0.0, number = ""
        for ch in s.dropFirst(2) {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            let value = Double(number) ?? 0
            switch ch {
            case "H": total += value * 3600
            case "M": total += value * 60
            case "S": total += value
            default: break
            }
            number = ""
        }
        return total
    }
}
