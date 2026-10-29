import AVFoundation

/// Converts a video file that isn't a Steam recording - typically an OBS
/// capture (.mkv) - into a .mov or .mp4, copying the streams as they are and,
/// for 3D, adding the stereo tag YouTube reads.
enum VideoFileConverter {

    /// What the open panel accepts. Matroska goes through MatroskaRemuxer;
    /// the rest are files AVFoundation already opens.
    static let fileExtensions = ["mkv", "mp4", "mov", "m4v"]

    struct Output {
        var url: URL
        var bytes: Int64
        var layout: StereoLayout
        /// Something the user should know that didn't stop the conversion.
        var note: String?
    }

    enum ConvertError: LocalizedError {
        case exportUnavailable, unsupported(String)
        var errorDescription: String? {
            switch self {
            case .exportUnavailable: return "Could not create a passthrough export session."
            case .unsupported(let ext): return "\(ext) files aren't supported."
            }
        }
    }

    /// The layout a file declares about itself: its name first, then
    /// Matroska's StereoMode. Name first because it is what the airGPU
    /// toolkit and most 3D tools write, and the user can see and fix it.
    static func declaredLayout(of file: URL, matroska: MatroskaFile?) -> StereoLayout? {
        StereoLayout.detect(fromFileName: file.lastPathComponent) ?? matroska?.declaredStereoLayout
    }

    /// "Game - 2026-10-28 19-59-40.3D.HSBS" for a 3D output, the plain stem for 2D.
    static func outputStem(for file: URL, layout: StereoLayout) -> String {
        let base = StereoLayout.stripTags(from: file.deletingPathExtension().lastPathComponent)
        return layout.fileTag.map { "\(base).\($0)" } ?? base
    }

    static func convert(file: URL,
                        to folder: URL,
                        container: ClipConverter.Container,
                        stereo: StereoChoice,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        let ext = file.pathExtension.lowercased()
        guard fileExtensions.contains(ext) else { throw ConvertError.unsupported(".\(ext)") }
        let matroska = ext == "mkv" ? try MatroskaFile(url: file) : nil
        let layout = stereo.resolve(detected: declaredLayout(of: file, matroska: matroska))

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = ClipConverter.uniqueDestination(in: folder, stem: outputStem(for: file, layout: layout),
                                                          ext: container.ext)
        let metadata = metadata(title: destination.deletingPathExtension().lastPathComponent)

        var note: String?
        if let matroska {
            let result = try await MatroskaRemuxer.remux(matroska, to: destination, fileType: container.fileType,
                                                         metadata: metadata) { progress($0 * 0.95) }
            note = result.skippedAudio.map { "\(file.lastPathComponent): no sound, because \($0)." }
        } else {
            let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw ConvertError.exportUnavailable
            }
            session.metadata = metadata
            let poll = Task {
                while !Task.isCancelled {
                    progress(Double(session.progress) * 0.95)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { poll.cancel() }
            try await session.export(to: destination, as: container.fileType)
        }

        try ClipConverter.tagOrDiscard(destination, stereo: layout)
        progress(1)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        return Output(url: destination, bytes: bytes, layout: layout, note: note)
    }

    private static func metadata(title: String) -> [AVMetadataItem] {
        [(AVMetadataKey.commonKeyTitle, title), (.commonKeySoftware, "Steam Clip Converter for Mac")].map { key, value in
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = key as NSString
            item.value = value as NSString
            return item
        }
    }
}
