import Foundation

/// How a recording packs two eyes into one frame. Only the packing a player
/// can split is modelled: left eye first, each eye squeezed to half the frame,
/// which is what ReShade's SuperDepth3D and most "3D SBS" game modes produce.
enum StereoLayout: String, CaseIterable, Identifiable {
    case flat
    case sideBySide
    case topBottom

    var id: String { rawValue }

    /// The `stereo_mode` byte of Google's `st3d` box, which is what YouTube
    /// reads to play an upload in 3D (its "Upload 3D videos" help page).
    var st3dMode: UInt8 {
        switch self {
        case .flat: return 0
        case .topBottom: return 1
        case .sideBySide: return 2
        }
    }

    /// Kodi's filename convention for half-resolution 3D, also written by the
    /// airGPU toolkit's recorder. Players that don't read `st3d` (most Quest
    /// video players, Kodi itself) go by the name instead.
    var fileTag: String? {
        switch self {
        case .flat: return nil
        case .sideBySide: return "3D.HSBS"
        case .topBottom: return "3D.HTAB"
        }
    }

    var label: String {
        switch self {
        case .flat: return "2D"
        case .sideBySide: return "3D side-by-side"
        case .topBottom: return "3D top-and-bottom"
        }
    }

    /// Reads the layout from a file name's tokens, e.g. "Game.3D.HSBS.mkv",
    /// "clip_SBS.mp4" or "movie.3D.HOU.mkv" (bare "OU" is too common a word
    /// to count, and bare "TAB" counts only with "3D"). Tokens are separated by
    /// `. _ - ` or a space, as in Kodi's own matching, so "SBS" inside a word
    /// never counts. Returns nil when the name says nothing about 3D.
    static func detect(fromFileName name: String) -> StereoLayout? {
        let stem = (name as NSString).deletingPathExtension
        let tokens = Set(stem.lowercased()
            .split(whereSeparator: { ".-_ ".contains($0) })
            .map(String.init))
        if !tokens.isDisjoint(with: ["sbs", "hsbs", "fsbs"]) { return .sideBySide }
        if !tokens.isDisjoint(with: ["htab", "ftab", "hou"]) { return .topBottom }
        // "Tab" is an ordinary word ("Tab menu tutorial"), so on its own it
        // only counts next to an explicit 3D.
        if tokens.contains("tab"), tokens.contains("3d") { return .topBottom }
        return nil
    }

    /// The file name stem with any 3D tokens this type recognises removed, so
    /// re-tagging "x.3D.HSBS" gives "x.3D.HSBS", not "x.3D.HSBS.3D.HSBS".
    static func stripTags(from stem: String) -> String {
        let pattern = #"(?i)([. _-](3d|h?sbs|fsbs|h?tab|ftab|hou))+$"#
        return stem.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    /// The name for an output in this layout: "<stem>.3D.HSBS" or "<stem>".
    func outputStem(for stem: String) -> String {
        guard let tag = fileTag else { return stem }
        return "\(Self.stripTags(from: stem)).\(tag)"
    }
}

/// The user's choice in the export bar. `automatic` reads the layout from the
/// file (its name, or Matroska's StereoMode) and treats Steam clips as 2D,
/// since Steam records no such hint.
enum StereoChoice: String, CaseIterable, Identifiable {
    case automatic
    case flat
    case sideBySide
    case topBottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Detect from file"
        case .flat: return StereoLayout.flat.label
        case .sideBySide: return StereoLayout.sideBySide.label
        case .topBottom: return StereoLayout.topBottom.label
        }
    }

    /// The layout to write, given what the file itself says (nil = nothing).
    func resolve(detected: StereoLayout?) -> StereoLayout {
        switch self {
        case .automatic: return detected ?? .flat
        case .flat: return .flat
        case .sideBySide: return .sideBySide
        case .topBottom: return .topBottom
        }
    }
}
