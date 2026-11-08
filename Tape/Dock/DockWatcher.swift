import AppKit

/// Follows the Dock as it grows and shrinks (apps launching and quitting, preferences, screens),
/// and, when the Dock hides itself, whether it's showing right now.
final class DockWatcher {
    private(set) var layout: DockLayout?
    /// False while an auto-hiding Dock is tucked away.
    private(set) var isRevealed = true

    var onChange: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?
    private var mouseMonitor: Any?
    private var revealWork: Task<Void, Never>?
    private var settleWork: Task<Void, Never>?

    func start() {
        measure()
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
        ]
        for name in names {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.measureAfterDockAnimates() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.measureAfterDockAnimates() }
        })
        // Catches everything without a notification: Dock settings, recents shuffling, drag-and-drop onto the Dock.
        poll = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.measure() }
        }
        poll?.tolerance = 0.5
    }

    /// The Dock animates for about half a second; measure as it settles and once more after.
    func measureAfterDockAnimates() {
        settleWork?.cancel()
        settleWork = Task { [weak self] in
            for pause in [50, 400, 650] {
                try? await Task.sleep(for: .milliseconds(pause))
                guard !Task.isCancelled else { return }
                self?.measure()
            }
        }
    }

    func measure() {
        let fresh = DockLocator.locate()
        let autohideChanged = fresh?.autohides != layout?.autohides
        guard fresh != layout else { return }
        layout = fresh
        if autohideChanged { configureAutohide() }
        onChange?()
    }

    // MARK: Auto-hiding Dock

    private func configureAutohide() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        guard layout?.autohides == true else {
            setRevealed(true)
            return
        }
        setRevealed(false)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
    }

    /// The Dock slides in when the pointer rests on its edge and away once it leaves the Dock.
    private func trackMouse() {
        guard let layout else { return }
        let mouse = NSEvent.mouseLocation
        let frame = layout.screenFrame
        guard frame.insetBy(dx: -1, dy: -1).contains(mouse) else { return }
        let atEdge = mouse.y <= frame.minY + 2
        let inDock = mouse.y <= frame.minY + layout.tileSize + 30
        if !isRevealed, atEdge {
            guard revealWork == nil else { return }
            revealWork = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                self?.revealWork = nil
                guard !Task.isCancelled else { return }
                if NSEvent.mouseLocation.y <= frame.minY + layout.tileSize + 30 { self?.setRevealed(true) }
            }
        } else if isRevealed, !inDock {
            revealWork?.cancel()
            revealWork = nil
            setRevealed(false)
        }
    }

    private func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        onChange?()
    }
}
