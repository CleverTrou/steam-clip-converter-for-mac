import Foundation

/// Finds where Steam keeps recordings, and resolves app IDs to game names.
enum SteamLocator {

    /// Steam's own default recording locations, plus any custom path the user set
    /// inside Steam itself.
    static func suggestedRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots: [URL] = []

        let userdataCandidates = [
            home.appending(path: "Library/Application Support/Steam/userdata"),
            home.appending(path: ".steam/steam/userdata"),
            home.appending(path: ".local/share/Steam/userdata"),
        ]

        for userdata in userdataCandidates where fm.fileExists(atPath: userdata.path) {
            guard let users = try? fm.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil) else { continue }
            for user in users where user.lastPathComponent.allSatisfy(\.isNumber) {
                let recordings = user.appending(path: "gamerecordings")
                if fm.fileExists(atPath: recordings.path) { roots.append(recordings) }
                // Steam stores a user-chosen recording folder in localconfig.vdf.
                if let custom = backgroundRecordPath(userDir: user) { roots.append(custom) }
            }
        }
        return roots
    }

    /// Pulls `"BackgroundRecordPath"  "<path>"` out of localconfig.vdf.
    static func backgroundRecordPath(userDir: URL) -> URL? {
        let vdf = userDir.appending(path: "config/localconfig.vdf")
        guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("\"BackgroundRecordPath\"") {
            let parts = line.components(separatedBy: "\"").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if let path = parts.last, path != "BackgroundRecordPath", !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

/// App ID -> game name, cached on disk so the grid fills in instantly on
/// relaunch and works offline.
actor GameCatalog {
    static let shared = GameCatalog()

    private var names: [String: String] = [:]
    private var inFlight: Set<String> = []
    private let cacheURL: URL

    init() {
        cacheURL = SupportDirectory.url.appending(path: "GameNames.json")
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            names = decoded
        }
    }

    func cachedName(for appID: String) -> String? { names[appID] }

    func name(for appID: String) async -> String? {
        if let hit = names[appID] { return hit }
        // ASCII digits only: `isNumber` alone also accepts "½" or "٣", which have
        // no business in a query string built from a folder name.
        guard !inFlight.contains(appID), !appID.isEmpty,
              appID.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        inFlight.insert(appID)
        defer { inFlight.remove(appID) }

        var request = URLRequest(url: URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=basic")!)
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json[appID] as? [String: Any],
              entry["success"] as? Bool == true,
              let payload = entry["data"] as? [String: Any],
              let name = payload["name"] as? String
        else { return nil }

        names[appID] = name
        persist()
        return name
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(names) { try? data.write(to: cacheURL) }
    }
}
