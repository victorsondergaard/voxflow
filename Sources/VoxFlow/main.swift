import AppKit

// VoxFlow — local, free voice dictation for macOS.
// Menu bar accessory app: no Dock icon (also enforced by LSUIElement in Info.plist).

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
