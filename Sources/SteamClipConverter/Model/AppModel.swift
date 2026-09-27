import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    var libraryRoot: URL? { didSet { persistRoot(); reload() } }
    var clips: [Clip] = []
    var isScanning = false

    // Filters
    var search = ""
    var gameFilter: String? = nil
    var qualityFilter: String? = nil
    var sort: SortOrder = .newest

    var selection: Set<Clip.ID> = []

    // Conversion
    var outputFolder: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appending(path: "Steam Recordings")
    var container: ClipConverter.Container = .mov
    var isConverting = false
    /// clip.id -> where its converted file landed. Persisted across launches.
    var conversions: [String: ConversionRecord] = ConversionStore.load()
    var statusFilter: StatusFilter? = nil
    var conversionLabel = ""
    var conversionProgress = 0.0
    var lastResult: String?

    enum StatusFilter: String, CaseIterable, Identifiable {
        case converted = "Already Converted"
        case pending = "Not Yet Converted"
        var id: String { rawValue }
    }

    /// Paired opposites so every criterion can be read in both directions.
    enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest First"
        case oldest = "Oldest First"
        case longest = "Longest Duration"
        case shortest = "Shortest Duration"
        case largest = "Largest File"
        case smallest = "Smallest File"

        var id: String { rawValue }

        enum Criterion: String, CaseIterable { case date = "Date", duration = "Duration", size = "File Size" }

        var criterion: Criterion {
            switch self {
            case .newest, .oldest: return .date
            case .longest, .shortest: return .duration
            case .largest, .smallest: return .size
            }
        }

        static func options(for criterion: Criterion) -> [SortOrder] {
            allCases.filter { $0.criterion == criterion }
        }
    }

    /// Steam locations are resolved once -- probing the filesystem inside a view
    /// body would re-scan on every redraw.
    private(set) var steamRoots: [URL] = SteamLocator.suggestedRoots()

    func refreshSteamRoots() { steamRoots = SteamLocator.suggestedRoots() }

    private let rootKey = "SteamClipConverter.libraryRoot"

    init() {
        if let saved = UserDefaults.standard.string(forKey: rootKey) {
            libraryRoot = URL(fileURLWithPath: saved)
        } else if let inherited = SupportDirectory.legacyLibraryRoot() {
            libraryRoot = inherited
        } else {
            libraryRoot = SteamLocator.suggestedRoots().first
        }
    }

    // MARK: - Library

    private func persistRoot() {
        UserDefaults.standard.set(libraryRoot?.path, forKey: rootKey)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder of Steam recordings (or a Steam userdata folder)."
        if panel.runModal() == .OK, let url = panel.url { libraryRoot = url }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export Here"
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            adoptExistingOutputs()
        }
    }

    func reload() {
        guard let root = libraryRoot else { clips = []; return }
        isScanning = true
        Task {
            let found = await Task.detached { ClipScanner.scan(root: root) }.value
            clips = found
            isScanning = false
            await enrich()
        }
    }

    /// Fills in game names and true stream parameters after the fast scan.
    private func enrich() async {
        for clip in clips {
            if let cached = await GameCatalog.shared.cachedName(for: clip.appID) {
                apply(gameName: cached, to: clip.id)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            let appIDs = Set(clips.map(\.appID))
            for appID in appIDs {
                group.addTask { [weak self] in
                    guard let name = await GameCatalog.shared.name(for: appID) else { return }
                    await self?.applyGameName(name, appID: appID)
                }
            }
        }
        // Probe sequentially: each one assembles a segment, and hammering a
        // OneDrive-backed folder in parallel just queues downloads.
        for clip in clips {
            guard let result = await MediaProbe.shared.probe(clip) else { continue }
            apply(probe: result, to: clip.id)
        }
        adoptExistingOutputs()
    }

    private func applyGameName(_ name: String, appID: String) {
        for index in clips.indices where clips[index].appID == appID {
            clips[index].gameName = name
        }
    }

    private func apply(gameName: String, to id: Clip.ID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].gameName = gameName
    }

    private func apply(probe: ProbeResult, to id: Clip.ID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].probe = probe
    }

    // MARK: - Filtering

    var games: [String] {
        Array(Set(clips.map(\.displayName))).sorted()
    }

    var qualities: [String] {
        Array(Set(clips.map(\.qualityBucket))).sorted()
    }

    var visibleClips: [Clip] {
        var result = clips
        if !search.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(search) ||
                $0.appID.contains(search) ||
                $0.id.localizedCaseInsensitiveContains(search)
            }
        }
        if let gameFilter { result = result.filter { $0.displayName == gameFilter } }
        if let qualityFilter { result = result.filter { $0.qualityBucket == qualityFilter } }
        if let statusFilter {
            result = result.filter { (conversions[$0.id] != nil) == (statusFilter == .converted) }
        }
        switch sort {
        case .newest: result.sort { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
        case .oldest: result.sort { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
        case .longest: result.sort { $0.duration > $1.duration }
        case .shortest: result.sort { $0.duration < $1.duration }
        case .largest: result.sort { $0.byteSize > $1.byteSize }
        case .smallest: result.sort { $0.byteSize < $1.byteSize }
        }
        return result
    }

    /// Combined size of what's currently on screen.
    var visibleBytes: Int64 { visibleClips.reduce(0) { $0 + $1.byteSize } }

    var selectedBytes: Int64 { selectedClips.reduce(0) { $0 + $1.byteSize } }

    var selectedClips: [Clip] { visibleClips.filter { selection.contains($0.id) } }

    // MARK: - Conversion

    func convertSelected() {
        let targets = selectedClips.isEmpty ? visibleClips : selectedClips
        guard !targets.isEmpty, !isConverting else { return }
        isConverting = true
        lastResult = nil
        let folder = outputFolder
        let container = self.container

        Task {
            var succeeded = 0
            var totalBytes: Int64 = 0
            var failures: [String] = []
            for (index, clip) in targets.enumerated() {
                conversionLabel = "Converting \(index + 1) of \(targets.count): \(clip.displayName)"
                conversionProgress = 0
                do {
                    let output = try await ClipConverter.convert(clip: clip, to: folder, container: container) { value in
                        Task { @MainActor in self.conversionProgress = value }
                    }
                    succeeded += 1
                    totalBytes += output.bytes
                    conversions[clip.id] = ConversionRecord(clipID: clip.id,
                                                           outputPath: output.url.path,
                                                           convertedAt: Date(),
                                                           format: container.ext.uppercased())
                    ConversionStore.save(conversions)
                } catch {
                    failures.append("\(clip.id): \(error.localizedDescription)")
                }
            }
            isConverting = false
            conversionLabel = ""
            conversionProgress = 0
            let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            let result = failures.isEmpty
                ? "Exported \(succeeded) clip\(succeeded == 1 ? "" : "s") (\(size)) to \(folder.lastPathComponent)."
                : "Exported \(succeeded), failed \(failures.count). \(failures.joined(separator: "; "))"
            lastResult = result
            // The result appears in the export bar without taking focus, so a
            // VoiceOver user would otherwise never hear that the batch finished.
            AccessibilityNotification.Announcement(result).post()
        }
    }

    /// Marks clips whose output is already sitting in the destination -- including
    /// files converted before this app existed -- and drops records whose file has
    /// since been moved or deleted.
    func adoptExistingOutputs() {
        var records = conversions
        for (id, record) in records where !record.stillExists { records.removeValue(forKey: id) }
        ConversionStore.adopt(clips: clips, outputFolder: outputFolder, into: &records)
        if records != conversions {
            conversions = records
            ConversionStore.save(records)
        }
    }

    func record(for clip: Clip) -> ConversionRecord? { conversions[clip.id] }

    func forgetConversion(_ clip: Clip) {
        conversions.removeValue(forKey: clip.id)
        ConversionStore.save(conversions)
    }

    var convertedCount: Int { clips.filter { conversions[$0.id] != nil }.count }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealOutput() {
        NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
    }
}
