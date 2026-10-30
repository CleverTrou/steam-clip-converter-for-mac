import AVFoundation
import XCTest
@testable import SteamClipConverter

final class StereoLayoutTests: XCTestCase {

    func testOutputNamesCarryExactlyOneTag() {
        XCTAssertEqual(StereoLayout.sideBySide.outputStem(for: "Game 2026-10-28"), "Game 2026-10-28.3D.HSBS")
        XCTAssertEqual(StereoLayout.sideBySide.outputStem(for: "Game.3D.HSBS"), "Game.3D.HSBS")
        XCTAssertEqual(StereoLayout.topBottom.outputStem(for: "Game_SBS"), "Game.3D.HTAB")
        XCTAssertEqual(StereoLayout.flat.outputStem(for: "Game"), "Game")
        // Words that only look like tags stay put.
        XCTAssertEqual(StereoLayout.sideBySide.outputStem(for: "Super Mario 3D"), "Super Mario 3D.3D.HSBS")
        XCTAssertEqual(StereoLayout.stripTags(from: "Game - Tab"), "Game - Tab")
    }

    func testTagsAreReadAsWholeTokensOnly() {
        XCTAssertEqual(StereoLayout.detect(fromFileName: "Game 2026-10-28.3D.HSBS.mov"), .sideBySide)
        XCTAssertEqual(StereoLayout.detect(fromFileName: "movie.3D.HTAB.mp4"), .topBottom)
        XCTAssertNil(StereoLayout.detect(fromFileName: "Gatsbsy.mov"))
        XCTAssertNil(StereoLayout.detect(fromFileName: "Game - Tab menu tutorial.mov"))
        XCTAssertEqual(StereoLayout.detect(fromFileName: "movie.3D.TAB.mov"), .topBottom)
    }

    func testA3DExportOfAClipIsRecognisedAsConverted() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "scc-adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = Clip(id: "bg_550_20260927_201500", url: folder, appID: "550",
                        recordedAt: Clip.folderDateFormatter.date(from: "20260927_201500"), kind: .background,
                        duration: 30, segmentDuration: 3, videoSegmentCount: 10, byteSize: 0,
                        probe: nil, gameName: "Left 4 Dead 2")
        // A different time zone's stamp, so only the name match can find it.
        TimeZone.ReferenceType.default = TimeZone(identifier: "Pacific/Kiritimati")!
        defer { TimeZone.ReferenceType.default = TimeZone.current }
        let output = folder.appending(path: "\(StereoLayout.sideBySide.outputStem(for: clip.outputStem)).mov")
        FileManager.default.createFile(atPath: output.path, contents: Data())
        var records: [String: ConversionRecord] = [:]
        ConversionStore.adopt(clips: [clip], outputFolder: folder, into: &records)
        XCTAssertEqual(records[clip.id].map { URL(fileURLWithPath: $0.outputPath).resolvingSymlinksInPath() },
                       output.resolvingSymlinksInPath())
    }
}

/// End to end through the real Steam path: DASH segments assembled, exported,
/// then tagged. The fixture is FFmpeg's DASH output, which names its segments
/// exactly as Steam does (init-stream0.m4s, chunk-stream0-00001.m4s), holding
/// a 2-second 640x180 side-by-side H.264 + AAC clip with B-frames.
final class SteamStereoConversionTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "scc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func steamClip(markers: [ClipMarker] = []) -> Clip {
        let url = Bundle.module.url(forResource: "steam-sbs", withExtension: nil, subdirectory: "Fixtures")!
        var clip = Clip(id: "bg_550_20260927_201500", url: url, appID: "550",
                        recordedAt: Clip.folderDateFormatter.date(from: "20260927_201500"), kind: .background,
                        duration: 2, segmentDuration: 1, videoSegmentCount: 2, byteSize: 0,
                        probe: nil, gameName: "Left 4 Dead 2")
        clip.markers = markers
        return clip
    }

    /// Decodes every video frame, which fails on wrong chunk offsets - the
    /// thing an st3d insertion could break.
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

    func testA3DClipIsTaggedAndStillPlaysInBothContainers() async throws {
        for container in ClipConverter.Container.allCases {
            let out = try await ClipConverter.convert(clip: steamClip(), to: folder, container: container,
                                                      stereo: .sideBySide) { _ in }
            XCTAssertTrue(out.url.lastPathComponent.hasSuffix(".3D.HSBS.\(container.ext)"), out.url.lastPathComponent)
            XCTAssertEqual(try StereoTagger.readMode(out.url), 2)
            let count = try await decodedFrameCount(out.url)
            XCTAssertEqual(count, 60)
            let audio = try await AVURLAsset(url: out.url).loadTracks(withMediaType: .audio)
            XCTAssertEqual(audio.count, 1)
        }
    }

    /// Clips with timeline events take the ChapterWriter path instead of the
    /// export session; the tag has to land there too.
    func testAClipWithChaptersIsTaggedToo() async throws {
        let clip = steamClip(markers: [.init(time: 0, title: "Start"), .init(time: 1, title: "Tank")])
        let out = try await ClipConverter.convert(clip: clip, to: folder, container: .mov, stereo: .topBottom) { _ in }
        XCTAssertEqual(try StereoTagger.readMode(out.url), 1)
        let groups = try await AVURLAsset(url: out.url).loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en"])
        XCTAssertEqual(groups.count, 2)
        let count = try await decodedFrameCount(out.url)
        XCTAssertEqual(count, 60)
    }

    func testA2DClipIsUntouched() async throws {
        let out = try await ClipConverter.convert(clip: steamClip(), to: folder, container: .mp4) { _ in }
        XCTAssertFalse(out.url.lastPathComponent.contains("3D"))
        XCTAssertNil(try StereoTagger.readMode(out.url))
    }

    /// Movie box BEFORE the media: the tagger has to move every chunk offset.
    func testTaggingAFastStartFileKeepsItPlayable() async throws {
        let flat = try await ClipConverter.convert(clip: steamClip(), to: folder, container: .mp4) { _ in }
        let session = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: flat.url),
                                                         presetName: AVAssetExportPresetPassthrough))
        session.shouldOptimizeForNetworkUse = true
        let faststart = folder.appending(path: "faststart.mp4")
        try await session.export(to: faststart, as: .mp4)
        let data = try Data(contentsOf: faststart)
        XCTAssertTrue(StereoTagger.children(of: 0..<data.count, in: data).prefix(3).contains { $0.type == "moov" })

        try StereoTagger.tag(faststart, layout: .topBottom)
        XCTAssertEqual(try StereoTagger.readMode(faststart), 1)
        try StereoTagger.tag(faststart, layout: .sideBySide)   // retag: same size, new mode
        XCTAssertEqual(try StereoTagger.readMode(faststart), 2)
        let count = try await decodedFrameCount(faststart)
        XCTAssertEqual(count, 60)
    }
}
