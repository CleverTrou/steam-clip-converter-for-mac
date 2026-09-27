import AppKit
import ApplicationServices

// Usage: stage.swift <x> <y> <w> <h> [card label prefixes to press...]
let args = CommandLine.arguments.dropFirst().map { $0 }
let (x, y, w, h) = (Double(args[0])!, Double(args[1])!, Double(args[2])!, Double(args[3])!)
let toPress = Array(args.dropFirst(4))

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.trevornelson.steamclipconverter").first
else { print("app not running"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
app.activate()

func attr(_ e: AXUIElement, _ n: String) -> Any? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}

guard let win = (attr(ax, "AXWindows") as? [AXUIElement])?.first else { print("no window"); exit(1) }
var pos = CGPoint(x: x, y: y), size = CGSize(width: w, height: h)
AXUIElementSetAttributeValue(win, "AXPosition" as CFString, AXValueCreate(.cgPoint, &pos)!)
AXUIElementSetAttributeValue(win, "AXSize" as CFString, AXValueCreate(.cgSize, &size)!)
Thread.sleep(forTimeInterval: 1.5)

var pressed: [String] = []
func walk(_ e: AXUIElement, _ d: Int) {
    guard d < 40 else { return }
    if (attr(e, "AXRole") as? String) == "AXButton", let label = attr(e, "AXDescription") as? String,
       let hit = toPress.first(where: { label.hasPrefix($0) }), !pressed.contains(hit) {
        AXUIElementPerformAction(e, "AXPress" as CFString)
        pressed.append(hit)
    }
    for c in (attr(e, "AXChildren") as? [AXUIElement] ?? []) { walk(c, d + 1) }
}
if !toPress.isEmpty { walk(win, 0) }
print("pressed:", pressed)

let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for i in infos where (i[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                  && (i[kCGWindowLayer as String] as? Int) == 0 {
    print("windowid:", i[kCGWindowNumber as String]!, "bounds:", i[kCGWindowBounds as String]!)
}
