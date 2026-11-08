import SwiftUI

/// Search Yahoo, add, reorder, recolour and rename what runs on the tape.
struct WatchlistPane: View {
    let model: AppModel

    @State private var query = ""
    @State private var hits: [Yahoo.SearchHit] = []
    @State private var searching = false
    @State private var renaming: WatchItem?
    @State private var newLabel = ""
    @FocusState private var searchFocused: Bool

    private var settings: Settings { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField
            if !query.isEmpty {
                results
            }
            list
            Text("Colours come from each logo, adjusted to read on your wallpaper. Click a colour to choose your own; drag to reorder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 560)
        .task(id: query) { await search() }
        .alert("Rename \(renaming.map { Format.label(for: $0.symbol) } ?? "")", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Label on the tape", text: $newLabel)
            Button("Rename") {
                if let renaming { settings.setLabel(newLabel, for: renaming.symbol) }
            }
            Button("Use Symbol") {
                if let renaming { settings.setLabel(nil, for: renaming.symbol) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown on the tape instead of the symbol.")
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Add a stock, ETF, index or crypto…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onSubmit { if let first = hits.first { add(first.symbol) } else if !query.isEmpty { add(query) } }
            if searching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
        .onAppear { searchFocused = true }
    }

    private var results: some View {
        VStack(spacing: 0) {
            if hits.isEmpty && !searching {
                Text("Nothing on Yahoo Finance matches “\(query)”. Press Return to add it as a symbol anyway.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            ForEach(hits) { hit in
                let added = settings.watchlist.contains { $0.symbol == hit.symbol }
                Button {
                    if !added { add(hit.symbol) }
                } label: {
                    HStack(spacing: 10) {
                        Text(hit.symbol)
                            .font(.system(size: 13, weight: .semibold).monospaced())
                            .frame(width: 96, alignment: .leading)
                        Text(hit.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text([hit.exchange, hit.kind.title].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: added ? "checkmark" : "plus")
                            .foregroundStyle(added ? Color.secondary : Color.accentColor)
                            .frame(width: 16)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(added)
                if hit.id != hits.last?.id { Divider().padding(.leading, 12) }
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func search() async {
        let text = query
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            hits = []
            return
        }
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        let found = (try? await Yahoo.search(text)) ?? []
        guard !Task.isCancelled, text == query else { return }
        hits = found
    }

    private func add(_ symbol: String) {
        settings.add(symbol)
        query = ""
        hits = []
    }

    // MARK: List

    private var list: some View {
        List {
            ForEach(settings.watchlist) { item in
                WatchRow(item: item, model: model)
                    .contextMenu {
                        Button("Rename…") {
                            newLabel = item.label ?? ""
                            renaming = item
                        }
                        if item.color != nil {
                            Button("Use the Logo's Colour") { settings.setColor(nil, for: item.symbol) }
                        }
                        Button("Open in Yahoo Finance") { NSWorkspace.shared.open(Yahoo.pageURL(for: item.symbol)) }
                        Divider()
                        Button("Remove", role: .destructive) { withAnimation { settings.remove(item.symbol) } }
                    }
            }
            .onMove { from, to in settings.watchlist.move(fromOffsets: from, toOffset: to) }
            .onDelete { settings.watchlist.remove(atOffsets: $0) }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds(.disabled)
        .frame(height: 320)
        .overlay {
            if settings.watchlist.isEmpty {
                ContentUnavailableView("Nothing on the tape", systemImage: "chart.line.uptrend.xyaxis", description: Text("Search above to add a listing."))
            }
        }
    }
}

private struct WatchRow: View {
    let item: WatchItem
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        let quote = model.market.quotes[item.symbol]
        let reference = model.settings.reference
        HStack(spacing: 10) {
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .help(model.brands.source(for: item))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.label ?? Format.label(for: item.symbol, kind: quote?.kind))
                        .font(.system(size: 13, weight: .semibold))
                    if item.label != nil || Format.label(for: item.symbol, kind: quote?.kind) != item.symbol {
                        Text(item.symbol).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text(quote?.name ?? "Waiting for Yahoo Finance…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let quote {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Format.price(quote.price, of: quote, showCurrency: true, compact: false).text)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                    if let change = quote.change(reference) {
                        Text(Format.signed(Format.percent(change.percent), change.direction))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(change.direction == .up ? Color.green : change.direction == .down ? Color.red : Color.secondary)
                    }
                }
            }
            Button {
                withAnimation { model.settings.remove(item.symbol) }
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help("Remove from the tape")
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    private var colorBinding: Binding<Color> {
        Binding {
            model.brands.color(for: item).map { Color(nsColor: $0.nsColor()) } ?? Color(white: 0.85)
        } set: { color in
            guard let rgb = RGB(NSColor(color)) else { return }
            model.settings.setColor(rgb.hexString, for: item.symbol)
        }
    }
}
