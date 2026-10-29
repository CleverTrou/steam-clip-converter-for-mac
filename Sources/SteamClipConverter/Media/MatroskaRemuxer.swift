import AVFoundation
import CoreMedia

/// Copies a Matroska file's video and audio into an MP4 or QuickTime file
/// without re-encoding, the way ClipConverter does for Steam's DASH segments.
///
/// WHY DECODE TIMES HAVE TO BE MADE UP
/// Matroska stores only presentation times. MP4 also needs decode times
/// whenever frames are stored out of display order - which H.264 with
/// B-frames, OBS's default, always is. FFmpeg solves this the same way: the
/// k-th frame in decode order is decoded at the k-th smallest presentation
/// time, pulled back by the largest reordering delay so that no frame is
/// decoded after it is shown.
enum MatroskaRemuxer {

    enum RemuxError: LocalizedError {
        case noVideo, unsupportedVideo(String), formatFailed(OSStatus), failed(Error?)
        var errorDescription: String? {
            switch self {
            case .noVideo: return "The .mkv has no video track."
            case .unsupportedVideo(let codec):
                return "The .mkv's video is \(codec). Only H.264 and HEVC can be copied without re-encoding."
            case .formatFailed(let status): return "Could not describe the .mkv's media (error \(status))."
            case .failed(let error): return error?.localizedDescription ?? "Writing the movie failed."
            }
        }
    }

    struct Result {
        /// The audio track was left out, with the reason. nil when copied or absent.
        var skippedAudio: String?
    }

