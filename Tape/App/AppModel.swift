import AppKit
import Observation
import ServiceManagement

/// Wires Tape together: settings, prices, brand colours, the Dock, the tape and its menus.
@Observable
final class AppModel {
    let settings: Settings
    let market = Market()
    let brands = Brands()
    @ObservationIgnored let dock = DockWatcher()

    var isPaused = false
    /// What the wallpaper behind the tape looks like, when contrast is automatic.
    var ground: Ground = .dark

    @ObservationIgnored private(set) var ticker: TickerController!
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var settingsWindow: SettingsWindowController?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var menuBarObservation: Task<Void, Never>?
    @ObservationIgnored private var wallpaperTimer: Timer?

    init(settings: Settings = .shared) {
        self.settings = settings
    }

    func start() {
        ticker = TickerController(model: self)
        market.interval = .seconds(settings.refreshInterval)
        market.symbols = settings.watchlist.map(\.symbol)
        market.start()
        dock.start()
        ticker.start()

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.market.refreshNow() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ticker.recheckWallpaper() }
        })
        wallpaperTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ticker.recheckWallpaper() }
        }
        wallpaperTimer?.tolerance = 30

        menuBarObservation = Task { [weak self] in
            guard let settings = self?.settings else { return }
            for await (show, interval) in Observations({ @MainActor in (settings.showMenuBarIcon, settings.refreshInterval) }) {
                self?.updateStatusItem(visible: show)
                if self?.market.interval != .seconds(interval) {
                    self?.market.interval = .seconds(interval)
                    self?.market.refreshNow()
                }
            }
        }

        if !settings.hasLaunchedBefore {
            settings.hasLaunchedBefore = true
            openSettings(.watchlist)
        }
    }

    // MARK: Drawing

    func tapeStyle(scale: CGFloat) -> TapeStyle {
        tapeStyle(scale: scale, design: settings.design)
    }

    func tapeStyle(scale: CGFloat, design: TapeDesign) -> TapeStyle {
        var ground: Ground = switch settings.contrast {
        case .automatic: self.ground
        case .lightText: .dark
        case .darkText: .light
        }
        let glass = design == .focus && settings.focusGlass
        // On glass, the ground is the glass.
        if glass { ground = .dark }
        return TapeStyle(
            fontSize: settings.fontSize,
            ground: ground,
            showCurrency: settings.showCurrency,
            changeStyle: settings.changeStyle,
            reference: settings.reference,
            scale: scale,
            design: design,
            focusGlass: glass
        )
    }

    /// One listing on a scrolling tape, in the style's design. Focus draws its listings together.
    func renderItem(for watch: WatchItem, style: TapeStyle, flash: Change.Direction? = nil) -> TapeItem? {
        guard style.design != .focus, let quote = market.quotes[watch.symbol] else { return nil }
        let label = watch.label ?? Format.label(for: watch.symbol, kind: quote.kind)
        let brand = settings.brandColors ? brands.color(for: watch) : nil
        return DesignRenderer.render(label: label, brand: brand, quote: quote, style: style, flash: flash)
    }

    /// The watchlist as Focus slides, on one grid that fits a window `room` points wide.
    func focusSlides(style: TapeStyle, room: CGFloat) -> [FocusSlide] {
        let listings = settings.watchlist.compactMap(focusListing(for:))
        return FocusRenderer.slides(for: listings, style: style, room: room)
    }

    /// One listing for Focus: with its logo, or a glyph for indices, currencies, futures and Bitcoin.
    func focusListing(for watch: WatchItem) -> FocusListing? {
        guard let quote = market.quotes[watch.symbol] else { return nil }
        let label = watch.label ?? Format.label(for: watch.symbol, kind: quote.kind)
        let brand = settings.brandColors ? brands.color(for: watch) : nil
        let logo = brands.logo(for: watch.symbol)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return FocusListing(label: label, name: quote.name, brand: brand, logo: logo, glyph: Self.glyph(for: quote.kind, label: label), quote: quote)
    }

    /// What stands in for a logo: a chart for indices, arrows for currencies, a crate for futures, ₿ for Bitcoin.
    static func glyph(for kind: Quote.Kind, label: String) -> NSImage? {
        let name: String? = switch kind {
        case .index: "chart.line.uptrend.xyaxis"
        case .currency: "arrow.left.arrow.right"
        case .future: "shippingbox.fill"
        case .crypto: label == "BTC" ? "bitcoinsign" : nil
        default: nil
        }
        return name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .semibold))
    }

    // MARK: Commands

    func togglePause() {
        isPaused.toggle()
    }

    func openSettings(_ tab: SettingsTab = .watchlist) {
        let controller = settingsWindow ?? SettingsWindowController(model: self)
        settingsWindow = controller
        controller.show(tab)
    }

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSSound.beep()
            }
        }
    }

    /// Pause, refresh, settings and quit, shared by the menu bar and the tape's own menu.
    func addCommonItems(to menu: NSMenu) {
        let designs = NSMenu()
        for design in TapeDesign.allCases {
            let item = NSMenuItem.make(design.title) { [weak self] in self?.settings.design = design }
            item.state = settings.design == design ? .on : .off
            item.toolTip = design.summary
            designs.addItem(item)
        }
        let designItem = NSMenuItem(title: "Design", action: nil, keyEquivalent: "")
        designItem.submenu = designs
        menu.addItem(designItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.make(isPaused ? "Resume Tape" : "Pause Tape") { [weak self] in self?.togglePause() })
        menu.addItem(NSMenuItem.make("Refresh Now", key: "r") { [weak self] in self?.market.refreshNow() })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.make("Edit Watchlist…") { [weak self] in self?.openSettings(.watchlist) })
        menu.addItem(NSMenuItem.make("Settings…", key: ",") { [weak self] in self?.openSettings(.appearance) })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.make("Quit Tape", key: "q") { NSApp.terminate(nil) })
    }

    // MARK: Menu bar

    private func updateStatusItem(visible: Bool) {
        guard visible else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Mark.templateImage()
        item.button?.toolTip = "Tape"
        let menu = NSMenu()
        menu.delegate = StatusMenuDelegate.shared
        StatusMenuDelegate.shared.model = self
        item.menu = menu
        statusItem = item
    }

    fileprivate func statusLine() -> String {
        if let problem = market.problem { return problem }
        guard let updated = market.updatedAt else { return market.isLoading ? "Loading prices…" : "No prices yet" }
        let open = settings.watchlist.compactMap { market.quotes[$0.symbol] }.filter { $0.isTrading() }.count
        let time = updated.formatted(date: Calendar.current.isDateInToday(updated) ? .omitted : .abbreviated, time: .shortened)
        let markets = open == 0 ? "markets closed" : open == 1 ? "1 listing trading" : "\(open) listings trading"
        return "Updated \(time) · \(markets)"
    }
}

/// Rebuilds the menu bar menu each time it opens, so it always says what's true right now.
final class StatusMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = StatusMenuDelegate()
    weak var model: AppModel?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        let status = NSMenuItem(title: model.statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !DockLocator.canReadDock {
            menu.addItem(NSMenuItem.make("Fit Exactly to the Dock…") { model.openSettings(.placement) })
        }
        menu.addItem(.separator())
        model.addCommonItems(to: menu)
    }
}
