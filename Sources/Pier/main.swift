import AppKit

// Debug/render flags short-circuit before the app loop (each one exits).
DebugFlags.handleIfPresent(CommandLine.arguments)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
