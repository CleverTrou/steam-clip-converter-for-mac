import AppKit

/// The standard About panel, which already shows the icon, name, version and
/// copyright from Info.plist, plus credits: what the app does, where it lives,
/// and that it is not Valve's.
enum AboutPanel {

    static let repository = URL(string: "https://github.com/CleverTrou/steam-clip-converter-for-mac")!

    static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        // Explicit colors: an attributed string without them is drawn black,
        // which disappears in Dark Mode.
        func text(_ string: String, size: CGFloat = NSFont.smallSystemFontSize,
                  color: NSColor = .labelColor, link: URL? = nil) -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if let link { attributes[.link] = link }
            return NSAttributedString(string: string, attributes: attributes)
        }

        let credits = NSMutableAttributedString()
        credits.append(text("Converts Steam Game Recording clips into movies QuickTime, Photos and Final Cut open. "
                            + "No ffmpeg: the whole pipeline is AVFoundation.\n"))
        credits.append(text("Source code on GitHub\n", color: .linkColor, link: repository))
        credits.append(text("Steam is a trademark of Valve Corporation. This app is not affiliated with or endorsed by Valve.",
                            size: NSFont.smallSystemFontSize - 1, color: .secondaryLabelColor))
        return credits
    }
}
