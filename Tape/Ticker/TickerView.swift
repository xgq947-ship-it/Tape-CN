import AppKit
import QuartzCore

/// The moving tape. Each listing is a bitmap layer. At cruising speed the whole strip is one
/// repeating Core Animation, run by the render server, so Tape itself does no work per frame.
/// A display link takes over only for changes (slowing for the pointer, a listing opening up),
/// and stops once the tape is still.
final class TickerView: NSView {
    // Callbacks
    var onSelect: ((String, NSRect) -> Void)?
    var onMenu: ((String?, NSEvent) -> NSMenu?)?
    var onHoverChange: ((Bool) -> Void)?
    /// A click between listings.
    var onMiss: (() -> Void)?

    /// Points per second; 0 stops the tape.
    var speed: CGFloat = 30 { didSet { updateTargetSpeed() } }
    var isPaused = false { didSet { updateTargetSpeed() } }
    var pausesOnHover = true { didSet { updateTargetSpeed() } }
    /// Keeps the tape still while the detail card is open.
    var isHolding = false { didSet { updateTargetSpeed(); if !isHolding { highlighted = hoveredSymbol } } }
    /// Edges fade over this many points.
    var fade: CGFloat = 26 { didSet { updateMask() } }
    var spacing: CGFloat = 28 { didSet { if spacing != oldValue { wake() } } }
    /// Moves in whole steps of this many points (an LED's dot pitch) instead of smoothly.
    var step: CGFloat? { didSet { if step != oldValue { wake() } } }
    /// Draws an unlit dot matrix with this pitch behind the listings, fixed in place.
    var dotGrid: CGFloat? { didSet { if dotGrid != oldValue { needsLayout = true } } }

    private final class Entry {
        let symbol: String
        var item: TapeItem
        var width: CGFloat
        var targetWidth: CGFloat
        var opacity: CGFloat
        var targetOpacity: CGFloat = 1
        var leaving = false
        var layers: [CALayer] = []

        init(item: TapeItem, appearing: Bool) {
            symbol = item.symbol
            self.item = item
            targetWidth = item.size.width
            width = appearing ? 0 : item.size.width
            opacity = appearing ? 0 : 1
        }
    }

    private let strip = CALayer()
    private let grid = CALayer()
    private var gridKey = ""
    private let fadeMask = CAGradientLayer()
    private var entries: [Entry] = []
    private var offset: CGFloat = 0
    private var velocity: CGFloat = 0
    private var targetVelocity: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var trackingArea: NSTrackingArea?
    private var hoveredSymbol: String?
    private var highlighted: String? { didSet { if highlighted != oldValue { updateOpacityTargets() } } }
    private var isHovering = false
    private var resumeTask: Task<Void, Never>?
    /// True while the render server moves the strip on its own.
    private var cruising = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        strip.anchorPoint = .zero
        grid.anchorPoint = .zero
        layer?.addSublayer(grid)
        layer?.addSublayer(strip)
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = fadeMask
        updateMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    /// Replaces the listings, keeping the ones that stay where they are on screen.
    /// New listings open up their room smoothly; removed ones close theirs.
    func setItems(_ items: [TapeItem], animated: Bool = true) {
        var existing = Dictionary(entries.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [Entry] = []
        var changedAnything = false
        for item in items {
            if let entry = existing.removeValue(forKey: item.symbol) {
                let changed = entry.item.key != item.key
                guard changed || entry.leaving || entry.targetWidth != item.size.width else {
                    next.append(entry)
                    continue
                }
                changedAnything = true
                entry.item = item
                entry.targetWidth = item.size.width
                entry.leaving = false
                updateOpacityTargets(entry)
                if changed { apply(item, to: entry, crossfade: animated) }
                next.append(entry)
            } else {
                changedAnything = true
                let entry = Entry(item: item, appearing: animated && !entries.isEmpty)
                next.append(entry)
            }
        }
        // Nothing new: leave the tape (and the render server's animation) alone.
        if !changedAnything, existing.isEmpty, next.map(\.symbol) == entries.map(\.symbol) { return }
        // Leaving listings stay in their place in the order while they close.
        for (index, old) in entries.enumerated() where existing[old.symbol] != nil {
            old.leaving = true
            old.targetWidth = 0
            old.targetOpacity = 0
            next.insert(old, at: min(index, next.count))
        }
        if !animated {
            for entry in next where entry.leaving { entry.layers.forEach { $0.removeFromSuperlayer() } }
            next.removeAll(where: \.leaving)
            for entry in next {
                entry.width = entry.targetWidth
                entry.opacity = entry.targetOpacity
            }
        }
        entries = next
        updateOpacityTargets()
        wake()
        layoutStrip()
    }

    /// Tints the price, then lets it fade back.
    func flash(_ flashed: TapeItem, settlingTo item: TapeItem) {
        guard let entry = entries.first(where: { $0.symbol == item.symbol }) else { return }
        entry.item = item
        entry.targetWidth = item.size.width
        for layer in entry.layers { layer.contents = flashed.image }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, let entry = self.entries.first(where: { $0.symbol == item.symbol }), entry.item.key == item.key else { return }
            self.apply(item, to: entry, crossfade: true, duration: 1.1)
        }
    }

