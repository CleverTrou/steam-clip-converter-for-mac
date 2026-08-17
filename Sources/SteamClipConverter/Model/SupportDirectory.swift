import Foundation

/// The app's Application Support folder, resolved once.
///
/// Also migrates the folder used before the app was renamed, so the conversion
/// ledger and the cached game-name database survive the rename instead of
/// silently resetting.
enum SupportDirectory {
    static let legacyName = "SteamClipMac"
    static let legacyBundleID = "com.trevornelson.steamclipmac"
    static let legacyRootKey = "SteamClipMac.libraryRoot"

    static let url: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appending(path: "Steam Clip Converter")
        let legacy = base.appending(path: legacyName)

        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }()

    /// The recordings folder chosen under the previous bundle identifier.
    /// UserDefaults are keyed per bundle ID, so the rename would otherwise look
    /// like a first run.
    static func legacyLibraryRoot() -> URL? {
        guard let defaults = UserDefaults(suiteName: legacyBundleID),
              let path = defaults.string(forKey: legacyRootKey),
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
