import AppKit
import ApplicationServices

/// Where the Dock is, in Cocoa screen coordinates (origin bottom left of the main screen).
nonisolated struct DockLayout: Equatable, Sendable {
    nonisolated enum Edge: String, Sendable { case bottom, left, right }

    var edge: Edge
    var autohides: Bool
    /// The screen the Dock lives on.
    var screenFrame: CGRect
    var visibleFrame: CGRect
    /// The Dock's glass, edge to edge. Measured when Tape may read the Dock (Accessibility), estimated otherwise.
    var tiles: CGRect
    var tileSize: CGFloat
    var isExact: Bool
}

/// Measures the Dock. With Accessibility access it asks the Dock itself for its frame; without,
/// it rebuilds the row from the Dock's own preferences and the apps that are running.
enum DockLocator {
    static var canReadDock: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the person to Privacy & Security → Accessibility.
    static func askForAccess() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func locate() -> DockLayout? {
        let prefs = DockPreferences.read()
        let measured = canReadDock ? measuredTiles() : nil
        guard let screen = dockScreen(prefs: prefs, tiles: measured) else { return nil }
        let tiles = measured ?? estimatedTiles(on: screen, prefs: prefs)
        return DockLayout(
            edge: prefs.edge,
            autohides: prefs.autohides,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            tiles: tiles,
            tileSize: prefs.tileSize,
            isExact: measured != nil
        )
    }

