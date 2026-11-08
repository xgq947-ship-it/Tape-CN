import AppKit
import SwiftUI

/// The detail card's own see-through panel, floating just above the tape.
final class CardController {
    private let model: AppModel
    private var panel: NSPanel?
    private var hosting: NSHostingView<DetailCard>?
    private var monitors: [Any] = []
    private(set) var symbol: String?
    private(set) var isOpen = false

    var onClose: (() -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    func show(symbol: String, above item: NSRect, tapeFrame: NSRect) {
        self.symbol = symbol
        let panel = self.panel ?? makePanel()
        let view = NSHostingView(rootView: DetailCard(symbol: symbol, model: model))
        view.sizingOptions = [.intrinsicContentSize]
        panel.contentView = view
        hosting = view
        let size = view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(tapeFrame) } ?? NSScreen.main
        let bounds = screen?.frame ?? tapeFrame
        var origin = CGPoint(x: (item.midX - size.width / 2).rounded(), y: tapeFrame.maxY - 6)
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
        let frame = CGRect(origin: origin, size: size)

        let wasOpen = isOpen
        isOpen = true
        if wasOpen {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame.offsetBy(dx: 0, dy: -8), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
            watchForOutsideClicks()
        }
    }

    func close() {
        guard isOpen, let panel else { return }
        isOpen = false
        symbol = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -6), display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                if !self.isOpen { panel.orderOut(nil) }
            }
        }
        onClose?()
    }

    /// Keeps the card's size right when its contents change (a price arrives, a sparkline grows).
    func refresh() {
        guard isOpen, let symbol, let panel, let hosting else { return }
        guard model.settings.watchlist.contains(where: { $0.symbol == symbol }) else {
            close()
            return
        }
        let size = hosting.fittingSize
        guard size != panel.frame.size else { return }
        var frame = panel.frame
        frame.origin.x += (frame.width - size.width) / 2
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    private func watchForOutsideClicks() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                // Clicks on the tape decide for themselves (another listing swaps the card, the same one closes it).
                if event.window !== panel, !(event.window is TapePanel) { self.close() }
            }
            return event
        }) {
            monitors.append(local)
        }
    }
}
