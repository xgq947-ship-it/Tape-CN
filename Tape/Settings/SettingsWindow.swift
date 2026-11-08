import AppKit
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case watchlist, appearance, placement, general

    var title: String {
        switch self {
        case .watchlist: "Watchlist"
        case .appearance: "Appearance"
        case .placement: "Placement"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .watchlist: "list.bullet"
        case .appearance: "textformat.size"
        case .placement: "dock.rectangle"
        case .general: "gearshape"
        }
    }
}

/// The classic Mac settings window: toolbar tabs, each pane its own size.
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(model: AppModel) {
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for tab in SettingsTab.allCases {
            let root: AnyView = switch tab {
            case .watchlist: AnyView(WatchlistPane(model: model))
            case .appearance: AnyView(AppearancePane(model: model))
            case .placement: AnyView(PlacementPane(model: model))
            case .general: AnyView(GeneralPane(model: model))
            }
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = tab.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("TapeSettings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: SettingsTab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
        if window?.isVisible != true { window?.center() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