    /// Everything Tape knows about the Dock, for checking a fit by hand.
    static func report() -> String {
        var lines = ["trusted \(canReadDock)"]
        let prefs = DockPreferences.read()
        lines.append("tile \(prefs.tileSize) edge \(prefs.edge) autohide \(prefs.autohides) magnify \(prefs.magnifies)")
        for screen in NSScreen.screens { lines.append("screen \(screen.frame) visible \(screen.visibleFrame)") }
        lines.append("located \(String(describing: locate()))")
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return lines.joined(separator: "\n") }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        for child in attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            let role = attribute(child, kAXRoleAttribute) as? String ?? "?"
            lines.append("\(role) \(String(describing: point(child, kAXPositionAttribute))) \(String(describing: size(child, kAXSizeAttribute)))")
            for item in (attribute(child, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(3) {
                let title = attribute(item, kAXTitleAttribute) as? String ?? "?"
                lines.append("  \(title) \(String(describing: point(item, kAXPositionAttribute))) \(String(describing: size(item, kAXSizeAttribute)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Measured

    /// The Dock's glass, straight from its accessibility tree. The list runs edge to edge of the
    /// glass, but reaches higher than it; the icons in it are centred on the glass, so they give
    /// its height. (Measured on macOS 27: list 10–90 pt up the screen, icons and glass 5–85.)
    static func measuredTiles() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let children = attribute(app, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children where (attribute(child, kAXRoleAttribute) as? String) == kAXListRole {
            guard let position = point(child, kAXPositionAttribute), let size = size(child, kAXSizeAttribute),
                  size.width > 0, size.height > 0 else { continue }
            var frame = CGRect(origin: position, size: size)
            if let icon = (attribute(child, kAXChildrenAttribute) as? [AXUIElement])?.first,
               let top = point(icon, kAXPositionAttribute), let cell = self.size(icon, kAXSizeAttribute), cell.height > 0 {
                frame.origin.y = top.y
                frame.size.height = cell.height
            }
            // Accessibility measures from the top left of the main screen; Cocoa from the bottom left.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        // The type check above guarantees this is an AXValue.
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    // MARK: Estimated

    private static func dockScreen(prefs: DockPreferences, tiles: CGRect?) -> NSScreen? {
        let screens = NSScreen.screens
        if let tiles, let screen = screens.first(where: { $0.frame.intersects(tiles) }) { return screen }
        // The screen whose usable area gives up room on the Dock's edge.
        let reserving = screens.first { screen in
            switch prefs.edge {
            case .bottom: screen.visibleFrame.minY - screen.frame.minY > 8
            case .left: screen.visibleFrame.minX - screen.frame.minX > 8
            case .right: screen.frame.maxX - screen.visibleFrame.maxX > 8
            }
        }
        return reserving ?? screens.first
    }

    /// Rebuilds the Dock: Finder, the pinned apps, running and recent apps, folders, the Trash.
    static func estimatedTiles(on screen: NSScreen, prefs: DockPreferences) -> CGRect {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
        let width = estimatedWidth(prefs: prefs, running: running)
        let tile = prefs.tileSize
        let frame = screen.frame
        let visible = screen.visibleFrame
        switch prefs.edge {
        case .bottom:
            guard !prefs.autohides else {
                return CGRect(x: frame.midX - width / 2, y: frame.minY + 7, width: width, height: tile)
            }
            // The glass floats: its top 2 points under the space the Dock keeps for itself, and as
            // tall as an icon and 9 points either side (measured at 60 and 67 points).
            let glass = tile + 18
            return CGRect(x: frame.midX - width / 2, y: visible.minY - 2 - glass, width: width, height: glass)
        case .left:
            return CGRect(x: frame.minX + 4, y: frame.midY - width / 2, width: tile, height: width)
        case .right:
            return CGRect(x: frame.maxX - tile - 4, y: frame.midY - width / 2, width: tile, height: width)
        }
    }

    static func estimatedWidth(prefs: DockPreferences, running: [String]) -> CGFloat {
        let pinned = Set(prefs.pinnedApps)
        let unpinnedRunning = Array(Set(running).subtracting(pinned).subtracting(["com.apple.finder"]))
        var recents = 0
        if prefs.showsRecents {
            let recentNotRunning = prefs.recentApps.filter { !pinned.contains($0) && !running.contains($0) }
            recents = unpinnedRunning.count + min(recentNotRunning.count, max(0, 3 - unpinnedRunning.count))
        }
        let appTiles = 1 + prefs.pinnedTileUnits + Double(prefs.showsRecents ? 0 : unpinnedRunning.count)
        let otherTiles = Double(prefs.others) + 1
        let dividers = 1 + (prefs.showsRecents && recents > 0 ? 1 : 0)
        let tile = Double(prefs.tileSize)
        // Measured on macOS 27's Dock: icons sit 1.06 tiles apart, a divider takes about half a tile,
        // and the glass reaches 0.13 of a tile past the outer icons on each side.
        let icons = appTiles + Double(recents) + otherTiles
        return CGFloat(icons * tile * 1.06 + Double(dividers) * tile * 0.485 + tile * 0.26)
    }
}

/// The Dock's own preferences (com.apple.dock).
nonisolated struct DockPreferences: Equatable, Sendable {
    var edge: DockLayout.Edge = .bottom
    var autohides = false
    var tileSize: CGFloat = 48
    var pinnedApps: [String] = []
    /// Pinned tiles, with small spacers counted as half.
    var pinnedTileUnits: Double = 0
    var recentApps: [String] = []
    var others = 0
    var showsRecents = true
    var magnifies = false

    static func read() -> DockPreferences {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        guard let dock = UserDefaults(suiteName: "com.apple.dock") else { return DockPreferences() }
        var prefs = DockPreferences()
        prefs.edge = DockLayout.Edge(rawValue: dock.string(forKey: "orientation") ?? "bottom") ?? .bottom
        prefs.autohides = dock.bool(forKey: "autohide")
        if let size = dock.object(forKey: "tilesize") as? Double, size > 8 { prefs.tileSize = CGFloat(size) }
        prefs.showsRecents = dock.object(forKey: "show-recents") as? Bool ?? true
        prefs.magnifies = dock.bool(forKey: "magnification")
        let apps = dock.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        for tile in apps {
            switch tile["tile-type"] as? String {
            case "small-spacer-tile": prefs.pinnedTileUnits += 0.5
            case "spacer-tile", "flex-spacer-tile": prefs.pinnedTileUnits += 1
            default:
                prefs.pinnedTileUnits += 1
                if let id = (tile["tile-data"] as? [String: Any])?["bundle-identifier"] as? String { prefs.pinnedApps.append(id) }
            }
        }
        prefs.recentApps = (dock.array(forKey: "recent-apps") as? [[String: Any]] ?? []).compactMap {
            ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
        }
        prefs.others = (dock.array(forKey: "persistent-others") ?? []).count
        return prefs
    }
}