    static func remux(_ mkv: MatroskaFile,
                      to destination: URL,
                      fileType: AVFileType,
                      metadata: [AVMetadataItem] = [],
                      progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        guard let video = mkv.videoTrack else { throw RemuxError.noVideo }
        guard !video.isCompressed else { throw MatroskaFile.ReadError.unsupported("content compression") }
        let videoFormat = try videoFormatDescription(video)

        var result = Result()
        var audioFormat: CMAudioFormatDescription?
        if let audio = mkv.audioTrack {
            if !audio.codecID.hasPrefix("A_AAC") {
                result.skippedAudio = "its audio is \(audio.codecID), which can't be copied into this format"
            } else if audio.isCompressed {
                result.skippedAudio = "its audio track is compressed inside the .mkv"
            } else {
                audioFormat = try audioFormatDescription(audio)
            }
        }

        let videoSamples = videoTiming(mkv.frames.filter { $0.track == video.number })
        let audioFrames = audioFormat == nil ? [] : mkv.frames.filter { $0.track == mkv.audioTrack!.number }
        guard !videoSamples.isEmpty else { throw RemuxError.noVideo }

        // Zero is the earliest presentation time on either track.
        let origin = min(videoSamples.map(\.pts).min() ?? 0, audioFrames.first?.time ?? .max)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        writer.metadata = metadata
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw RemuxError.failed(writer.error) }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if let audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw RemuxError.failed(writer.error) }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw RemuxError.failed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let data = mkv.data
        let sampleRate = mkv.audioTrack?.sampleRate ?? 48_000
        let feed = Task.detached { () throws -> Void in
            try interleave(writer: writer,
                           video: (videoInput, videoSamples.count, { i in
                               let s = videoSamples[i]
                               return try sampleBuffer(data: data, frame: s.frame, format: videoFormat,
                                                       pts: s.pts - origin, dts: s.dts - origin, duration: s.duration)
                           }, { i in videoSamples[i].dts }),
                           audio: audioInput.map { input in
                               (input, audioFrames.count, { i in
                                   try audioSampleBuffer(data: data, frame: audioFrames[i], format: audioFormat!,
                                                         pts: audioFrames[i].time - origin, sampleRate: sampleRate)
                               }, { i in audioFrames[i].time })
                           },
                           progress: progress)
        }
        do {
            try await feed.value
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw RemuxError.failed(error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw RemuxError.failed(writer.error)
        }
        progress(1)
        return result
    }

    // MARK: - Timing

    struct VideoSample {
        let frame: MatroskaFile.Frame
        let pts: Int64
        let dts: Int64
        let duration: Int64
    }

    /// Frames in file (decode) order, with decode times and durations made up
    /// as described above. Times are nanoseconds.
    static func videoTiming(_ frames: [MatroskaFile.Frame]) -> [VideoSample] {
        guard !frames.isEmpty else { return [] }
        let sorted = frames.map(\.time).sorted()
        var delay: Int64 = 0
        for (k, frame) in frames.enumerated() { delay = max(delay, sorted[k] - frame.time) }

        // A frame lasts until the next one in display order. The last one
        // repeats the typical spacing.
        var next: [Int64: Int64] = [:]
        for k in 0..<(sorted.count - 1) where sorted[k + 1] > sorted[k] { next[sorted[k]] = sorted[k + 1] }
        let typical = sorted.count > 1 ? max(1, (sorted.last! - sorted.first!) / Int64(sorted.count - 1)) : 16_666_667

        return frames.enumerated().map { k, frame in
            let duration = next[frame.time].map { $0 - frame.time } ?? typical
            return VideoSample(frame: frame, pts: frame.time, dts: sorted[k] - delay, duration: duration)
        }
    }

    // MARK: - Formats

    static func videoFormatDescription(_ track: MatroskaFile.Track) throws -> CMVideoFormatDescription {
        let codec: CMVideoCodecType
        let atom: String
        switch track.codecID {
        case "V_MPEG4/ISO/AVC": codec = kCMVideoCodecType_H264; atom = "avcC"
        case "V_MPEGH/ISO/HEVC": codec = kCMVideoCodecType_HEVC; atom = "hvcC"
        default: throw RemuxError.unsupportedVideo(track.codecID)
        }
        // The decoder configuration record Matroska keeps as CodecPrivate is
        // byte-for-byte the avcC / hvcC box payload MP4 wants.
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: track.codecPrivate],
        ]
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec,
                                                    width: Int32(track.width), height: Int32(track.height),
                                                    extensions: extensions as CFDictionary,
                                                    formatDescriptionOut: &format)
        guard status == noErr, let format else { throw RemuxError.formatFailed(status) }
        return format
    }

    static func audioFormatDescription(_ track: MatroskaFile.Track) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: track.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(track.channels),
                                               mBitsPerChannel: 0, mReserved: 0)
        let cookie = aacMagicCookie(audioSpecificConfig: track.codecPrivate)
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count, magicCookie: raw.baseAddress,
                                           extensions: nil, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw RemuxError.formatFailed(status) }
        return format
    }

    /// Matroska's CodecPrivate for AAC is the bare AudioSpecificConfig. The
    /// writer copies an AAC magic cookie verbatim into the MP4 `esds` box,
    /// which needs the full MPEG-4 ES descriptor around it (ISO 14496-1 7.2.6):
    /// a bare config there makes a track AVFoundation can't see at all.
    static func aacMagicCookie(audioSpecificConfig asc: Data) -> Data {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data {
            // The 4-byte length form, as FFmpeg writes it; any length fits.
            let n = body.count
            var d = Data([tag, 0x80 | UInt8((n >> 21) & 0x7F), 0x80 | UInt8((n >> 14) & 0x7F),
                          0x80 | UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
            d.append(body)
            return d
        }
        var decoderConfig = Data([0x40,          // object type: MPEG-4 audio
                                  0x15,          // stream type audio (5) << 2 | reserved 1
                                  0, 0, 0,       // buffer size
                                  0, 0, 0, 0,    // max bitrate
                                  0, 0, 0, 0])   // average bitrate
        decoderConfig.append(descriptor(0x05, asc))
        var es = Data([0, 0, 0])                 // ES_ID 0, no flags
        es.append(descriptor(0x04, decoderConfig))
        es.append(descriptor(0x06, Data([0x02])))   // SLConfig: predefined MP4
        return descriptor(0x03, es)
    }

    // MARK: - Samples

    private static func time(_ ns: Int64) -> CMTime { CMTime(value: ns, timescale: 1_000_000_000) }

    private static func blockBuffer(_ data: Data, _ frame: MatroskaFile.Frame) throws -> CMBlockBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.size,
                                                        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: frame.size, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw RemuxError.formatFailed(status) }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + frame.offset, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: frame.size)
        }
        guard status == noErr else { throw RemuxError.formatFailed(status) }
        return block
    }

    static func sampleBuffer(data: Data, frame: MatroskaFile.Frame, format: CMFormatDescription,
                             pts: Int64, dts: Int64, duration: Int64) throws -> CMSampleBuffer {
        let block = try blockBuffer(data, frame)
        var timing = CMSampleTimingInfo(duration: time(duration), presentationTimeStamp: time(pts),
                                        decodeTimeStamp: time(dts))
        var size = frame.size
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                               sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw RemuxError.formatFailed(status) }
        if !frame.isKey,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    static func audioSampleBuffer(data: Data, frame: MatroskaFile.Frame, format: CMAudioFormatDescription,
                                  pts: Int64, sampleRate: Double) throws -> CMSampleBuffer {
        let block = try blockBuffer(data, frame)
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                  mDataByteSize: UInt32(frame.size))
        var sample: CMSampleBuffer?
        // An AAC packet is 1024 samples, so its timestamp is in the sample rate's timescale.
        let rate = Int32(sampleRate.rounded())
        let start = CMTimeConvertScale(time(pts), timescale: rate, method: .roundHalfAwayFromZero)
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            presentationTimeStamp: start, packetDescriptions: &packet, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw RemuxError.formatFailed(status) }
        return sample
    }

    // MARK: - Interleaving

    /// An input, how many samples it gets, how to make sample i, and sample
    /// i's decode time in nanoseconds (the order the writer wants them in).
    typealias Stream = (input: AVAssetWriterInput, count: Int,
                        make: (Int) throws -> CMSampleBuffer, time: (Int) -> Int64)

    struct StallError: LocalizedError {
        var errorDescription: String? { "The movie writer stopped accepting samples." }
    }

    /// Feeds both tracks in one loop, always the one whose next sample comes
    /// first. The writer holds back whichever track runs ahead until the
    /// other catches up, so feeding the earlier one is what keeps it moving;
    /// a loop that waited on the later track would wait forever.
    static func interleave(writer: AVAssetWriter, video: Stream, audio: Stream?,
                           progress: @escaping @Sendable (Double) -> Void) throws {
        let streams = [video] + (audio.map { [$0] } ?? [])
        var next = Array(repeating: 0, count: streams.count)
        var finished = Array(repeating: false, count: streams.count)
        var lastProgress = -1
        var waitingSince: Date?

        func finish(_ i: Int) {
            if !finished[i] { streams[i].input.markAsFinished(); finished[i] = true }
        }

        while finished.contains(false) {
            if writer.status == .failed { throw writer.error ?? StallError() }
            for i in streams.indices where next[i] >= streams[i].count { finish(i) }
            let pending = streams.indices.filter { !finished[$0] }
            guard let first = pending.min(by: { streams[$0].time(next[$0]) < streams[$1].time(next[$1]) }) else { break }

            // The earliest track first; if it is full, anything else ready.
            let pick = streams[first].input.isReadyForMoreMediaData
                ? first
                : pending.first { streams[$0].input.isReadyForMoreMediaData }
            guard let pick else {
                let since = waitingSince ?? Date()
                waitingSince = since
                if Date().timeIntervalSince(since) > 60 { throw StallError() }
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            waitingSince = nil

            let appended = try autoreleasepool { streams[pick].input.append(try streams[pick].make(next[pick])) }
            guard appended else { throw writer.error ?? StallError() }
            next[pick] += 1

            if pick == 0 {
                let percent = next[0] * 100 / max(1, streams[0].count)
                if percent != lastProgress { lastProgress = percent; progress(Double(percent) / 100) }
            }
        }
    }
}
