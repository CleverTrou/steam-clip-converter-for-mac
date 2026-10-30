import Foundation

/// How a Steam recording packs two eyes into one frame. Steam records what the
/// game shows, so a game run in side-by-side 3D (ReShade's SuperDepth3D, or a
/// game's own 3D mode) makes a side-by-side clip. Only the packing a player
/// can split is modelled: left eye first, each eye squeezed to half the frame.
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

    /// Kodi's filename convention for half-resolution 3D. Players that don't
    /// read `st3d` (most Quest video players, Kodi itself) go by the name.
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

    /// Reads a 3D layout from a file name's tokens, e.g. "Game.3D.HSBS.mov" or
    /// "clip_SBS.mp4". Steam's own folder names carry none; this is how
    /// `stripTags`, and so the converted-file check, recognise exported names.
    /// Tokens are separated by `. _ - ` or a space, as in Kodi's matching, so
    /// "SBS" inside a word never counts; a bare "OU" never counts and a bare
    /// "TAB" only next to "3D", as both are ordinary words. Returns nil when
    /// the name says nothing about 3D.
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
    /// Exactly one trailing tag - a layout token with an optional "3D" before
    /// it - and only if `detect` reads it as 3D. So "Super Mario 3D" and
    /// "Game - Tab" keep their last word, and so does "Super Mario 3D.3D.HSBS".
    static func stripTags(from stem: String) -> String {
        let pattern = #"(?i)[. _-](3d[. _-])?(h?sbs|fsbs|h?tab|ftab|hou)$"#
        guard let range = stem.range(of: pattern, options: .regularExpression),
              detect(fromFileName: String(stem[range]) + ".x") != nil else { return stem }
        return String(stem[..<range.lowerBound])
    }

    /// The name for an output in this layout: "<stem>.3D.HSBS" or "<stem>".
    func outputStem(for stem: String) -> String {
        guard let tag = fileTag else { return stem }
        return "\(Self.stripTags(from: stem)).\(tag)"
    }
}
