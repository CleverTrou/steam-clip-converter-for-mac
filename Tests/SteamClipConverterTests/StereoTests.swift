import AVFoundation
import XCTest
@testable import SteamClipConverter

final class StereoLayoutTests: XCTestCase {

    func testLayoutIsReadFromFileNameTokens() {
        XCTAssertEqual(StereoLayout.detect(fromFileName: "Riddick - 2026-10-28 18-04-09.3D.HSBS.mkv"), .sideBySide)
        XCTAssertEqual(StereoLayout.detect(fromFileName: "clip_SBS.mp4"), .sideBySide)
        XCTAssertEqual(StereoLayout.detect(fromFileName: "movie.3D.HTAB.mkv"), .topBottom)
        XCTAssertEqual(StereoLayout.detect(fromFileName: "movie 3D HOU.mov"), .topBottom)
        XCTAssertNil(StereoLayout.detect(fromFileName: "Half-Life Alyx - 2026-09-20 21-39-16.mkv"))
        // Inside a word, or a bare "OU", is not a tag.
        XCTAssertNil(StereoLayout.detect(fromFileName: "Gatsbsy.mkv"))
        XCTAssertNil(StereoLayout.detect(fromFileName: "Ou est la gare.mkv"))
    }

    func testOutputNamesCarryExactlyOneTag() {
        XCTAssertEqual(StereoLayout.sideBySide.outputStem(for: "Game 2026-10-28"), "Game 2026-10-28.3D.HSBS")
        XCTAssertEqual(StereoLayout.sideBySide.outputStem(for: "Game.3D.HSBS"), "Game.3D.HSBS")
        XCTAssertEqual(StereoLayout.topBottom.outputStem(for: "Game_SBS"), "Game.3D.HTAB")
        XCTAssertEqual(StereoLayout.flat.outputStem(for: "Game"), "Game")
        let file = URL(fileURLWithPath: "/x/Riddick - 2026-10-28 18-04-09.3D.HSBS.mkv")
        XCTAssertEqual(VideoFileConverter.outputStem(for: file, layout: .flat), "Riddick - 2026-10-28 18-04-09")
    }

    func testAutomaticTrustsTheFileAndTheOthersOverrideIt() {
        XCTAssertEqual(StereoChoice.automatic.resolve(detected: .sideBySide), .sideBySide)
        XCTAssertEqual(StereoChoice.automatic.resolve(detected: nil), .flat)
        XCTAssertEqual(StereoChoice.flat.resolve(detected: .sideBySide), .flat)
        XCTAssertEqual(StereoChoice.topBottom.resolve(detected: nil), .topBottom)
    }
}

final class MatroskaTests: XCTestCase {

    static func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "mkv", subdirectory: "Fixtures")!
    }

    func testOBSStyleFileIsIndexed() throws {
        let mkv = try MatroskaFile(url: Self.fixture("sbs-h264-aac"))
        let video = try XCTUnwrap(mkv.videoTrack)
        XCTAssertEqual(video.codecID, "V_MPEG4/ISO/AVC")
        XCTAssertEqual([video.width, video.height], [640, 180])
        XCTAssertFalse(video.codecPrivate.isEmpty)
        let audio = try XCTUnwrap(mkv.audioTrack)
        XCTAssertTrue(audio.codecID.hasPrefix("A_AAC"))
        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertEqual(audio.channels, 2)
        XCTAssertEqual(mkv.declaredStereoLayout, .sideBySide)

        let videoFrames = mkv.frames.filter { $0.track == video.number }
        XCTAssertEqual(videoFrames.count, 60)            // 2 s at 30 fps
        XCTAssertTrue(videoFrames.first!.isKey)
        XCTAssertEqual(videoFrames.filter(\.isKey).count, 2)   // -g 30
    }

    func testCutOffRecordingIsReadUpToItsLastWholeFrame() throws {
        let whole = try MatroskaFile(url: Self.fixture("sbs-h264-aac"))
        let cut = try MatroskaFile(url: Self.fixture("truncated-h264-aac"))
        XCTAssertGreaterThan(cut.frames.count, 0)
        XCTAssertLessThan(cut.frames.count, whole.frames.count)
        for frame in cut.frames { XCTAssertLessThanOrEqual(frame.offset + frame.size, cut.data.count) }
    }

    func testDecodeTimesNeverFollowPresentationAndOnlyMoveForward() throws {
        let mkv = try MatroskaFile(url: Self.fixture("sbs-h264-aac"))
        let video = try XCTUnwrap(mkv.videoTrack)
        let samples = MatroskaRemuxer.videoTiming(mkv.frames.filter { $0.track == video.number })
        XCTAssertTrue(samples.contains { $0.dts != $0.pts }, "the fixture should have B-frames")
        for s in samples { XCTAssertLessThanOrEqual(s.dts, s.pts) }
        for (a, b) in zip(samples, samples.dropFirst()) { XCTAssertLessThan(a.dts, b.dts) }
    }

    func testNotMatroskaIsRefused() {
        XCTAssertThrowsError(try MatroskaFile(data: Data("not a video".utf8)))
    }
}

