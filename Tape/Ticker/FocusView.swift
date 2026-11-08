import AppKit
import CoreImage
import QuartzCore

/// Focus: one listing at a time. Each column (tile, name, price, move, chart) keeps its place on a
/// shared grid; when the next listing comes, the old one drifts up out of focus and the new one
/// rises into it, a column at a time, left to right. A small clock face by the Dock sweeps round as
/// the next one approaches. The pointer holds it; two fingers or the wheel flip through.
final class FocusView: NSView {
    var onSelect: ((String, NSRect) -> Void)?
    var onMenu: ((String?, NSEvent) -> NSMenu?)?
    /// The glass behind the slide and its corner radius, when Focus has glass, in this view's coordinates.
    var onPlatter: (((rect: CGRect, radius: CGFloat)?) -> Void)?

    var isPaused = false { didSet { if isPaused != oldValue { updateClock() } } }
    var pausesOnHover = true { didSet { if pausesOnHover != oldValue { updateClock() } } }
    var isHolding = false { didSet { if isHolding != oldValue { updateClock() } } }
    /// Seconds each listing stays.
    var dwell: TimeInterval = 6 {
        didSet { if dwell != oldValue, shown != nil { restartClock() } }
    }
    /// Which end the slide sits at: the one by the Dock.
    var alignsTrailing = true { didSet { if alignsTrailing != oldValue { needsLayout = true } } }
    var metrics = FocusMetrics(fontSize: 14) { didSet { if metrics != oldValue { needsLayout = true } } }
    /// The middle of the corner the slide sits in, in this view's coordinates.
    var centre: CGFloat? { didSet { if centre != oldValue { needsLayout = true } } }

    private let grid = CALayer()
    private let veil = CALayer()
    private var columns: [FocusSlide.Column: CALayer] = [:]
    private let ring = CALayer()
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let halo = CALayer()
    private var slides: [FocusSlide] = []
    private var index = 0
    private var shown: FocusSlide?
    private var hovering = false
    private var trackingArea: NSTrackingArea?
    private var scrollAccumulator: CGFloat = 0
    private var lastPlatter: [CGFloat]??

