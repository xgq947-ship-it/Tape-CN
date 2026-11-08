import SwiftUI

/// What opens above a listing when it's clicked: the full price, today's path, the ranges and
/// whether its market is open.
struct DetailCard: View {
    let symbol: String
    let model: AppModel

    private var quote: Quote? { model.market.quotes[symbol] }
    private var item: WatchItem { model.settings.watchlist.first { $0.symbol == symbol } ?? WatchItem(symbol) }
    private var reference: Reference { model.settings.reference }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let quote {
                header(quote)
                price(quote)
                if quote.intraday.count > 1 {
                    Sparkline(points: quote.intraday, baseline: quote.baseline(reference), tint: tint(quote))
                        .frame(height: 62)
                }
                ranges(quote)
                footer(quote)
            } else {
                Text(symbol).font(.headline)
                Text("Waiting for Yahoo Finance…").foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 320, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(10)
    }

    private func tint(_ quote: Quote) -> Color {
        switch quote.change(reference)?.direction ?? .flat {
        case .up: Color(red: 0.10, green: 0.72, blue: 0.48)
        case .down: Color(red: 0.90, green: 0.27, blue: 0.24)
        case .flat: .secondary
        }
    }

    // MARK: Sections

    private func header(_ quote: Quote) -> some View {
        HStack(spacing: 11) {
            Logo(symbol: symbol, label: item.label ?? Format.label(for: symbol, kind: quote.kind), kind: quote.kind, model: model)
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text([symbol, quote.exchange, quote.kind == .stock ? nil : quote.kind.title].compactMap(\.self).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func price(_ quote: Quote) -> some View {
        let price = Format.price(quote.price, of: quote, showCurrency: true, compact: false)
        let change = quote.change(reference)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                if !price.prefix.isEmpty { Text(price.prefix).foregroundStyle(.secondary) }
                Text(price.number)
                if !price.suffix.isEmpty { Text(price.suffix).foregroundStyle(.secondary) }
            }
            .font(.system(size: 30, weight: .semibold).monospacedDigit())
            .contentTransition(.numericText(value: quote.price))
            if let change {
                HStack(spacing: 6) {
                    Text(Format.signed(Format.amount(change.amount, of: quote), change.direction))
                    Text(Format.signed(Format.percent(change.percent), change.direction))
                    Text(reference == .open ? "since the open" : "today")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(tint(quote))
            }
        }
        .animation(.smooth, value: quote.price)
    }

    @ViewBuilder
    private func ranges(_ quote: Quote) -> some View {
        VStack(spacing: 10) {
            if let low = quote.dayLow, let high = quote.dayHigh {
                RangeBar(title: "Day", low: low, high: high, value: quote.price, quote: quote)
            }
            if let low = quote.yearLow, let high = quote.yearHigh {
                RangeBar(title: "52 weeks", low: low, high: high, value: quote.price, quote: quote)
            }
        }
    }

    private func footer(_ quote: Quote) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(quote.isTrading() ? Color(red: 0.18, green: 0.81, blue: 0.59) : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(status(quote))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.open(Yahoo.pageURL(for: symbol))
            } label: {
                Label("Yahoo Finance", systemImage: "arrow.up.right")
                    .labelStyle(TrailingIcon())
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    /// The dot already says open or closed; the words say until when.
    private func status(_ quote: Quote) -> String {
        let now = Date.now
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        if quote.kind == .crypto { return "Trades around the clock" }
        if quote.isTrading(at: now), let end = quote.sessionEnd { return "Open until \(end.formatted(time))" }
        if let start = quote.sessionStart, start > now {
            let day = Calendar.current.isDateInToday(start) ? "" : " \(start.formatted(.dateTime.weekday(.abbreviated)))"
            return "Opens\(day) at \(start.formatted(time))"
        }
        let asOf = Calendar.current.isDateInToday(quote.marketTime)
            ? quote.marketTime.formatted(time)
            : quote.marketTime.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "Closed · last at \(asOf)"
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

/// The listing's logo tile, or a stand-in in its colour: a glyph for indices, currencies and
/// futures, initials for companies whose logo hasn't arrived.
private struct Logo: View {
    let symbol: String
    let label: String
    let kind: Quote.Kind
    let model: AppModel

    private var glyph: String? {
        switch kind {
        case .index: "chart.line.uptrend.xyaxis"
        case .currency: "arrow.left.arrow.right"
        case .future: "shippingbox"
        case .crypto: "bitcoinsign"
        default: nil
        }
    }

    private var initials: String {
        String(label.filter { $0.isLetter || $0.isNumber }.prefix(2))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack {
            if let image = model.brands.logo(for: symbol) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                let item = model.settings.watchlist.first { $0.symbol == symbol } ?? WatchItem(symbol)
                let color = model.brands.color(for: item).map { Color(nsColor: $0.nsColor()) } ?? Color.secondary
                shape.fill(color.opacity(0.18))
                if let glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                } else {
                    Text(initials)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(color)
                }
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// Low ——●—— high.
private struct RangeBar: View {
    let title: String
    let low: Double
    let high: Double
    let value: Double
    let quote: Quote

    var body: some View {
        let position = high > low ? min(max((value - low) / (high - low), 0), 1) : 0.5
        VStack(spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(Format.price(low, of: quote, showCurrency: false, compact: false).text)
                Text("–").foregroundStyle(.tertiary)
                Text(Format.price(high, of: quote, showCurrency: false, compact: false).text)
            }
            .font(.system(size: 11).monospacedDigit())
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    Capsule()
                        .fill(.primary.opacity(0.28))
                        .frame(width: max(3, proxy.size.width * position))
                    Circle()
                        .fill(.primary)
                        .frame(width: 7, height: 7)
                        .offset(x: proxy.size.width * position - 3.5)
                }
            }
            .frame(height: 7)
        }
    }
}

/// Today's path against the line it's measured from.
struct Sparkline: View {
    let points: [Quote.Point]
    let baseline: Double?
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let values = points.map(\.value)
            guard let first = points.first?.time, let last = points.last?.time, var low = values.min(), var high = values.max() else { return }
            if let baseline {
                low = min(low, baseline)
                high = max(high, baseline)
            }
            let span = max(high - low, abs(high) * 0.0005, .ulpOfOne)
            let duration = max(last.timeIntervalSince(first), 1)
            let inset: CGFloat = 3
            // Room on the right for the dot at the latest price.
            let width = size.width - 6
            func point(_ p: Quote.Point) -> CGPoint {
                CGPoint(
                    x: CGFloat(p.time.timeIntervalSince(first) / duration) * width,
                    y: inset + (1 - CGFloat((p.value - low) / span)) * (size.height - inset * 2)
                )
            }
            var line = Path()
            for (index, p) in points.enumerated() {
                index == 0 ? line.move(to: point(p)) : line.addLine(to: point(p))
            }
            var area = line
            area.addLine(to: CGPoint(x: point(points[points.count - 1]).x, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.28), tint.opacity(0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            if let baseline {
                let y = inset + (1 - CGFloat((baseline - low) / span)) * (size.height - inset * 2)
                var dash = Path()
                dash.move(to: CGPoint(x: 0, y: y))
                dash.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(dash, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            if let end = points.last {
                let dot = point(end)
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12)), with: .color(tint.opacity(0.22)))
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 2.75, y: dot.y - 2.75, width: 5.5, height: 5.5)), with: .color(tint))
            }
        }
    }
}
