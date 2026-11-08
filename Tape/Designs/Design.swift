import AppKit

/// The six looks Tape can wear. Each one differs in material, colour, type and motion, not just in tint.
nonisolated enum TapeDesign: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Text only, shadowed like the labels on the desktop.
    case classic
    /// A rail of Liquid Glass beside the Dock, each listing in its own capsule.
    case liquid
    /// A dot-matrix LED ticker on smoked black, stepping a dot at a time like the real thing.
    case led
    /// A strip of printed ticker tape: cream paper, serif names, ink colours.
    case paper
    /// No background at all: every listing floats in a glow the colour and size of its move.
    case aura
    /// No scrolling: one listing at a time, large, with its logo and today's path.
    case focus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .liquid: "Liquid"
        case .led: "LED"
        case .paper: "Paper"
        case .aura: "Aura"
        case .focus: "Focus"
        }
    }

    var summary: String {
        switch self {
        case .classic: "Text only, like desktop labels"
        case .liquid: "Glass capsules, made of the Dock's material"
        case .led: "Dot-matrix ticker on smoked black"
        case .paper: "Printed ticker tape"
        case .aura: "Each move glows its own colour"
        case .focus: "One at a time, with logo and chart"
        }
    }

    /// Whether the person's contrast choice applies; the others bring their own ground.
    var followsWallpaper: Bool { self == .classic || self == .aura || self == .focus }
    var scrolls: Bool { self != .focus }
}

/// The geometry of a design at a text size: how tall its window is, where the backdrop and the
/// moving tape sit inside it, and how listings are spaced.
nonisolated struct DesignMetrics: Equatable, Sendable {
    var height: CGFloat
    /// The backdrop's frame inside the window (glass rail, LED panel, paper), if it has one.
    var backdropInset: CGFloat
    /// The tape's frame inside the backdrop (or the window).
    var tapeInsets: CGSize
    var spacing: CGFloat
    var fade: CGFloat
    /// Motion in whole steps of this many points (the LED's dot pitch), or smooth.
    var step: CGFloat?
    var cornerRadius: CGFloat

    init(design: TapeDesign, fontSize: CGFloat, scale: CGFloat) {
        let f = fontSize
        switch design {
        case .classic:
            height = (f * 3).rounded()
            backdropInset = 0
            tapeInsets = .zero
            spacing = (f * 2.1).rounded()
            fade = (f * 2).rounded()
            step = nil
            cornerRadius = 0
        case .liquid:
            let rail = LiquidRenderer.pillHeight(fontSize: f) + 8
            height = rail + 10
            backdropInset = 5
            tapeInsets = CGSize(width: (rail / 2 - 4).rounded(), height: 0)
            spacing = 7
            fade = 14
            step = nil
            cornerRadius = rail / 2
        case .led:
            let pitch = LEDRenderer.pitch(fontSize: f, scale: scale)
            let panel = pitch * 9 + 10
            height = panel + 12
            backdropInset = 6
            tapeInsets = CGSize(width: 9, height: 5)
            spacing = pitch * 7
            fade = 0
            step = pitch
            cornerRadius = 7
        case .paper:
            let paper = PaperRenderer.paperHeight(fontSize: f)
            height = paper + 18
            backdropInset = 9
            tapeInsets = .zero
            spacing = 0
            fade = (f * 1.8).rounded()
            step = nil
            cornerRadius = 1.5
        case .aura:
            height = (f * 4.8).rounded()
            backdropInset = 0
            tapeInsets = .zero
            spacing = (f * 1.4).rounded()
            fade = (f * 2.4).rounded()
            step = nil
            cornerRadius = 0
        case .focus:
            height = FocusMetrics(fontSize: f).height
            backdropInset = 0
            tapeInsets = .zero
            spacing = 0
            fade = 0
            step = nil
            cornerRadius = 0
        }
    }
}
