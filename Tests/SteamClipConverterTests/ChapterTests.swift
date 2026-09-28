import AVFoundation
import XCTest
@testable import SteamClipConverter

final class ChapterTests: XCTestCase {

    private func clip(markers: [ClipMarker], duration: Double = 30) -> Clip {
        var clip = Clip(id: "bg_550_20260927_201500", url: URL(fileURLWithPath: "/tmp/bg_550_20260927_201500"),
                        appID: "550", recordedAt: nil, kind: .background, duration: duration,
                        segmentDuration: 3, videoSegmentCount: 10, byteSize: 0, probe: nil, gameName: "Left 4 Dead 2")
        clip.markers = markers
        return clip
    }

    private func summary(_ chapters: [ChapterWriter.Chapter]) -> [String] {
        chapters.map { String(format: "%.1f+%.1f %@", $0.start.seconds, $0.duration.seconds, $0.title) }
    }

    func testChaptersRunGapFreeFromZeroToTheEnd() {
        let chapters = ClipConverter.chapters(for: clip(markers: [
            .init(time: 0, title: "Safe room"), .init(time: 8, title: "Tank"), .init(time: 24, title: "Marker"),
        ]), duration: CMTime(seconds: 30, preferredTimescale: 600))
        XCTAssertEqual(summary(chapters), ["0.0+8.0 Safe room", "8.0+16.0 Tank", "24.0+6.0 Marker"])
    }

    func testAnOpeningChapterNamedAfterTheGameCoversTimeBeforeTheFirstEvent() {
        let chapters = ClipConverter.chapters(for: clip(markers: [.init(time: 12, title: "Tank")]),
                                              duration: CMTime(seconds: 30, preferredTimescale: 600))
        XCTAssertEqual(summary(chapters), ["0.0+12.0 Left 4 Dead 2", "12.0+18.0 Tank"])
    }

    func testEventsUnderHalfASecondApartCollapse() {
        let chapters = ClipConverter.chapters(for: clip(markers: [
            .init(time: 0.2, title: "First"), .init(time: 8, title: "Tank"), .init(time: 8.2, title: "Echo"),
        ]), duration: CMTime(seconds: 30, preferredTimescale: 600))
        XCTAssertEqual(summary(chapters), ["0.0+8.0 First", "8.0+22.0 Tank"])
    }

    func testNoMarkersMeansNoChapters() {
        XCTAssertTrue(ClipConverter.chapters(for: clip(markers: []),
                                             duration: CMTime(seconds: 30, preferredTimescale: 600)).isEmpty)
    }

    func testOnlyQuickTimeGetsChapters() {
        XCTAssertTrue(ClipConverter.Container.mov.supportsChapters)
        XCTAssertFalse(ClipConverter.Container.mp4.supportsChapters)
    }
}
