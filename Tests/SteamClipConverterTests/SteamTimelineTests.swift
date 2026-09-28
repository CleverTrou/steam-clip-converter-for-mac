import XCTest
@testable import SteamClipConverter

final class SteamTimelineTests: XCTestCase {

    // MARK: - Protobuf encoding for fixtures

    private func varint(_ value: UInt64) -> Data {
        var value = value, out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }
    private func field(_ number: Int, _ value: UInt64) -> Data { varint(UInt64(number << 3)) + varint(value) }
    private func field(_ number: Int, _ bytes: Data) -> Data { varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    private func field(_ number: Int, _ string: String) -> Data { field(number, Data(string.utf8)) }

    /// Mirrors the shape of a real gamerecording.pb: timeline id, app ID, start,
    /// length, and per-recording folder, offset and length (plus fields we ignore).
    private func index(timeline: String, recordings: [(String, UInt64)]) -> Data {
        var body = field(1, timeline) + field(2, 250820) + field(3, 1_786_897_855) + field(4, 125_192)
        for (folder, offset) in recordings {
            body += field(5, field(1, folder) + field(2, offset) + field(3, 82_551) + field(4, 3) + field(9, 514_401_527))
        }
        return field(1, body)
    }

    // MARK: - Index

    func testIndexMapsEachRecordingToItsTimelineAndOffset() {
        let data = index(timeline: "timeline_A", recordings: [("bg_1", 7_365), ("bg_2", 38_124)])
        let parsed = SteamTimeline.parseIndex(data)
        XCTAssertEqual(parsed["bg_1"], .init(timelineID: "timeline_A", offset: 7_365))
        XCTAssertEqual(parsed["bg_2"], .init(timelineID: "timeline_A", offset: 38_124))
    }

    func testIndexToleratesTruncatedData() {
        let data = index(timeline: "timeline_A", recordings: [("bg_1", 7_365)])
        XCTAssertTrue(SteamTimeline.parseIndex(data.prefix(data.count - 3)).isEmpty)
    }

    // MARK: - Timeline JSON

    func testTimelineReadsStringNumbersAndSkipsErrors() throws {
        let json = """
        {"daterecorded":"1786897865","starttime":"0","endtime":"2354034","entries":[
          {"id":"1","time":"429813","type":"error","description":"#GameRecording_RecordingFailed"},
          {"id":"2","time":"5000","type":"event","title":"Tank spawned","description":"Wave 3"},
          {"id":"3","time":"9000","type":"usermarker","description":"#GameRecording_UserMarker"},
          {"id":"4","time":12000,"duration":"4000","type":"event","name":"Horde"}
        ]}
        """
        let timeline = try XCTUnwrap(SteamTimeline.Timeline(data: Data(json.utf8)))
        XCTAssertEqual(timeline.entries.map(\.title), ["Tank spawned", "User marker", "Horde"])
        XCTAssertEqual(timeline.entries.map(\.time), [5000, 9000, 12000])
        XCTAssertEqual(timeline.entries.last?.duration, 4000)
    }

    func testReadableTurnsTokensIntoSentences() {
        XCTAssertEqual(SteamTimeline.readable("#GameRecording_RecordingFailed"), "Recording failed")
        XCTAssertEqual(SteamTimeline.readable("#Timeline_UserMarker"), "User marker")
        XCTAssertEqual(SteamTimeline.readable("Boss defeated"), "Boss defeated")
    }

    // MARK: - Placing events in a clip

    func testMarkersAreRelativeToTheClipAndClippedToIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "timeline-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clipFolder = root.appending(path: "video/bg_250820_20260816_163133")
        try FileManager.default.createDirectory(at: clipFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "timelines"), withIntermediateDirectories: true)

        // The clip starts 38.124 s into the session and runs 82.5 s.
        try index(timeline: "timeline_S", recordings: [("bg_250820_20260816_163133", 38_124)])
            .write(to: root.appending(path: "gamerecording.pb"))
        try Data("""
        {"starttime":"0","entries":[
          {"time":"10000","type":"event","title":"Before the clip"},
          {"time":"30000","duration":"20000","type":"event","title":"Spans the clip start"},
          {"time":"48124","type":"event","title":"Ten seconds in"},
          {"time":"200000","type":"event","title":"After the clip"}
        ]}
        """.utf8).write(to: root.appending(path: "timelines/timeline_S.json"))

        let clip = Clip(id: "bg_250820_20260816_163133", url: clipFolder, appID: "250820", recordedAt: nil,
                        kind: .background, duration: 82.5, segmentDuration: 3, videoSegmentCount: 28,
                        byteSize: 0, probe: nil, gameName: nil)
        let markers = SteamTimeline.markers(for: clip)
        XCTAssertEqual(markers.map(\.title), ["Spans the clip start", "Ten seconds in"])
        XCTAssertEqual(markers[0].time, 0)
        XCTAssertEqual(markers[1].time, 10, accuracy: 0.001)
    }

    func testNoTimelineMeansNoMarkers() {
        let clip = Clip(id: "bg_1_20260101_000000", url: URL(fileURLWithPath: "/nonexistent/video/bg_1_20260101_000000"),
                        appID: "1", recordedAt: nil, kind: .background, duration: 10, segmentDuration: 3,
                        videoSegmentCount: 4, byteSize: 0, probe: nil, gameName: nil)
        XCTAssertTrue(SteamTimeline.markers(for: clip).isEmpty)
    }
}
