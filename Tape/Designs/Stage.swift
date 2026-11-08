import AppKit

/// Everything inside the tape's window: the design's backdrop (glass rail, LED panel, paper)
/// and, on top, the moving tape or the Focus view.
final class TapeStage: NSView {
    let tape = TickerView()
    let focus = FocusView()
    var onMenu: ((NSEvent) -> NSMenu?)?

    private(set) var design: TapeDesign = .classic
    private var metrics = DesignMetrics(design: .classic, fontSize: 14, scale: 2)
    private var scale: CGFloat = 2
    /// Focus on a pane of glass, which follows the slide rather than filling the window.
    private(set) var focusGlass = false
    private var platter: (rect: CGRect, radius: CGFloat)?
    /// In Settings the glass blurs what's in the window (the wallpaper preview), not the desktop.
    private let isPreview: Bool

    private let shadowView = NSView()
    private let glass = NSVisualEffectView()
    private let backdrop = NSView()
    private var backdropKey = ""

    init(preview: Bool = false) {
        isPreview = preview
        super.init(frame: .zero)
        wantsLayer = true
        shadowView.wantsLayer = true
        backdrop.wantsLayer = true
        glass.material = .hudWindow
        glass.blendingMode = preview ? .withinWindow : .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        for view in [shadowView, glass, backdrop, tape, focus] as [NSView] { addSubview(view) }
        focus.onPlatter = { [weak self] platter in self?.placePlatter(platter) }
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(design: TapeDesign, metrics: DesignMetrics, scale: CGFloat, focusGlass: Bool = false) {
        guard design != self.design || metrics != self.metrics || scale != self.scale || focusGlass != self.focusGlass else { return }
        self.design = design
        self.metrics = metrics
        self.scale = scale
        self.focusGlass = focusGlass
        apply()
    }

    private var hasGlass: Bool { design == .liquid || (design == .focus && focusGlass) }

    private func apply() {
        tape.spacing = metrics.spacing
        tape.fade = metrics.fade
        tape.step = metrics.step
        tape.isHidden = !design.scrolls
        focus.isHidden = design.scrolls
        glass.isHidden = !hasGlass
        shadowView.isHidden = design == .focus && !focusGlass
        backdrop.isHidden = design == .focus && !focusGlass
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let panel = bounds.insetBy(dx: metrics.backdropInset, dy: metrics.backdropInset)
        let tapeFrame = panel.insetBy(dx: metrics.tapeInsets.width, dy: metrics.tapeInsets.height)
        tape.frame = tapeFrame
        tape.dotGrid = design == .led ? metrics.step : nil
        focus.frame = bounds
        // Focus's glass follows the slide; FocusView says where through `placePlatter`.
        if design == .focus {
            placePlatter(platter)
            return
        }
        frameBackdrop(panel, radius: metrics.cornerRadius, continuous: false)
    }

    /// Where Focus's glass goes, or nil for none.
    private func placePlatter(_ platter: (rect: CGRect, radius: CGFloat)?) {
        self.platter = platter
        guard design == .focus else { return }
        guard focusGlass, let platter else {
            glass.isHidden = true
            backdrop.isHidden = true
            shadowView.isHidden = true
            return
        }
        glass.isHidden = false
        backdrop.isHidden = false
        shadowView.isHidden = false
        // Corners concentric with the tile's, so tile and glass read as one object.
        frameBackdrop(platter.rect, radius: platter.radius, continuous: true)
    }

    private func frameBackdrop(_ panel: CGRect, radius: CGFloat, continuous: Bool) {
        glass.frame = panel
        backdrop.frame = panel
        shadowView.frame = panel

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // A soft shadow under any object that sits on the desktop.
        if let layer = shadowView.layer {
            let solid = design == .liquid || design == .led || design == .paper || (design == .focus && focusGlass)
            let local = CGRect(origin: .zero, size: panel.size)
            layer.shadowPath = solid ? (continuous ? Shapes.continuous(local, radius: radius) : CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)) : nil
            layer.shadowColor = CGColor(gray: 0, alpha: 1)
            layer.shadowOpacity = solid ? (design == .paper ? 0.34 : 0.28) : 0
            layer.shadowRadius = design == .paper ? 5 : 7
            layer.shadowOffset = CGSize(width: 0, height: design == .paper ? -2.5 : -2)
        }
        if hasGlass {
            glass.maskImage = Self.mask(height: panel.height, radius: radius, continuous: continuous)
        }
        let key = "\(design)|\(focusGlass)|\(panel.size)|\(radius)|\(scale)"
        if key != backdropKey {
            backdropKey = key
            backdrop.layer?.contents = design == .focus
                ? Backdrops.glassEdge(size: panel.size, radius: radius, scale: scale, continuous: true)
                : Backdrops.image(for: design, size: panel.size, metrics: metrics, scale: scale)
            backdrop.layer?.contentsScale = scale
        }
    }

