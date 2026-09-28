import AVFoundation

/// Remuxes a Steam recording into a Mac-native container. Passthrough only --
/// the bitstream is copied, never re-encoded, so a 500 MB 4K clip converts in
/// about a second and loses nothing.
enum ClipConverter {

    enum Container: String, CaseIterable, Identifiable {
        case mov = "QuickTime (.mov)"
        case mp4 = "MPEG-4 (.mp4)"
        var id: String { rawValue }
        var fileType: AVFileType { self == .mov ? .mov : .mp4 }
        var ext: String { self == .mov ? "mov" : "mp4" }
        /// .mov round-trips every metadata field; .mp4 silently drops some.
        var keepsAllMetadata: Bool { self == .mov }
        /// QuickTime text chapter tracks are native to .mov.
        var supportsChapters: Bool { self == .mov }
    }

    /// One chapter per timeline event. When the first event comes after the
    /// opening, a chapter named after the game covers the time before it, since
    /// chapters must start at zero and leave no gaps.
    static func chapters(for clip: Clip, duration: CMTime) -> [ChapterWriter.Chapter] {
        let total = duration.seconds
        guard total > 0, !clip.markers.isEmpty else { return [] }
        var starts: [(time: Double, title: String)] = []
        for marker in clip.markers where marker.time < total {
            // Events a fraction of a second apart would make unusable chapters.
            if let last = starts.last, marker.time - last.time < 0.5 { continue }
            starts.append((marker.time, marker.title))
        }
        guard !starts.isEmpty else { return [] }
        if starts[0].time > 0.5 { starts.insert((0, clip.displayName), at: 0) } else { starts[0].time = 0 }
        return starts.indices.map { i in
            let end = i + 1 < starts.count ? starts[i + 1].time : total
            return .init(title: starts[i].title,
                         start: CMTime(seconds: starts[i].time, preferredTimescale: 600),
                         duration: CMTime(seconds: end - starts[i].time, preferredTimescale: 600))
        }
    }

    struct Output {
        var url: URL
        var bytes: Int64
        var seconds: Double
    }

    static func convert(clip: Clip,
                        to folder: URL,
                        container: Container,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        let started = Date()
        let scratch = DashAssembler.scratchDirectory()
        let videoURL = scratch.appending(path: "\(clip.id)-full-v.mp4")
        let audioURL = scratch.appending(path: "\(clip.id)-full-a.mp4")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        }

        guard try DashAssembler.assemble(clip: clip, stream: .video, to: videoURL) else {
            throw ConversionError.noVideoStream
        }
        let hasAudio = (try? DashAssembler.assemble(clip: clip, stream: .audio, to: audioURL)) == true
        progress(0.15)

        let options = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        // Assets must outlive their tracks -- see MediaProbe for why.
        let videoAsset = AVURLAsset(url: videoURL, options: options)
        let audioAsset = hasAudio ? AVURLAsset(url: audioURL, options: options) : nil

        let composition = AVMutableComposition()
        guard let vTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.noVideoStream
        }
        let vRange = try await vTrack.load(.timeRange)
        let vComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try vComp?.insertTimeRange(vRange, of: vTrack, at: .zero)

        // Each track is inserted over its OWN range: audio and video differ by up
        // to ~0.1s because their segment boundaries don't line up, and overrunning
        // the audio track fails the export with an unexplained -11800.
        if let audioAsset, let aTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
            let aRange = try await aTrack.load(.timeRange)
            let aComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try aComp?.insertTimeRange(aRange, of: aTrack, at: .zero)
        }
        progress(0.3)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appending(path: "\(clip.outputStem).\(container.ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appending(path: "\(clip.outputStem) (\(suffix)).\(container.ext)")
            suffix += 1
        }

        // An export session can't add tracks, so a clip with timeline events
        // is rewritten sample by sample with a chapter track alongside.
        // Clips without events keep the session path.
        let chapters = chapters(for: clip, duration: composition.duration)
        if container.supportsChapters, !chapters.isEmpty {
            try await ChapterWriter.write(composition, chapters: chapters,
                                          metadata: metadata(for: clip, container: container),
                                          to: destination, fileType: container.fileType) { value in
                progress(0.3 + value * 0.7)
            }
            progress(1.0)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            return Output(url: destination, bytes: bytes, seconds: Date().timeIntervalSince(started))
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ConversionError.exportUnavailable
        }
        session.metadata = metadata(for: clip, container: container)

        let poll = Task {
            while !Task.isCancelled {
                progress(0.3 + Double(session.progress) * 0.7)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poll.cancel() }

        try await session.export(to: destination, as: container.fileType)
        progress(1.0)

        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        return Output(url: destination, bytes: bytes, seconds: Date().timeIntervalSince(started))
    }

    /// Common-keyspace items survive in both containers; the custom `mdta` items
    /// carry Steam specifics and only round-trip in .mov.
    private static func metadata(for clip: Clip, container: Container) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func common(_ key: AVMetadataKey, _ value: String) {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = key as NSString
            item.value = value as NSString
            items.append(item)
        }
        func custom(_ identifier: String, _ value: String) {
            guard container.keepsAllMetadata else { return }
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = "com.steamclipconverter.\(identifier)" as NSString
            item.value = value as NSString
            items.append(item)
        }

        common(.commonKeyTitle, clip.outputStem)
        common(.commonKeyDescription, "\(clip.kind.rawValue) of \(clip.displayName) (Steam app \(clip.appID))")
        common(.commonKeySoftware, "Steam Clip Converter for Mac")
        common(.commonKeyAuthor, "Steam Game Recording")
        common(.commonKeyPublisher, clip.displayName)
        if let date = clip.recordedAt {
            common(.commonKeyCreationDate, ISO8601DateFormatter().string(from: date))
        }

        custom("appid", clip.appID)
        custom("game", clip.displayName)
        custom("source", clip.id)
        custom("kind", clip.kind.rawValue)
        if let p = clip.probe {
            custom("capture", "\(p.width)x\(p.height)@\(Int(p.fps.rounded()))")
            custom("codec", p.videoCodec)
        }
        return items
    }

    enum ConversionError: LocalizedError {
        case noVideoStream, exportUnavailable
        var errorDescription: String? {
            switch self {
            case .noVideoStream: return "No video segments found in this recording."
            case .exportUnavailable: return "Could not create a passthrough export session."
            }
        }
    }
}
