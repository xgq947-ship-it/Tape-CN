import AppKit
import Observation

/// A borderless, see-through panel at the Dock's level, on every Space but not over full-screen apps.
final class TapePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // Said explicitly, so the gaps between listings count as the tape too: otherwise the pointer
        // "leaves" whenever a gap slides under it and the tape starts moving again mid-read.
        ignoresMouseEvents = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Puts the tape beside the Dock and keeps what it shows in step with prices and settings.
final class TickerController {
    private let model: AppModel
    private let panel = TapePanel()
    private let stage = TapeStage()
    private let card: CardController

    private var lastPrices: [String: Double] = [:]
    private var lastDesign: TapeDesign?
    /// The strip's width and the screen's scale the listings were last drawn for.
    private var drawnFor: (width: CGFloat, scale: CGFloat)?
    private var wallpaperKey: String?
    private var observation: Task<Void, Never>?
    private var windowObservers: [NSObjectProtocol] = []
    private var isShown = false

    private var tickerView: TickerView { stage.tape }

    init(model: AppModel) {
        self.model = model
        card = CardController(model: model)
        panel.contentView = stage
        let select: (String, NSRect) -> Void = { [weak self] symbol, rect in self?.toggleCard(for: symbol, at: rect) }
        stage.tape.onSelect = select
        stage.focus.onSelect = select
        stage.tape.onMenu = { [weak self] symbol, _ in self?.menu(for: symbol) }
        stage.focus.onMenu = { [weak self] symbol, _ in self?.menu(for: symbol) }
        stage.onMenu = { [weak self] _ in self?.menu(for: nil) }
        stage.tape.onMiss = { [weak self] in self?.card.close() }
        card.onClose = { [weak self] in
            self?.stage.tape.isHolding = false
            self?.stage.focus.isHolding = false
        }
    }

    func start() {
        model.dock.onChange = { [weak self] in self?.place() }
        // Arriving on a screen with another scale (the laptop's Retina panel after a 1× monitor).
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        observation = Task { [weak self] in
            guard let model = self?.model else { return }
            let changes = Observations { @MainActor in
                // Everything the drawing depends on.
                _ = model.market.quotes
                _ = model.brands.extracted
                _ = model.brands.logos
                let settings = model.settings
                _ = (settings.watchlist, settings.fontSize, settings.showCurrency, settings.changeStyle, settings.design)
                _ = (settings.reference, settings.contrast, settings.brandColors, settings.speed)
                _ = (settings.pauseOnHover, settings.side, settings.dockGap, model.isPaused, model.ground)
                _ = (settings.focusDwell, settings.focusGlass)
            }
            for await _ in changes {
                self?.refresh()
            }
        }
        place()
        refresh()
    }

    /// The next listing in Focus.
    func flipFocus(by delta: Int = 1) {
        stage.focus.advance(by: delta)
    }

    /// Where the tape is on screen, while it's showing.
    var tapeFrame: CGRect? { isShown ? panel.frame : nil }

    // MARK: Placement