    /// The glass's outline as a stretchable image: corners kept, the middle stretched.
    private static func mask(height: CGFloat, radius: CGFloat, continuous: Bool) -> NSImage {
        let corner = continuous ? (radius * 1.53).rounded(.up) : radius
        let image = NSImage(size: NSSize(width: corner * 2 + 1, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            if continuous {
                let path = NSBezierPath(cgPath: Shapes.continuous(rect, radius: radius))
                path.fill()
            } else {
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: min(radius, rect.height / 2)).fill()
            }
            return true
        }
        image.capInsets = NSEdgeInsets(top: 0, left: corner, bottom: 0, right: corner)
        image.resizingMode = .stretch
        return image
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onMenu?(event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

/// The still parts of each design, drawn once per size.
nonisolated enum Backdrops {
    static func image(for design: TapeDesign, size: CGSize, metrics: DesignMetrics, scale: CGFloat) -> CGImage? {
        switch design {
        case .liquid: glassEdge(size: size, radius: metrics.cornerRadius, scale: scale)
        case .led: ledPanel(size: size, radius: metrics.cornerRadius, scale: scale)
        case .paper: PaperRenderer.paper(size: size, scale: scale)
        case .classic, .aura, .focus: nil
        }
    }

    /// What makes blur read as glass: a lit rim, a catch-light along the top, a darker lower edge.
    static func glassEdge(size: CGSize, radius: CGFloat, scale: CGFloat, continuous: Bool = false) -> CGImage? {
        guard let canvas = Bitmap(size: size, scale: scale) else { return nil }
        let context = canvas.context
        let rect = CGRect(origin: .zero, size: size)
        func outline(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
            continuous ? Shapes.continuous(rect, radius: radius) : CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let shape = outline(rect, radius)
        context.saveGState()
        context.addPath(shape)
        context.clip()
        let tint = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0.02), CGColor(gray: 0, alpha: 0.08)] as CFArray, locations: [0, 0.5, 1])!
        context.drawLinearGradient(tint, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        context.restoreGState()
        let px = 1 / scale
        context.addPath(outline(rect.insetBy(dx: px / 2, dy: px / 2), radius - px / 2))
        context.setLineWidth(px)
        context.replacePathWithStrokedPath()
        context.clip()
        let rim = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.5), CGColor(gray: 1, alpha: 0.12), CGColor(gray: 1, alpha: 0.22)] as CFArray, locations: [0, 0.5, 1])!
        context.drawLinearGradient(rim, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        return canvas.image()
    }

    /// A smoked-glass display: deep black, a bezel and a reflection across its upper half.
    static func ledPanel(size: CGSize, radius: CGFloat, scale: CGFloat) -> CGImage? {
        guard let canvas = Bitmap(size: size, scale: scale) else { return nil }
        let context = canvas.context
        let rect = CGRect(origin: .zero, size: size)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.addPath(shape)
        context.clip()
        let body = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 0.94), CGColor(red: 0.02, green: 0.02, blue: 0.025, alpha: 0.96)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(body, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        let reflection = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.055), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(reflection, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height * 0.45), options: [])
        context.restoreGState()
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.1))
        context.setLineWidth(1)
        context.strokePath()
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 2.5, dy: 2.5), cornerWidth: radius - 2.5, cornerHeight: radius - 2.5, transform: nil))
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
        context.setLineWidth(1)
        context.strokePath()
        return canvas.image()
    }
}
