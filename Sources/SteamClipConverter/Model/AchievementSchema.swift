import Foundation

/// Achievement API name ("HL2_GET_CROWBAR") -> display name ("Trusty Hardware"),
/// from the schema Steam caches for each game whose stats it has loaded:
///
///     ~/Library/Application Support/Steam/appcache/stats/UserGameStatsSchema_<appid>.bin
///
/// A game recorded on another PC may have none on this Mac, and then markers
/// fall back to the API name.
enum AchievementSchema {

    static var directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Steam/appcache/stats")

    static func names(appID: String) -> [String: String] {
        guard !appID.isEmpty, appID.allSatisfy({ $0.isASCII && $0.isNumber }) else { return [:] }
        let url = directory.appending(path: "UserGameStatsSchema_\(appID).bin")
        return cache.value(for: url) {
            (try? Data(contentsOf: url)).map(parse) ?? [:]
        }
    }

    private static let cache = FileCache<[String: String]>()

    /// Layout, read from real files (Valve publishes no schema):
    ///   <appid> { stats { <n> { bits { <n> { name, display { name { english } } } } } } }
    static func parse(_ data: Data) -> [String: String] {
        var names: [String: String] = [:]
        func collect(_ node: BinaryKeyValues) {
            if let api = node.strings["name"],
               let display = node.sections["display"]?.sections["name"]?.strings["english"]?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !display.isEmpty {   // a blank name would title the marker "Achievement: "
                names[api] = display
            }
            node.sections.values.forEach(collect)
        }
        collect(BinaryKeyValues(data))
        return names
    }
}

/// Just enough of Valve's binary KeyValues to read an achievement schema:
/// nested sections and strings. Numbers are skipped; a truncated or unknown
/// value ends the read, keeping what came before it.
struct BinaryKeyValues {
    var strings: [String: String] = [:]
    var sections: [String: BinaryKeyValues] = [:]

    init(_ data: Data) {
        let bytes = [UInt8](data)
        var i = 0
        self = Self.section(bytes, &i, depth: 0)
    }

    private init() {}

    private static func section(_ bytes: [UInt8], _ i: inout Int, depth: Int) -> BinaryKeyValues {
        var node = BinaryKeyValues()
        while i < bytes.count {
            let type = bytes[i]; i += 1
            if type == 8 || type == 11 { break }   // end of section
            guard let key = cString(bytes, &i) else { break }
            switch type {
            case 0:
                guard depth < 32 else { return node }
                node.sections[key] = section(bytes, &i, depth: depth + 1)
            case 1:
                guard let value = cString(bytes, &i) else { return node }
                node.strings[key] = value
            case 2, 3, 4, 6: i += 4   // int32, float, pointer, color
            case 7, 10: i += 8        // uint64, int64
            default: return node      // wide strings and anything else: stop rather than misread
            }
        }
        return node
    }

    private static func cString(_ bytes: [UInt8], _ i: inout Int) -> String? {
        guard let end = bytes[i...].firstIndex(of: 0) else { return nil }
        defer { i = end + 1 }
        return String(decoding: bytes[i..<end], as: UTF8.self)
    }
}