    private func apply(_ item: TapeItem, to entry: Entry, crossfade: Bool, duration: CFTimeInterval = 0.45) {
        for layer in entry.layers {
            if crossfade {
                let transition = CATransition()
                transition.type = .fade
                transition.duration = duration
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(transition, forKey: "contents")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            configure(layer, with: item)
            CATransaction.commit()
        }
    }

    private func configure(_ layer: CALayer, with item: TapeItem) {
        layer.contents = item.image
        layer.contentsScale = CGFloat(item.image.width) / (item.size.width + item.padding * 2)
        layer.bounds = CGRect(x: 0, y: 0, width: item.size.width + item.padding * 2, height: item.size.height + item.padding * 2)
    }

    // MARK: Motion

    private func updateTargetSpeed() {
        let holding = isPaused || isHolding || (pausesOnHover && isHovering)
        targetVelocity = holding ? 0 : speed
        wake()
    }

    private func wake() {
        endCruise()
        if link == nil, window != nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        configureFrameRate()
        lastTimestamp = nil
        link?.isPaused = false
    }

    private func configureFrameRate() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: lowPower ? 60 : 120, preferred: lowPower ? 60 : 120)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
        } else {
            wake()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(max(now - (lastTimestamp ?? (now - 1 / 120)), 0), 1 / 20)
        lastTimestamp = now

        // Ease speed, widths and opacity toward their targets (critically damped feel, no overshoot).
        let ease = { (time: CGFloat) in 1 - exp(-CGFloat(dt) / time) }
        velocity += (targetVelocity - velocity) * ease(velocity > targetVelocity ? 0.16 : 0.45)
        if abs(velocity - targetVelocity) < 0.05 { velocity = targetVelocity }
        offset += velocity * CGFloat(dt)

        var settled = velocity == 0 && targetVelocity == 0
        for entry in entries {
            entry.width += (entry.targetWidth - entry.width) * ease(0.22)
            entry.opacity += (entry.targetOpacity - entry.opacity) * ease(0.16)
            if abs(entry.width - entry.targetWidth) < 0.05 { entry.width = entry.targetWidth } else { settled = false }
            if abs(entry.opacity - entry.targetOpacity) < 0.005 { entry.opacity = entry.targetOpacity } else { settled = false }
        }
        let gone = entries.filter { $0.leaving && $0.width == 0 && $0.opacity == 0 }
        if !gone.isEmpty {
            gone.forEach { $0.layers.forEach { $0.removeFromSuperlayer() } }
            entries.removeAll { entry in gone.contains { $0 === entry } }
        }

        let steady = entries.allSatisfy { $0.width == $0.targetWidth && $0.opacity == $0.targetOpacity && !$0.leaving }
        if settled {
            // Come to rest on whole pixels, so still text is as crisp as the menu bar.
            let scale = window?.backingScaleFactor ?? 2
            offset = (offset * scale).rounded() / scale
            link.isPaused = true
        } else if steady, velocity > 0, velocity == targetVelocity {
            startCruise()
            return
        }
        layoutStrip()
    }

    /// Hands the motion to the render server: one linear animation over one period, repeating forever.
    private func startCruise() {
        let period = self.period
        guard !cruising, period > 1, velocity > 0 else { return }
        layoutStrip()
        let start = step.map { (offset / $0).rounded(.down) * $0 } ?? offset
        offset = start
        cruising = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutStrip(shift: 0)
        strip.position = CGPoint(x: -start, y: 0)
        let animation: CAAnimation
        if let step, period / step >= 1 {
            // A real LED panel jumps a whole dot at a time; the render server does the jumping.
            let count = max(1, Int((period / step).rounded()))
            let keyframes = CAKeyframeAnimation(keyPath: "position.x")
            keyframes.values = (0...count).map { -start - CGFloat($0) * step }
            keyframes.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
            keyframes.calculationMode = .discrete
            animation = keyframes
        } else {
            let linear = CABasicAnimation(keyPath: "position.x")
            linear.fromValue = -start
            linear.toValue = -start - period
            linear.timingFunction = CAMediaTimingFunction(name: .linear)
            animation = linear
        }
        animation.duration = CFTimeInterval(period / velocity)
        animation.repeatCount = .infinity
        strip.add(animation, forKey: "cruise")
        CATransaction.commit()
        link?.isPaused = true
    }

    /// Takes the motion back exactly where the render server has it on screen.
    private func endCruise() {
        guard cruising else { return }
        cruising = false
        let shown = strip.presentation()?.position.x ?? strip.position.x
        offset = -shown
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.removeAnimation(forKey: "cruise")
        strip.position = .zero
        CATransaction.commit()
        lastTimestamp = nil
        layoutStrip()
    }

    /// Where the strip is drawn right now, horizontally.
    private var stripShift: CGFloat {
        cruising ? (strip.presentation()?.position.x ?? strip.position.x) : 0
    }

    private var period: CGFloat {
        entries.reduce(0) { $0 + $1.width + (($1.width / max($1.targetWidth, $1.item.size.width, 1)) * spacing) }
    }

    /// Positions every copy of every listing. While cruising the strip itself moves, so the
    /// listings are laid out from `shift` 0 with one extra copy to cover a whole period of travel.
    private func layoutStrip(shift: CGFloat? = nil) {
        if cruising, shift == nil { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        strip.bounds = CGRect(origin: .zero, size: bounds.size)
        if !cruising { strip.position = .zero }
        let period = self.period
        guard period > 1 else {
            entries.forEach { $0.layers.forEach { $0.isHidden = true } }
            return
        }
        offset = offset.truncatingRemainder(dividingBy: period)
        if offset < 0 { offset += period }
        let copies = Int((bounds.width / period).rounded(.up)) + 2
        let scale = window?.backingScaleFactor ?? 2

        let shown = shift ?? (step.map { (offset / $0).rounded(.down) * $0 } ?? offset)
        var x: CGFloat = -shown
        for entry in entries {
            while entry.layers.count < copies {
                let layer = CALayer()
                layer.anchorPoint = .zero
                layer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
                configure(layer, with: entry.item)
                strip.addSublayer(layer)
                entry.layers.append(layer)
            }
            while entry.layers.count > copies { entry.layers.removeLast().removeFromSuperlayer() }

            let height = entry.item.size.height
            let y = ((bounds.height - height) / 2 * scale).rounded() / scale - entry.item.padding
            let share = entry.width / max(entry.targetWidth, entry.item.size.width, 1)
            for (copy, layer) in entry.layers.enumerated() {
                let left = x + CGFloat(copy) * period
                // A listing opening up grows from its centre.
                let inset = (entry.item.size.width - entry.width) / 2
                var origin = left - inset
                if let step { origin = (origin / step).rounded() * step }
                layer.position = CGPoint(x: origin - entry.item.padding, y: y)
                layer.opacity = Float(entry.opacity * min(1, share * 1.4))
                layer.isHidden = shift == nil && (left + entry.width < -entry.item.padding || left > bounds.width + entry.item.padding)
            }
            x += entry.width + share * spacing
        }
    }

    override func layout() {
        super.layout()
        updateMask()
        updateGrid()
        if cruising { wake() } else { layoutStrip() }
    }

    private func updateGrid() {
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(dotGrid ?? 0)|\(bounds.size)|\(scale)"
        guard key != gridKey else { return }
        gridKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.frame = CGRect(origin: .zero, size: bounds.size)
        grid.contents = dotGrid.flatMap { LEDRenderer.grid(size: bounds.size, pitch: $0, scale: scale) }
        grid.contentsScale = scale
        CATransaction.commit()
    }

    private func updateMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        layer?.mask = fade > 0 ? fadeMask : nil
        let edge = bounds.width > 0 ? min(0.45, fade / bounds.width) : 0
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        CATransaction.commit()
    }

    // MARK: Hover, click, scrub

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        resumeTask?.cancel()
        isHovering = true
        onHoverChange?(true)
        updateTargetSpeed()
        mouseMoved(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredSymbol = symbol(at: convert(event.locationInWindow, from: nil))
        if !isHolding { highlighted = hoveredSymbol }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSymbol = nil
        if !isHolding { highlighted = nil }
        onHoverChange?(false)
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.isHovering = false
            self.updateTargetSpeed()
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (symbol, rect) = hit(at: point) else {
            onMiss?()
            return
        }
        highlighted = symbol
        let inWindow = convert(rect, to: nil)
        onSelect?(symbol, window?.convertToScreen(inWindow) ?? inWindow)
    }

    override func rightMouseDown(with event: NSEvent) {
        let symbol = symbol(at: convert(event.locationInWindow, from: nil))
        if let menu = onMenu?(symbol, event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    /// Two fingers (or the wheel) slide the tape by hand.
    override func scrollWheel(with event: NSEvent) {
        let horizontal = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
        var delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= 12 }
        endCruise()
        offset -= delta
        layoutStrip()
        wake()
    }

    func symbol(at point: NSPoint) -> String? { hit(at: point)?.0 }

    private func hit(at point: NSPoint) -> (String, NSRect)? {
        let shift = stripShift
        for entry in entries where !entry.leaving {
            for layer in entry.layers where !layer.isHidden {
                let frame = layer.frame.offsetBy(dx: shift, dy: 0)
                if frame.insetBy(dx: entry.item.padding - spacing / 2, dy: 0).contains(point) {
                    return (entry.symbol, frame.insetBy(dx: entry.item.padding, dy: entry.item.padding))
                }
            }
        }
        return nil
    }

    private func updateOpacityTargets() {
        entries.forEach(updateOpacityTargets)
        wake()
    }

    private func updateOpacityTargets(_ entry: Entry) {
        guard !entry.leaving else { return }
        if let highlighted { entry.targetOpacity = entry.symbol == highlighted ? 1 : 0.38 } else { entry.targetOpacity = 1 }
    }

    /// Where a listing is on screen right now (its first visible copy), for the detail card.
    func screenRect(of symbol: String) -> NSRect? {
        let shift = stripShift
        guard let entry = entries.first(where: { $0.symbol == symbol }),
              let layer = entry.layers.first(where: { !$0.isHidden && bounds.intersects($0.frame.offsetBy(dx: shift, dy: 0)) }) else { return nil }
        let rect = convert(layer.frame.offsetBy(dx: shift, dy: 0).insetBy(dx: entry.item.padding, dy: entry.item.padding), to: nil)
        return window?.convertToScreen(rect)
    }
}
