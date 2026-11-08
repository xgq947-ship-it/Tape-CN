import SwiftUI

struct AppearancePane: View {
    @Bindable var settings: Settings
    let model: AppModel

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                TapePreview(model: model)
                    .listRowInsets(EdgeInsets())
            }
            Section("Design") {
                DesignPicker(selection: $settings.design)
                if settings.design == .focus {
                    Picker("Background", selection: $settings.focusGlass) {
                        Text("Clear").tag(false)
                        Text("Glass").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
            Section("Text") {
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: $settings.fontSize, in: 11...20, step: 0.5)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    }
                }
                Toggle("Colour names like their logos", isOn: $settings.brandColors)
                if settings.design.followsWallpaper {
                    Picker("Contrast", selection: $settings.contrast) {
                        Text("Follow the wallpaper").tag(Contrast.automatic)
                        Text("Light text").tag(Contrast.lightText)
                        Text("Dark text").tag(Contrast.darkText)
                    }
                }
            }
            Section("Numbers") {
                Picker("Show the move as", selection: $settings.changeStyle) {
                    Text("Percent").tag(ChangeStyle.percent)
                    Text("Amount").tag(ChangeStyle.amount)
                    Text("Both").tag(ChangeStyle.both)
                }
                .pickerStyle(.segmented)
                Picker("Measure it from", selection: $settings.reference) {
                    Text("Yesterday's close").tag(Reference.previousClose)
                    Text("Today's open").tag(Reference.open)
                }
                Toggle("Show the currency", isOn: $settings.showCurrency)
            }
            Section("Motion") {
                if settings.design.scrolls {
                    LabeledContent("Speed") {
                        HStack(spacing: 8) {
                            Image(systemName: "tortoise").foregroundStyle(.secondary)
                            Slider(value: $settings.speed, in: 10...90)
                            Image(systemName: "hare").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    LabeledContent("Each listing stays") {
                        HStack(spacing: 8) {
                            Slider(value: $settings.focusDwell, in: 3...15, step: 1)
                            Text("\(Int(settings.focusDwell)) s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
                Toggle(settings.design.scrolls ? "Pause while the pointer is on the tape" : "Hold the listing while the pointer is on it", isOn: $settings.pauseOnHover)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.resetAppearance() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The six designs side by side, each drawn by its own renderer with a real listing.
private struct DesignPicker: View {
    @Binding var selection: TapeDesign

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(TapeDesign.allCases) { design in
                Button {
                    withAnimation(.smooth(duration: 0.25)) { selection = design }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        DesignSwatch(design: design)
                            .frame(height: 40)
                            .frame(maxWidth: .infinity)
                            .clipShape(.rect(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selection == design ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selection == design ? 2 : 0.5))
                        Text(design.title).font(.system(size: 12, weight: .semibold))
                        Text(design.summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A tiny emblem of each design, drawn in SwiftUI so it needs no prices.
private struct DesignSwatch: View {
    let design: TapeDesign

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.42, green: 0.33, blue: 0.3), Color(red: 0.2, green: 0.17, blue: 0.17)], startPoint: .topLeading, endPoint: .bottomTrailing)
            switch design {
            case .classic:
                HStack(spacing: 4) {
                    Text("NVDA").foregroundStyle(Color(red: 0.5, green: 0.76, blue: 0.1)).fontWeight(.semibold)
                    Text("181.60").foregroundStyle(.white)
                    Text("▾1.2%").foregroundStyle(Color(red: 1, green: 0.49, blue: 0.46))
                }
                .font(.system(size: 10.5).monospacedDigit())
                .shadow(color: .black.opacity(0.6), radius: 1.5)
            case .liquid:
                HStack(spacing: 4) {
                    Text("NVDA").foregroundStyle(Color(red: 0.55, green: 0.8, blue: 0.2)).fontWeight(.semibold)
                    Text("181.60").foregroundStyle(.white)
                }
                .font(.system(size: 10.5).monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.white.opacity(0.14), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                .padding(4)
                .background(.ultraThinMaterial, in: .capsule)
            case .led:
                Text("NVDA ▼1.2")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color(red: 1, green: 0.3, blue: 0.28))
                    .shadow(color: .red.opacity(0.8), radius: 3)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(white: 0.04), in: .rect(cornerRadius: 4))
            case .paper:
                HStack(spacing: 5) {
                    Text("NVDA").font(.system(size: 11, weight: .bold, design: .serif))
                    Text("181.60").font(.system(size: 10, design: .monospaced))
                }
                .foregroundStyle(Color(white: 0.1))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color(red: 0.96, green: 0.94, blue: 0.89))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            case .aura:
                ZStack {
                    Ellipse().fill(RadialGradient(colors: [Color(red: 0.18, green: 0.89, blue: 0.63).opacity(0.65), .clear], center: .center, startRadius: 0, endRadius: 30))
                        .frame(width: 80, height: 34)
                    Text("NVDA 181.60").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            case .focus:
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 4.2, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.5, green: 0.78, blue: 0.05), Color(red: 0.4, green: 0.66, blue: 0)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 19, height: 19)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    Text("181\(Text(".60").foregroundStyle(.white.opacity(0.8)))")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("+1.2%")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0, green: 0.2, blue: 0.12))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color(red: 0.24, green: 0.9, blue: 0.66), in: .capsule)
                }
                .shadow(color: .black.opacity(0.4), radius: 1.5)
            }
        }
    }
}

