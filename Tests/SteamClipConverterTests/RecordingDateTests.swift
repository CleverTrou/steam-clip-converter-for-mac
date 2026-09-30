import XCTest
@testable import SteamClipConverter

final class RecordingDateTests: XCTestCase {

    private var root: URL!
    private var savedTimeZone: TimeZone!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "date-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "bg_550_20260930_012635"),
                                                withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "bg_550_20260930_012635/session.mpd"))
        // Recorded on a PC set to US Central, which is where the bug showed.
        savedTimeZone = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
    }

    override func tearDownWithError() throws {
        NSTimeZone.default = savedTimeZone
        try? FileManager.default.removeItem(at: root)
    }

    private func clip() throws -> Clip {
        try XCTUnwrap(ClipScanner.makeClip(folder: root.appending(path: "bg_550_20260930_012635"), kind: .background))
    }

    /// Its timeline, timeline_55020260930_012631, has daterecorded 1790731591:
    /// the same digits in UTC, four seconds earlier.
    func testFolderNamesAreUTC() throws {
        XCTAssertEqual(try clip().recordedAt, Date(timeIntervalSince1970: 1_790_731_595))
        XCTAssertEqual(try clip().outputStem, "App 550 2026-09-29 20-26-35")
    }

    func testExportsNamedFromTheFolderDigitsAreStillRecognised() throws {
        let exports = root.appending(path: "exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let old = exports.appending(path: "App 550 2026-09-30 01-26-35.mov")
        try Data().write(to: old)

        var records: [String: ConversionRecord] = [:]
        ConversionStore.adopt(clips: [try clip()], outputFolder: exports, into: &records)
        XCTAssertEqual(records["bg_550_20260930_012635"]?.outputURL.lastPathComponent, old.lastPathComponent)
    }
}
