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

    private func timeline(_ entries: String, end: Int = 2_000_000) throws -> SteamTimeline.Timeline {
        let json = #"{"daterecorded":"1790731591","starttime":"0","endtime":"\#(end)","entries":[\#(entries)]}"#
        return try XCTUnwrap(SteamTimeline.Timeline(data: Data(json.utf8)))
    }

    /// Trimmed from a real Left 4 Dead 2 session.
    func testEventsScreenshotsAndMapNamesBecomeMarkers() throws {
        let parsed = try timeline("""
          {"id":"1","time":"61252","type":"gamemode","mode":2},
          {"id":"2","time":"221435","type":"state_description","title":"\\"Dead Center\\" - 1: Hotel"},
          {"id":"4","time":"367639","type":"event","title":"A Hunter pounced on you!","description":"",
           "icon":"steam_combat","priority":1000,"duration":"0","possible_clip":2},
          {"id":"9","time":"662858","type":"event","title":"You used First Aid","description":"",
           "icon":"steam_heart","priority":1000,"duration":"5000","possible_clip":2},
          {"id":"18","time":"1190501","type":"state_description","title":""},
          {"id":"20","time":"1235543","type":"screenshot","icon":"steam_screenshot","priority":1000,"handle":1},
          {"id":"99","time":"1240000","type":"error","description":"#GameRecording_RecordingFailed"}
        """)
        XCTAssertEqual(parsed.entries.map(\.title),
                       [#""Dead Center" - 1: Hotel"#, "A Hunter pounced on you!", "You used First Aid", "Screenshot"])
        XCTAssertEqual(parsed.entries.map(\.time), [221_435, 367_639, 662_858, 1_235_543])
        XCTAssertEqual(parsed.entries[2].duration, 5000)
    }

    /// Trimmed from a real Half-Life 2 session: the title and description
    /// together make the name, and states that only last through a load
    /// screen, repeat, or echo the chapter event are dropped.
    func testDescriptionsJoinTitlesAndTransientStatesAreDropped() throws {
        let parsed = try timeline("""
          {"id":"31","time":"78531","type":"gamemode","mode":2},
          {"id":"32","time":"78531","type":"state_description","title":"Loading..."},
          {"id":"36","time":"79342","type":"phase","duration":"780406","phase_id":"#hl2_chapter1_title"},
          {"id":"35","time":"79342","type":"event","title":"New Chapter","description":"POINT INSERTION",
           "icon":"steam_bookmark","priority":40,"duration":"0","possible_clip":1},
          {"id":"38","time":"80481","type":"state_description","title":"POINT INSERTION"},
          {"id":"39","time":"99478","type":"event","title":"Meet Gman",
           "description":"Rise and shine, Mr. Freeman. Rise and shine. ","icon":"npc_gman","priority":40},
          {"id":"47","time":"454509","type":"state_description","title":"Loading..."},
          {"id":"49","time":"455670","type":"state_description","title":"POINT INSERTION"},
          {"id":"72","time":"898935","type":"event","title":"Achievement Progress",
           "description":"Lambda Locator (1/45)","icon":"steam_achievement","priority":40}
        """)
        XCTAssertEqual(parsed.entries.map(\.title), [
            "New Chapter: POINT INSERTION",
            "Meet Gman: Rise and shine, Mr. Freeman. Rise and shine.",
            "Achievement Progress: Lambda Locator (1/45)",
        ])
    }

    func testALongStateThatNoEventNamesIsKept() throws {
        let parsed = try timeline("""
          {"time":"18750","type":"state_description","title":"In Menus"},
          {"time":"20290","type":"state_description","title":"Loading..."},
          {"time":"22403","type":"state_description","title":"In Menus"}
        """, end: 78_531)
        XCTAssertEqual(parsed.entries.map(\.title), ["In Menus"])
        XCTAssertEqual(parsed.entries.map(\.time), [22_403])
    }

    /// Not yet seen in a real file: Steam's own marker, named by a token.
    func testTokenOnlyEntriesAreMadeReadable() throws {
        let parsed = try timeline(##"{"time":"9000","type":"usermarker","description":"#GameRecording_UserMarker"}"##)
        XCTAssertEqual(parsed.entries.map(\.title), ["User marker"])
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
