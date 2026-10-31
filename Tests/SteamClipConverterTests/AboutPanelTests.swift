import AppKit
import XCTest
@testable import SteamClipConverter

final class AboutPanelTests: XCTestCase {

    /// Text with a fixed color, or none, is drawn black and vanishes in Dark
    /// Mode. System catalog colors follow the appearance.
    func testEveryRunOfTheCreditsUsesAnAppearanceAwareColor() {
        let credits = AboutPanel.credits
        credits.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: credits.length)) { value, range, _ in
            let run = credits.attributedSubstring(from: range).string
            guard let color = value as? NSColor else { return XCTFail("no color on \"\(run)\"") }
            XCTAssertEqual(color.type, .catalog, "fixed color on \"\(run)\"")
        }
    }

    func testCreditsLinkToTheRepository() {
        let credits = AboutPanel.credits
        var links: [URL] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links, [AboutPanel.repository])
        XCTAssertTrue(credits.string.contains("not affiliated"))
    }
}