    func place() {
        guard let layout = model.dock.layout,
              let frame = Self.frame(for: layout, side: model.settings.side, gap: model.settings.dockGap, height: style.metrics.height) else {
            hide()
            return
        }
        let target = model.dock.isRevealed ? frame : frame.offsetBy(dx: 0, dy: -frame.height - 8)
        let visible = model.dock.isRevealed
        if !isShown {
            panel.setFrame(target, display: true)
            panel.alphaValue = visible ? 1 : 0
            panel.orderFrontRegardless()
            isShown = true
        } else if panel.frame != target || (panel.alphaValue == 1) != visible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = visible == (panel.alphaValue == 1) ? 0.32 : 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = visible ? 1 : 0
            }
        }
        stage.focus.centre = Self.corner(for: layout, side: model.settings.side).map { $0 - frame.minX }
        sampleWallpaper(for: frame)
        // Moved to another screen, or the Dock grew: Focus lays out for the new width, and every
        // design redraws for a screen with a different scale.
        let scale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let drawn = drawnFor, drawn.scale != scale || (style.design == .focus && abs(drawn.width - frame.width) >= 1) {
            refresh()
        }
    }

    private func hide() {
        guard isShown else { return }
        panel.orderOut(nil)
        isShown = false
    }

    /// The narrowest strip worth showing: Focus's smallest card still fits, and a tape still reads.
    /// A long Dock on a laptop leaves about this much (a 1512 pt screen with seventeen icons).
    static let minimumWidth: CGFloat = 56

    /// The middle of the corner beside the Dock, between the screen's edge and the glass, in screen
    /// coordinates; nil when the Dock is on a side and the tape runs along the bottom.
    static func corner(for layout: DockLayout, side: DockSide) -> CGFloat? {
        guard layout.edge == .bottom else { return nil }
        return switch side {
        case .left: (layout.screenFrame.minX + layout.tiles.minX) / 2
        case .right: (layout.tiles.maxX + layout.screenFrame.maxX) / 2
        }
    }

    /// The strip between the screen's edge and the Dock, centred on the Dock's icons.
    static func frame(for layout: DockLayout, side: DockSide, gap: CGFloat, height: CGFloat) -> CGRect? {
        let margin: CGFloat = 14
        let screen = layout.screenFrame
        switch layout.edge {
        case .bottom:
            // An auto-hiding Dock is measured while it may be out of sight; centre on where it shows.
            let midY = layout.autohides ? screen.minY + (layout.tileSize + 14) / 2 : layout.tiles.midY
            var minX: CGFloat, maxX: CGFloat
            // Whole points at the Dock's end too, so the window sits on the pixel grid.
            switch side {
            case .left:
                minX = screen.minX + margin
                maxX = (layout.tiles.minX - gap).rounded(.down)
                // Beside a long Dock every point counts: take some of the screen's margin back.
                if maxX - minX < 100 { minX = screen.minX + margin / 2 }
            case .right:
                minX = (layout.tiles.maxX + gap).rounded(.up)
                maxX = screen.maxX - margin
                if maxX - minX < 100 { maxX = screen.maxX - margin / 2 }
            }
            guard maxX - minX >= Self.minimumWidth else { return nil }
            return CGRect(x: minX, y: max(screen.minY, (midY - height / 2).rounded()), width: maxX - minX, height: height)
        case .left, .right:
            // With the Dock on a side, the tape runs along the bottom of the screen instead.
            let visible = layout.visibleFrame
            return CGRect(x: visible.minX + margin, y: screen.minY + 2, width: visible.width - margin * 2, height: height)
        }
    }

    // MARK: Wallpaper

    private func sampleWallpaper(for frame: CGRect) {
        guard model.settings.contrast == .automatic else { return }
        guard let screen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }),
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        let region = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)|\(region.integral)"
        guard key != wallpaperKey else { return }
        wallpaperKey = key
        let size = screen.frame.size
        let scaling = Wallpaper.scaling(for: screen)
        Task { [weak self] in
            let sample = await Task.detached(priority: .utility) {
                Wallpaper.sample(imageAt: url, screenSize: size, region: region, scaling: scaling)
            }.value
            guard let self, let sample, sample.ground != self.model.ground else { return }
            self.model.ground = sample.ground
        }
    }

    /// The wallpaper can change without telling anyone; look again now and then.
    func recheckWallpaper() {
        wallpaperKey = nil
        if isShown { sampleWallpaper(for: panel.frame) }
    }

    // MARK: Drawing

    var style: TapeStyle {
        model.tapeStyle(scale: panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    func refresh() {
        let settings = model.settings
        let width = model.dock.layout.flatMap { Self.frame(for: $0, side: settings.side, gap: settings.dockGap, height: style.metrics.height)?.width } ?? 420
        drawnFor = (width, panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        model.market.symbols = settings.watchlist.map(\.symbol)
        model.brands.prepare(settings.watchlist.map(\.symbol))
        let style = self.style
        let design = style.design
        let switched = lastDesign != nil && lastDesign != design
        lastDesign = design
        stage.configure(design: design, metrics: style.metrics, scale: style.scale, focusGlass: style.focusGlass)
        tickerView.speed = settings.speed
        tickerView.pausesOnHover = settings.pauseOnHover
        tickerView.isPaused = model.isPaused
        stage.focus.pausesOnHover = settings.pauseOnHover
        stage.focus.isPaused = model.isPaused
        stage.focus.alignsTrailing = settings.side == .left
        stage.focus.metrics = FocusMetrics(fontSize: style.fontSize, glass: style.focusGlass)
        stage.focus.dwell = settings.focusDwell

        if design == .focus {
            tickerView.setItems([], animated: false)
            stage.focus.setSlides(model.focusSlides(style: style, room: width))
        } else {
            stage.focus.setSlides([])
            var items: [TapeItem] = []
            var flashes: [(TapeItem, TapeItem)] = []
            for watch in settings.watchlist {
                guard let quote = model.market.quotes[watch.symbol], let item = model.renderItem(for: watch, style: style) else { continue }
                items.append(item)
                if !switched, let last = lastPrices[watch.symbol], last != quote.price,
                   let flashed = model.renderItem(for: watch, style: style, flash: quote.price > last ? .up : .down) {
                    flashes.append((flashed, item))
                }
            }
            // A new design arrives whole; a new price arrives with a flash.
            if switched { tickerView.setItems([], animated: false) }
            tickerView.setItems(items, animated: isShown && !switched)
            for (flashed, item) in flashes { tickerView.flash(flashed, settlingTo: item) }
        }
        for watch in settings.watchlist {
            if let quote = model.market.quotes[watch.symbol] { lastPrices[watch.symbol] = quote.price }
        }
        place()
        card.refresh()
    }

    // MARK: Card and menu

    private func toggleCard(for symbol: String, at rect: NSRect) {
        if card.symbol == symbol, card.isOpen {
            card.close()
            return
        }
        showCard(for: symbol, at: rect)
    }

    func showCard(for symbol: String, at rect: NSRect) {
        stage.tape.isHolding = true
        stage.focus.isHolding = true
        card.show(symbol: symbol, above: rect, tapeFrame: panel.frame)
    }

    private func menu(for symbol: String?) -> NSMenu {
        let menu = NSMenu()
        if let symbol {
            let label = model.settings.watchlist.first { $0.symbol == symbol }?.label ?? Format.label(for: symbol, kind: model.market.quotes[symbol]?.kind)
            menu.addItem(NSMenuItem.make("Show \(label)") { [weak self] in
                guard let self, let rect = self.stage.tape.screenRect(of: symbol) ?? self.stage.focus.screenRect(of: symbol) else { return }
                self.toggleCard(for: symbol, at: rect)
            })
            menu.addItem(NSMenuItem.make("Open in Yahoo Finance") { NSWorkspace.shared.open(Yahoo.pageURL(for: symbol)) })
            if let quote = model.market.quotes[symbol] {
                menu.addItem(NSMenuItem.make("Copy Price") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Format.number(quote.price, decimals: quote.decimals), forType: .string)
                })
            }
            menu.addItem(NSMenuItem.make("Remove from Tape") { [weak self] in self?.model.settings.remove(symbol) })
            menu.addItem(.separator())
        }
        model.addCommonItems(to: menu)
        return menu
    }
}

/// Menu items that run a closure.
extension NSMenuItem {
    static func make(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuHandler(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuHandler.run), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        // The target is weak; the represented object keeps the handler alive as long as the item.
        item.representedObject = target
        return item
    }
}

private final class MenuHandler: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}