/// The tape as it looks right now, on the piece of wallpaper it runs over.
struct TapePreview: View {
    let model: AppModel
    @State private var backdrop: NSImage?

    var body: some View {
        let style = model.tapeStyle(scale: NSScreen.main?.backingScaleFactor ?? 2)
        let room = min(model.ticker?.tapeFrame?.width ?? 480, 480)
        let focus = style.design == .focus
        let items = focus ? [] : model.settings.watchlist.compactMap { model.renderItem(for: $0, style: style) }
        let slides = focus ? model.focusSlides(style: style, room: room) : []
        let height = max(72, style.metrics.height + 20)
        // The backdrop sits behind the tape without taking part in layout, so it can't widen the form.
        StageView(items: items, slides: slides, style: style, speed: model.settings.speed, dwell: model.settings.focusDwell, trailing: model.settings.side == .left)
            .frame(maxWidth: .infinity)
            .frame(height: style.metrics.height)
            .frame(height: height)
            .background {
                if let backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipped()
            .animation(.smooth(duration: 0.3), value: style.design)
            .task(id: model.ticker?.tapeFrame?.integral.debugDescription) { await loadBackdrop() }
    }

    private func loadBackdrop() async {
        guard let frame = model.ticker?.tapeFrame,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }),
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        // A slice as wide as the pane, ending where the tape meets the Dock.
        let width: CGFloat = 520
        let height: CGFloat = 90
        var region = CGRect(x: frame.maxX - width, y: frame.midY - height / 2, width: width, height: height)
        if model.settings.side == .right { region.origin.x = frame.minX }
        region = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        // Stay on the wallpaper when the tape is narrower than the pane.
        region.origin.x = min(max(region.minX, 0), screen.frame.width - width)
        region.origin.y = max(region.minY, 0)
        let size = screen.frame.size
        let scaling = Wallpaper.scaling(for: screen)
        let scale = screen.backingScaleFactor
        let image = await Task.detached(priority: .userInitiated) {
            Wallpaper.crop(imageAt: url, screenSize: size, region: region, scaling: scaling, scale: scale)
        }.value
        if let image { backdrop = NSImage(cgImage: image, size: region.size) }
    }
}

/// The real stage, as on the desktop, with its glass blurring the preview's wallpaper.
private struct StageView: NSViewRepresentable {
    let items: [TapeItem]
    let slides: [FocusSlide]
    let style: TapeStyle
    let speed: CGFloat
    let dwell: TimeInterval
    let trailing: Bool

    func makeNSView(context: Context) -> TapeStage {
        let stage = TapeStage(preview: true)
        stage.tape.pausesOnHover = true
        return stage
    }

    func updateNSView(_ stage: TapeStage, context: Context) {
        let switched = stage.design != style.design
        stage.configure(design: style.design, metrics: style.metrics, scale: style.scale, focusGlass: style.focusGlass)
        stage.tape.speed = speed
        stage.focus.metrics = FocusMetrics(fontSize: style.fontSize, glass: style.focusGlass)
        stage.focus.dwell = dwell
        stage.focus.alignsTrailing = trailing
        if style.design == .focus {
            stage.tape.setItems([], animated: false)
            stage.focus.setSlides(slides)
        } else {
            stage.focus.setSlides([])
            if switched { stage.tape.setItems([], animated: false) }
            stage.tape.setItems(items, animated: !switched)
        }
    }
}
