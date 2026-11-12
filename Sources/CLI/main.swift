// click2whoosh CLI — terminal front-end for ClickManager.
//   -v          print raw Bluetooth traffic
//   --any-app   send keys whatever app is in front (default: only MyWhoosh)
// Button mapping is shared with the menu bar app (edit it there).

import Foundation

let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
let manager = ClickManager()
manager.verbose = CommandLine.arguments.contains("-v")
manager.log = { print("[\(df.string(from: Date()))] \($0)"); fflush(stdout) }
if CommandLine.arguments.contains("--any-app") { manager.onlyWhenMyWhooshFront = false }

if !manager.accessibilityOK {
    manager.log("⚠️  No Accessibility permission: keystrokes will be dropped.")
    manager.log("   Allow your terminal app in System Settings › Privacy & Security › Accessibility, then quit & reopen it.")
    manager.requestAccessibility()
}
manager.log("Mapping: " + clickButtons.map { "\($0.label)=\(manager.mapping[$0.id] ?? "?")" }.joined(separator: ", "))
manager.log("Keys go only to MyWhoosh: \(manager.onlyWhenMyWhooshFront)")

signal(SIGINT) { _ in print("\nbye"); exit(0) }
RunLoop.main.run()