final class ConversionTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "scc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["SCC_KEEP"] == nil { try? FileManager.default.removeItem(at: folder) } else { print("KEPT \(folder!.path)") }
    }

    /// Decodes every video frame, which fails on wrong decode order or
    /// chunk offsets - the two things the remuxer and the tagger could break.
    private func decodedFrameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { count += 1 }
        }
        XCTAssertEqual(reader.status, .completed, "\(reader.error.map(String.init(describing:)) ?? "")")
        return count
    }

    func testMkvBecomesATagged3DMovieThatPlays() async throws {
        for container in ClipConverter.Container.allCases {
            let out = try await VideoFileConverter.convert(file: MatroskaTests.fixture("sbs-h264-aac"), to: folder,
                                                           container: container, stereo: .automatic) { _ in }
            XCTAssertEqual(out.layout, .sideBySide, "from Matroska's StereoMode")
            XCTAssertEqual(out.url.lastPathComponent, "sbs-h264-aac.3D.HSBS.\(container.ext)")
            XCTAssertNil(out.note)
            XCTAssertEqual(try StereoTagger.readMode(out.url), 2)

            let asset = AVURLAsset(url: out.url)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audioTracks.count, 1)
            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, 2, accuracy: 0.1)
            let count = try await decodedFrameCount(out.url)
            XCTAssertEqual(count, 60)
        }
    }

    func testHevcAndFlatOutputHaveNoTag() async throws {
        let out = try await VideoFileConverter.convert(file: MatroskaTests.fixture("flat-hevc"), to: folder,
                                                       container: .mov, stereo: .automatic) { _ in }
        XCTAssertEqual(out.layout, .flat)
        XCTAssertNil(try StereoTagger.readMode(out.url))
        let format = try await AVURLAsset(url: out.url).loadTracks(withMediaType: .video).first!.load(.formatDescriptions).first!
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        let count = try await decodedFrameCount(out.url)
        XCTAssertEqual(count, 60)
    }

    func testCutOffRecordingStillConverts() async throws {
        let out = try await VideoFileConverter.convert(file: MatroskaTests.fixture("truncated-h264-aac"), to: folder,
                                                       container: .mp4, stereo: .sideBySide) { _ in }
        XCTAssertEqual(try StereoTagger.readMode(out.url), 2)
        let count = try await decodedFrameCount(out.url)
        XCTAssertGreaterThan(count, 0)
    }

    /// Movie box BEFORE the media: the tagger has to move every chunk offset.
    func testTaggingAFastStartFileKeepsItPlayable() async throws {
        let flat = try await VideoFileConverter.convert(file: MatroskaTests.fixture("sbs-h264-aac"), to: folder,
                                                        container: .mp4, stereo: .flat) { _ in }
        let session = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: flat.url),
                                                         presetName: AVAssetExportPresetPassthrough))
        session.shouldOptimizeForNetworkUse = true
        let faststart = folder.appending(path: "faststart.mp4")
        try await session.export(to: faststart, as: .mp4)
        XCTAssertEqual(try topLevelTypes(faststart).prefix(3).contains("moov"), true)

        try StereoTagger.tag(faststart, layout: .topBottom)
        XCTAssertEqual(try StereoTagger.readMode(faststart), 1)
        try StereoTagger.tag(faststart, layout: .sideBySide)   // retag: same size, new mode
        XCTAssertEqual(try StereoTagger.readMode(faststart), 2)
        let count = try await decodedFrameCount(faststart)
        XCTAssertEqual(count, 60)
    }

    /// A real OBS recording, too big to commit: set SCC_REAL_MKV to run it.
    /// Forced to side-by-side so the tag path runs too; the frames are what
    /// is being checked.
    func testRealOBSCapture() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCC_REAL_MKV"] else {
            throw XCTSkip("set SCC_REAL_MKV to an OBS .mkv to run this")
        }
        let file = URL(fileURLWithPath: path)
        let mkv = try MatroskaFile(url: file)
        let expected = mkv.frames.filter { $0.track == mkv.videoTrack!.number }.count
        let started = Date()
        let out = try await VideoFileConverter.convert(file: file, to: folder, container: .mp4,
                                                       stereo: .sideBySide) { _ in }
        print("REAL: \(expected) frames remuxed in \(Date().timeIntervalSince(started))s -> \(out.bytes) bytes")
        XCTAssertNil(out.note)
        XCTAssertEqual(try StereoTagger.readMode(out.url), 2)
        let count = try await decodedFrameCount(out.url)
        XCTAssertEqual(count, expected)
        let audioSamples = try await decodedAudioFrames(out.url)
        XCTAssertGreaterThan(audioSamples, 0)
    }

    private func decodedAudioFrames(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
        XCTAssertEqual(reader.status, .completed, "\(reader.error.map(String.init(describing:)) ?? "")")
        return frames
    }

    func testAudioDecodesToTheRightLength() async throws {
        let out = try await VideoFileConverter.convert(file: MatroskaTests.fixture("sbs-h264-aac"), to: folder,
                                                       container: .mp4, stereo: .automatic) { _ in }
        let frames = try await decodedAudioFrames(out.url)
        XCTAssertEqual(Double(frames) / 48_000, 2, accuracy: 0.1)
    }

    private func topLevelTypes(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        return StereoTagger.children(of: 0..<data.count, in: data).map(\.type)
    }
}