    // The countdown's clock, which can stop and carry on where it was.
    private var remaining: TimeInterval = 0
    private var runningSince: CFTimeInterval?
    private var timer: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer = CALayer()
        grid.anchorPoint = .zero
        ring.anchorPoint = .zero
        halo.isHidden = true
        for shape in [track, fill] {
            shape.fillColor = nil
            shape.lineCap = .butt
            shape.anchorPoint = .zero
        }
        veil.anchorPoint = .zero
        fill.strokeEnd = 0
        for layer in [grid, veil, ring, track, fill, halo] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull(),
                             "path": NSNull(), "strokeColor": NSNull(), "strokeEnd": NSNull(), "lineWidth": NSNull(), "shadowOpacity": NSNull()]
        }
        ring.addSublayer(track)
        ring.addSublayer(fill)
        grid.addSublayer(veil)
        grid.addSublayer(halo)
        layer?.addSublayer(grid)
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var currentSymbol: String? { shown?.symbol }

    // MARK: Slides

    func setSlides(_ new: [FocusSlide]) {
        let previous = shown
        slides = new
        guard !new.isEmpty else {
            clear()
            return
        }
        if let symbol = previous?.symbol, let kept = new.firstIndex(where: { $0.symbol == symbol }) {
            index = kept
        } else {
            index = min(index, new.count - 1)
        }
        let next = new[index]
        if let previous {
            if previous.symbol != next.symbol {
                present(next, .roll(forward: true))
                restartClock()
            } else if previous.key != next.key {
                // The same listing with a new price: only what changed moves, in the price's direction.
                present(next, .tick(up: next.price >= previous.price))
            }
        } else {
            present(next, .appear)
            restartClock()
        }
        ring.isHidden = new.count < 2 || !next.clock
        updateClock()
    }

    private func clear() {
        for layer in columns.values { layer.removeFromSuperlayer() }
        columns = [:]
        veil.contents = nil
        shown = nil
        halo.isHidden = true
        halo.removeAllAnimations()
        timer?.cancel()
        runningSince = nil
        ring.isHidden = true
        reportPlatter(nil)
    }

    private enum Motion {
        case appear, roll(forward: Bool), tick(up: Bool)

        /// How far a column travels, how much it blurs, and how long each half takes.
        var travel: CGFloat {
            switch self {
            case .appear: 0
            case .roll(let forward): forward ? 6 : -6
            case .tick(let up): up ? 4 : -4
            }
        }

        var blur: Double {
            switch self {
            case .appear: 4
            case .roll: 5
            case .tick: 2.5
            }
        }

        var out: CFTimeInterval { if case .tick = self { 0.2 } else { 0.26 } }
        var into: CFTimeInterval { if case .tick = self { 0.38 } else { 0.52 } }
        var lag: CFTimeInterval { if case .tick = self { 0.05 } else { 0.09 } }
        /// Between one column and the next, left to right.
        var stagger: CFTimeInterval { if case .roll = self { 0.035 } else { 0 } }
    }

    private func present(_ slide: FocusSlide, _ motion: Motion) {
        shown = slide
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeGrid()
        if veil.contents as! CGImage? !== slide.veil {
            veil.contents = slide.veil
            veil.contentsScale = slide.veil.map { CGFloat($0.width) / max(slide.veilFrame.width, 1) } ?? 1
        }
        veil.frame = slide.veilFrame
        let now = CACurrentMediaTime()
        // With Reduce Motion, columns cross-fade in place.
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var arrival: CFTimeInterval?
        for (order, column) in FocusSlide.Column.allCases.enumerated() {
            let part = slide.part(column)
            let old = columns[column]
            if let part, let old, old.value(forKey: "key") as? String == part.key {
                old.frame = part.frame
                continue
            }
            let delay = Double(order) * motion.stagger
            if let old { leave(old, motion, calm: calm, at: now + delay) }
            columns[column] = nil
            guard let part else { continue }
            let layer = CALayer()
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull(), "filters": NSNull()]
            layer.contents = part.image
            layer.contentsScale = CGFloat(part.image.width) / part.frame.width
            layer.frame = part.frame
            layer.setValue(part.key, forKey: "key")
            grid.insertSublayer(layer, below: halo)
            columns[column] = layer
            let begin = now + delay + (old == nil ? 0 : motion.lag)
            arrive(layer, motion, calm: calm, at: begin)
            if column == .chart { arrival = begin - now + motion.into }
        }
        CATransaction.commit()
        placeHalo(after: arrival)
    }

    private func leave(_ layer: CALayer, _ motion: Motion, calm: Bool, at begin: CFTimeInterval) {
        let blur = calm ? nil : Self.blurFilter()
        let travel = calm ? 0 : motion.travel
        layer.filters = blur.map { [$0] }
        layer.opacity = 0
        let group = CAAnimationGroup()
        group.animations = [
            Self.animation("opacity", from: 1, to: 0),
            Self.animation("position.y", from: layer.position.y, to: layer.position.y + travel),
        ] + (blur == nil ? [] : [Self.animation("filters.blur.inputRadius", from: 0, to: motion.blur)])
        group.duration = motion.out
        group.beginTime = begin
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.85, 0.5)
        layer.add(group, forKey: "leave")
        let wait = begin - CACurrentMediaTime() + motion.out + 0.05
        Task { [weak layer] in
            try? await Task.sleep(for: .seconds(max(wait, 0)))
            layer?.removeFromSuperlayer()
        }
    }

    private func arrive(_ layer: CALayer, _ motion: Motion, calm: Bool, at begin: CFTimeInterval) {
        let blur = calm ? nil : Self.blurFilter()
        let travel = calm ? 0 : motion.travel
        layer.filters = blur.map { [$0] }
        let group = CAAnimationGroup()
        group.animations = [
            Self.animation("opacity", from: 0, to: 1),
            Self.animation("position.y", from: layer.position.y - travel, to: layer.position.y),
        ] + (blur == nil ? [] : [Self.animation("filters.blur.inputRadius", from: motion.blur, to: 0)])
        group.duration = motion.into
        group.beginTime = begin
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.add(group, forKey: "arrive")
        // Sharp again: drop the filter, so a still slide costs nothing to draw.
        let wait = begin - CACurrentMediaTime() + motion.into + 0.05
        Task { [weak layer] in
            try? await Task.sleep(for: .seconds(max(wait, 0)))
            layer?.filters = nil
        }
    }

    private static func animation(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    private static func blurFilter() -> CIFilter? {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.name = "blur"
        filter.setValue(0, forKey: kCIInputRadiusKey)
        return filter
    }

    /// While the market trades, a ring breathes out from the end of the chart. `delay` is when a
    /// new chart has come into focus; without one, the ring only follows the line's end.
    private func placeHalo(after delay: CFTimeInterval?) {
        guard let slide = shown, let live = slide.live, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            halo.isHidden = true
            halo.removeAllAnimations()
            return
        }
        let size: CGFloat = 4.5
        halo.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        halo.cornerRadius = size / 2
        halo.backgroundColor = slide.accent.cgColor(alpha: 0.55)
        halo.position = live
        halo.opacity = 0
        halo.isHidden = false
        guard delay != nil || halo.animation(forKey: "breathe") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 3.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let breathe = CAAnimationGroup()
        breathe.animations = [scale, fade]
        breathe.duration = 2.4
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.6, 0.3, 1)
        breathe.beginTime = CACurrentMediaTime() + (delay ?? 0)
        halo.add(breathe, forKey: "breathe")
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeGrid()
        CATransaction.commit()
    }

    private var placement: FocusMetrics.Layout? {
        guard let slide = shown else { return nil }
        return metrics.layout(in: bounds, gridWidth: slide.size.width, trailing: alignsTrailing, clock: slide.clock, tile: slide.tile, centre: centre)
    }

    private func placeGrid() {
        guard let placement, let slide = shown else { return }
        grid.frame = CGRect(origin: placement.grid.origin, size: slide.size)
        ring.frame = placement.ring
        let local = CGRect(origin: .zero, size: placement.ring.size)
        let line = metrics.ringLine * 0.75
        let colors = FocusRenderer.ringColors(dark: slide.isDark)
        let wedge = FocusRenderer.wedgeCircle(in: local, line: line)
        track.frame = local
        track.path = FocusRenderer.ringPath(in: local, line: line)
        track.lineWidth = line
        track.strokeColor = colors.track
        fill.frame = local
        fill.path = wedge.path
        fill.lineWidth = wedge.width
        fill.strokeColor = colors.fill
        // On the wallpaper the ring gets the same lift as the text; on glass it needs none.
        ring.shadowColor = CGColor(gray: 0, alpha: 1)
        ring.shadowOffset = CGSize(width: 0, height: -0.5)
        ring.shadowRadius = 1
        ring.shadowOpacity = slide.isDark && !metrics.glass ? 0.45 : 0
        ring.isHidden = slides.count < 2 || !slide.clock
        reportPlatter(metrics.glass ? (rect: placement.platter, radius: metrics.platterRadius(tile: slide.tile)) : nil)
    }

    private func reportPlatter(_ platter: (rect: CGRect, radius: CGFloat)?) {
        let key = platter.map { [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height, $0.radius] }
        guard lastPlatter != .some(key) else { return }
        lastPlatter = .some(key)
        onPlatter?(platter)
    }

    // MARK: Countdown

    private var shouldRun: Bool {
        slides.count > 1 && !isPaused && !isHolding && !(pausesOnHover && hovering) && window != nil
    }

    /// From empty: the wedge winds back what's left of the last countdown, then sweeps round over the dwell.
    private func restartClock() {
        timer?.cancel()
        timer = nil
        runningSince = nil
        remaining = dwell
        let current = fill.presentation()?.strokeEnd ?? 0
        fill.removeAnimation(forKey: "count")
        fill.speed = 1
        fill.timeOffset = 0
        fill.beginTime = 0
        let unwind = min(0.35, dwell * 0.1)
        let count = CAKeyframeAnimation(keyPath: "strokeEnd")
        count.values = [current, 0, 1]
        count.keyTimes = [0, NSNumber(value: unwind / dwell), 1]
        count.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
        count.duration = dwell
        count.fillMode = .forwards
        count.isRemovedOnCompletion = false
        count.beginTime = fill.convertTime(CACurrentMediaTime(), from: nil)
        fill.strokeEnd = 0
        fill.add(count, forKey: "count")
        pauseFill()
    }

    /// Starts or stops the clock to match what's going on, keeping its place.
    private func updateClock() {
        if shouldRun, runningSince == nil, shown != nil {
            runningSince = CACurrentMediaTime()
            resumeFill()
            let left = remaining
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(left))
                guard !Task.isCancelled else { return }
                self?.advance(by: 1)
            }
        } else if !shouldRun, let since = runningSince {
            remaining = max(0, remaining - (CACurrentMediaTime() - since))
            runningSince = nil
            timer?.cancel()
            timer = nil
            pauseFill()
        }
    }

    private func pauseFill() {
        guard fill.speed != 0 else { return }
        let now = fill.convertTime(CACurrentMediaTime(), from: nil)
        fill.speed = 0
        fill.timeOffset = now
    }

    private func resumeFill() {
        guard fill.speed == 0 else { return }
        let paused = fill.timeOffset
        fill.speed = 1
        fill.timeOffset = 0
        fill.beginTime = 0
        fill.beginTime = fill.convertTime(CACurrentMediaTime(), from: nil) - paused
    }

    /// The next listing, or the one before.
    func advance(by delta: Int) {
        guard slides.count > 1 else { return }
        index = (index + delta + slides.count) % slides.count
        present(slides[index], .roll(forward: delta > 0))
        restartClock()
        updateClock()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        matchScreenScale()
        updateClock()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchScreenScale()
    }

    /// The clock is drawn by Core Animation from its path; at the layer's default scale of 1 it
    /// would be drawn at half the Retina screen's resolution and enlarged, soft at the edge.
    private func matchScreenScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for layer in [ring, track, fill, halo] where layer.contentsScale != scale { layer.contentsScale = scale }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateClock()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateClock()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let symbol = currentSymbol, let rect = screenRect(of: symbol) else { return }
        onSelect?(symbol, rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onMenu?(currentSymbol, event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    /// Flip through by hand: a notch of the wheel, or a short swipe, is one listing.
    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { scrollAccumulator = 0 }
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : event.scrollingDeltaY
        scrollAccumulator += event.hasPreciseScrollingDeltas ? delta : delta * 30
        if abs(scrollAccumulator) > 28 {
            advance(by: scrollAccumulator < 0 ? 1 : -1)
            scrollAccumulator = 0
        }
    }

    func screenRect(of symbol: String) -> NSRect? {
        guard currentSymbol == symbol, let placement else { return nil }
        let rect = convert(placement.grid.insetBy(dx: 0, dy: (placement.grid.height - metrics.tile) / 2), to: nil)
        return window?.convertToScreen(rect)
    }
}
