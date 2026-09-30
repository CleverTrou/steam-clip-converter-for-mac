import Foundation

/// Remembers which recordings have already been converted, and where the result
/// went. Persisted, so the marking survives relaunch -- a converted clip should
/// never look like an unconverted one just because the app restarted.
struct ConversionRecord: Codable, Hashable {
    var clipID: String
    var outputPath: String
    var convertedAt: Date
    var format: String

    var outputURL: URL { URL(fileURLWithPath: outputPath) }
    var stillExists: Bool { FileManager.default.fileExists(atPath: outputPath) }

    var label: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Converted \(f.string(from: convertedAt))"
    }
}

enum ConversionStore {
    private static var url: URL { SupportDirectory.url.appending(path: "Conversions.json") }

    static func load() -> [String: ConversionRecord] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: ConversionRecord].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ records: [String: ConversionRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url)
    }

    /// Finds outputs produced by earlier runs -- including before this ledger
    /// existed -- by matching each clip's expected filename in the destination.
    static func adopt(clips: [Clip], outputFolder: URL, into records: inout [String: ConversionRecord]) {
        let fm = FileManager.default
        let extensions = ["mov", "mp4", "m4v"]
        let existing = (try? fm.contentsOfDirectory(at: outputFolder, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { extensions.contains($0.pathExtension.lowercased()) } ?? []
        guard !existing.isEmpty else { return }

        for clip in clips where records[clip.id] == nil {
            // Exact name first -- anything this app produced.
            var match = existing.first { $0.deletingPathExtension().lastPathComponent == clip.outputStem }

            // Then a timestamp match, so exports made by other tools (or earlier
            // naming schemes) are recognised too. Every Steam recording carries a
            // unique capture time, so comparing digit-only forms is unambiguous:
            // "SteamVR_2026-08-16_16-31-03.mp4" -> "202608161631034" contains
            // "20260816163103".
            // The folder's own digits, not local time: other tools name files
            // from the folder, and so did this app before it read them as UTC.
            if match == nil, let recordedAt = clip.recordedAt {
                let stamp = Clip.folderDateFormatter.string(from: recordedAt).filter(\.isNumber)
                match = existing.first { url in
                    url.lastPathComponent.filter(\.isNumber).contains(stamp)
                }
            }

            guard let match else { continue }
            let modified = (try? match.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            records[clip.id] = ConversionRecord(clipID: clip.id,
                                                outputPath: match.path,
                                                convertedAt: modified,
                                                format: match.pathExtension.uppercased())
        }
    }
}
