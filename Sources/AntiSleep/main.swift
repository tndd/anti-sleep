import AppKit

if !RecoveryMonitor.runIfRequested() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
