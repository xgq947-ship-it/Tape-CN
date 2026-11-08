import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let delegate = AppDelegate()
    private let model = AppModel()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Preview.runIfAsked(model: model) { return }
        #if DEBUG
        if Shots.runIfAsked(model: model) { return }
        #endif
        model.start()
    }

    /// Opening Tape again (Finder, Spotlight, Launchpad) brings up its settings, the only window it has.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.openSettings(.watchlist)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
