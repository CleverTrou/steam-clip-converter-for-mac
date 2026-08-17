import AVFoundation
import AppKit

/// Reads true stream parameters and renders preview frames.
///
/// Every preview assembles ONE segment (init + a single chunk, typically a few
/// MB) rather than the whole clip, so scrubbing a 3-minute 4K recording never
/// copies more than a few megabytes.
actor MediaProbe {
    static let shared = MediaProbe()

    private var probeCache: [String: ProbeResult] = [:]
    private var frameCache: [String: NSImage] = [:]

    /// Real codec, resolution and frame rate -- from the bitstream, not the MPD.
    func probe(_ clip: Clip) async -> ProbeResult? {
        if let hit = probeCache[clip.id] { return hit }

        let scratch = DashAssembler.scratchDirectory()
        let videoURL = scratch.appending(path: "\(clip.id)-probe-v.mp4")
        let audioURL = scratch.appending(path: "\(clip.id)-probe-a.mp4")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        }

        guard (try? DashAssembler.assemble(clip: clip, stream: .video, to: videoURL, chunkRange: 0..<1)) == true else {
            return nil
        }
        // Hold the asset in a binding: an AVAssetTrack does not retain its parent
        // asset, and a deallocated asset turns every later call into an opaque
        // -11800 / -12780 failure.
        let videoAsset = AVURLAsset(url: videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vTrack = try? await videoAsset.loadTracks(withMediaType: .video).first else { return nil }

        let size = (try? await vTrack.load(.naturalSize)) ?? .zero
        let fps = (try? await vTrack.load(.nominalFrameRate)) ?? 0
        var codec = "----"
        if let fd = (try? await vTrack.load(.formatDescriptions))?.first {
            codec = fourCC(CMFormatDescriptionGetMediaSubType(fd))
        }

        var hasAudio = false, sampleRate = 0.0, channels = 0
        if (try? DashAssembler.assemble(clip: clip, stream: .audio, to: audioURL, chunkRange: 0..<1)) == true {
            let audioAsset = AVURLAsset(url: audioURL)
            if let aTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first {
                hasAudio = true
                if let fd = (try? await aTrack.load(.formatDescriptions))?.first,
                   let basic = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                    sampleRate = basic.pointee.mSampleRate
                    channels = Int(basic.pointee.mChannelsPerFrame)
                }
            }
        }

        let result = ProbeResult(width: Int(size.width), height: Int(size.height),
                                 fps: Double(fps), videoCodec: codec, hasAudio: hasAudio,
                                 audioSampleRate: sampleRate, audioChannels: channels)
        probeCache[clip.id] = result
        return result
    }

    /// A frame at `time`, assembled from just the segment containing it.
    func frame(for clip: Clip, at time: Double, maxWidth: CGFloat = 640) async -> NSImage? {
        let segment = DashAssembler.segmentIndex(for: time, in: clip)
        let key = "\(clip.id)#\(segment)#\(Int(maxWidth))"
        if let hit = frameCache[key] { return hit }

        let scratch = DashAssembler.scratchDirectory()
        let url = scratch.appending(path: "\(clip.id)-seg\(segment).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        guard (try? DashAssembler.assemble(clip: clip, stream: .video, to: url,
                                           chunkRange: segment..<(segment + 1))) == true else { return nil }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange) else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: 0)
        // Each segment opens on a sync sample, so a generous tolerance costs
        // nothing and avoids decoding forward from the segment start.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.5, preferredTimescale: 600)

        // A standalone segment keeps its original decode timestamps, so its
        // timeline starts at the segment's offset -- not at zero.
        let within = time - (Double(segment) * clip.segmentDuration)
        var target = range.start + CMTime(seconds: max(0, within), preferredTimescale: 600)
        if target > range.end { target = range.start }

        guard let (cg, _) = try? await generator.image(at: target) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        frameCache[key] = image
        return image
    }

    func poster(for clip: Clip) async -> NSImage? {
        // A frame ~10% in beats frame zero: recordings often open on a fade or a
        // loading screen.
        await frame(for: clip, at: clip.duration * 0.1, maxWidth: 480)
    }

    private func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "----"
    }
}
