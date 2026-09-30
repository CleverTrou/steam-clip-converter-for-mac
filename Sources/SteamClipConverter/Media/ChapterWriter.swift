import AVFoundation

/// Writes a composition to a QuickTime movie with a chapter track, copying
/// every audio and video sample as-is: no re-encoding, same speed class as the
/// passthrough export session.
///
/// Chapters in QuickTime are a disabled text track that the video track points
/// at through a `chap` track reference. QuickTime Player, VLC and IINA list
/// them; `AVAsset.chapterMetadataGroups` reads them back.
enum ChapterWriter {

    struct Chapter {
        let title: String
        let start: CMTime
        let duration: CMTime
    }

    enum WriteError: LocalizedError {
        case noVideoTrack, textFormatUnavailable, failed(Error?)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The recording has no video track to attach chapters to."
            case .textFormatUnavailable: return "Could not create the chapter track format."
            case .failed(let error): return error?.localizedDescription ?? "Writing the movie failed."
            }
        }
    }

    static func write(_ asset: AVAsset,
                      chapters: [Chapter],
                      metadata: [AVMetadataItem],
                      to destination: URL,
                      fileType: AVFileType,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        writer.metadata = metadata

        let duration = try await asset.load(.duration)
        var pumps: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, isVideo: Bool)] = []
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            // nil output settings: compressed samples pass straight through.
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw WriteError.failed(reader.error) }
            reader.add(output)

            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            guard writer.canAdd(input) else { throw WriteError.failed(writer.error) }
            writer.add(input)
            pumps.append((output, input, track.mediaType == .video))
        }
        guard let video = pumps.first(where: \.isVideo)?.input else { throw WriteError.noVideoTrack }

        let textFormat = try chapterFormat()
        let chapterInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
        chapterInput.expectsMediaDataInRealTime = false
        chapterInput.marksOutputTrackAsEnabled = false
        // An untagged ("und") chapter track is skipped by lookups that ask for
        // the viewer's languages, which is how QuickTime Player finds chapters.
        // Titles come from Steam in the client's language, so tag it with ours.
        chapterInput.languageCode = Locale.current.language.languageCode?.identifier(.alpha3) ?? "eng"
        chapterInput.extendedLanguageTag = Locale.preferredLanguages.first
        guard writer.canAdd(chapterInput) else { throw WriteError.failed(writer.error) }
        writer.add(chapterInput)
        video.addTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)

        // Built before anything starts, so a failure here leaves no file behind.
        let samples = try chapters.map { chapter -> CMSampleBuffer in
            try textSample(chapter.title, start: chapter.start, duration: chapter.duration, format: textFormat)
        }

        guard reader.startReading() else { throw WriteError.failed(reader.error) }
        guard writer.startWriting() else { throw WriteError.failed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let aborter = DrainAborter()
        let allDrained = await withTaskGroup(of: Bool.self) { group -> Bool in
            for (index, pump) in pumps.enumerated() {
                let queue = DispatchQueue(label: "chapter-writer.\(index)")
                group.addTask {
                    await drain(into: pump.input, on: queue, aborter: aborter) {
                        guard let sample = pump.output.copyNextSampleBuffer() else { return nil }
                        if pump.isVideo, duration.seconds > 0 {
                            progress(min(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration.seconds, 1))
                        }
                        return sample
                    }
                }
            }
            group.addTask {
                var remaining = samples[...]
                return await drain(into: chapterInput, on: DispatchQueue(label: "chapter-writer.text"), aborter: aborter) {
                    remaining.popFirst()
                }
            }
            return await group.allSatisfy { $0 }
        }

        // A half-written movie must not survive: it would sit in the export
        // folder under the clip's own name, and the ledger adopts outputs by
        // name, so the clip would be marked converted.
        func discard(_ error: Error?) -> Error {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: destination)
            return WriteError.failed(error)
        }

        guard allDrained, reader.status != .failed, writer.status != .failed else {
            throw discard(reader.error ?? writer.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw discard(writer.error) }
    }

    /// Feeds `input` until `next` runs dry or an append fails, then marks it
    /// finished. Returns false if an append failed here or in a sibling drain.
    private static func drain(into input: AVAssetWriterInput, on queue: DispatchQueue, aborter: DrainAborter,
                              next: @escaping () -> CMSampleBuffer?) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            // Only touched on `queue`, which the readiness callback also runs on.
            var finished = false
            func finish(_ succeeded: Bool) {
                finished = true
                done.resume(returning: succeeded)
            }
            aborter.onAbort { queue.async { if !finished { finish(false) } } }
            input.requestMediaDataWhenReady(on: queue) {
                while !finished && input.isReadyForMoreMediaData {
                    guard let sample = next() else {
                        input.markAsFinished()
                        finish(true)
                        return
                    }
                    guard input.append(sample) else {
                        input.markAsFinished()
                        finish(false)
                        aborter.abort()
                        return
                    }
                }
            }
        }
    }

    // MARK: - QuickTime text samples

    /// The QuickTime `text` sample description for a chapter track, in the
    /// exact big-endian form CoreMedia itself produces when it serializes the
    /// chapter track of a movie (CMTextFormatDescriptionCopyAsBigEndian…).
    /// A bare text description is rejected by the writer (-12712), and one
    /// hand-built from the classic file-format spec fails to parse (-12714):
    /// CoreMedia's form adds a font table and a 0xFFFF data reference index.
    private static let chapterDescription: [UInt8] = [
        0x00, 0x00, 0x00, 0x3b, 0x74, 0x65, 0x78, 0x74,   // size 59, 'text'
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff,   // reserved, data reference index
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,   // display flags, justification
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,               // background colour
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   // default text box
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,   // default style
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x66, 0x74, 0x61, 0x62, 0x00, 0x01, 0x00, 0x01, 0x00,   // 'ftab': one font, id 1, no name
    ]

    private static func chapterFormat() throws -> CMFormatDescription {
        let bytes = chapterDescription
        var format: CMFormatDescription?
        let status = bytes.withUnsafeBufferPointer { buffer in
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault, bigEndianTextDescriptionData: buffer.baseAddress!,
                size: buffer.count, flavor: nil, mediaType: kCMMediaType_Text, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw WriteError.textFormatUnavailable }
        return format
    }

    /// A QuickTime text sample: a big-endian UInt16 length, the UTF-8 text,
    /// then an `encd` atom declaring UTF-8 so non-ASCII titles survive.
    private static func textSample(_ text: String, start: CMTime, duration: CMTime,
                                   format: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = Array(text.utf8.prefix(Int(UInt16.max)))
        var bytes = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)] + utf8
        bytes += [0, 0, 0, 12] + Array("encd".utf8) + [0, 0, 1, 0]

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0,
                                            dataLength: bytes.count) == noErr
        else { throw WriteError.textFormatUnavailable }

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                   sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                   sampleBufferOut: &sample) == noErr,
              let sample
        else { throw WriteError.textFormatUnavailable }
        return sample
    }
}

/// Stops every drain once one fails. A failed writer may never call another
/// input's readiness block, so a drain waiting on one would hang the export
/// and the partial file would never be cleaned up.
final class DrainAborter: @unchecked Sendable {
    private var handlers: [() -> Void] = []
    private var aborted = false
    private let lock = NSLock()

    /// Runs `handler` on abort, or right away if that already happened.
    func onAbort(_ handler: @escaping () -> Void) {
        lock.lock()
        guard !aborted else { lock.unlock(); handler(); return }
        handlers.append(handler)
        lock.unlock()
    }

    func abort() {
        lock.lock()
        let pending = aborted ? [] : handlers
        aborted = true
        handlers = []
        lock.unlock()
        pending.forEach { $0() }
    }
}
