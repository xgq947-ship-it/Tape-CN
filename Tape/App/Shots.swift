#if DEBUG
import AppKit
import ScreenCaptureKit

/// Debug builds only. Opened with `-TapeShots <folder>`, Tape photographs its own windows (the tape
/// over the wallpaper behind it, the detail card, each settings pane) and quits. Only Tape's own
/// windows are captured, so no screen-recording permission is needed.
enum Shots {
    static func runIfAsked(model: AppModel) -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "TapeShots") else { return false }
        Task { await run(model, into: URL(fileURLWithPath: path, isDirectory: true)) }
        return true
    }

    private static func run(_ model: AppModel, into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.start()
        for _ in 0..<80 where model.market.quotes.count < model.settings.watchlist.count {
            try? await Task.sleep(for: .milliseconds(250))
        }
        await pause(4)

        let windows = NSApp.windows
        if let tape = windows.first(where: { $0 is TapePanel }) {
            // The tape as it is now, alone and with its transparency, plus where it sits (top-left
            // origin, in points), to lay over a screenshot of the desktop and the Dock.
            await capture(tape, "tape-alpha", into: folder, background: nil)
            if let screen = tape.screen {
                let f = tape.frame, s = screen.frame
                let line = "\(f.minX - s.minX) \(s.maxY - f.maxY) \(f.width) \(f.height) \(s.width) \(s.height) \(screen.backingScaleFactor)\n"
                try? line.write(to: folder.appendingPathComponent("tape-frame.txt"), atomically: true, encoding: .utf8)
            }
            let chosen = model.settings.design
            for design in TapeDesign.allCases {
                model.settings.design = design
                await pause(2.2)
                await captureOverWallpaper(tape, "tape-\(design.rawValue)", into: folder)
            }
            // Focus on glass, and a flip photographed as it happens.
            let glass = model.settings.focusGlass
            model.settings.design = .focus
            model.settings.focusGlass = true
            await pause(1.5)
            await captureOverWallpaper(tape, "tape-focus-glass", into: folder)
            model.settings.focusGlass = false
            await pause(1.5)
            let start = Date()
            model.ticker.flipFocus()
            for frame in 0..<10 {
                await captureOverWallpaper(tape, String(format: "flip-%02d-%03.0fms", frame, Date().timeIntervalSince(start) * 1000), into: folder)
                // Without the wallpaper to lay under each frame, captures come faster than the flip.
                if UserDefaults.standard.bool(forKey: "TapeShotsAlpha") { await pause(0.055) }
            }
            model.settings.focusGlass = glass
            model.settings.design = chosen
            await pause(1)
        }

        // The card for the first listing on the tape.
        if let symbol = model.settings.watchlist.first(where: { model.market.quotes[$0.symbol] != nil })?.symbol,
           let frame = model.ticker.tapeFrame {
            model.ticker.showCard(for: symbol, at: CGRect(x: frame.minX + 120, y: frame.minY + 12, width: 120, height: 18))
            await pause(1.2)
            if let card = NSApp.windows.first(where: { $0.level.rawValue == Int(CGWindowLevelForKey(.dockWindow)) + 1 && $0.isVisible }) {
                await captureOverWallpaper(card, "card", into: folder)
            }
        }

        for tab in SettingsTab.allCases {
            model.openSettings(tab)
            await pause(1.2)
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                await capture(window, "settings-\(tab.title.lowercased())", into: folder, background: nil)
            }
        }
        NSApp.terminate(nil)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Transparent windows are composited onto the wallpaper that's really behind them.
    private static func captureOverWallpaper(_ window: NSWindow, _ name: String, into folder: URL) async {
        // `-TapeShotsAlpha YES` keeps the transparency, to lay the pictures over a real screenshot
        // (an Aerial wallpaper is a video, so the desktop picture macOS reports isn't what's on screen).
        guard !UserDefaults.standard.bool(forKey: "TapeShotsAlpha"),
              let screen = window.screen ?? NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            await capture(window, name, into: folder, background: nil)
            return
        }
        let region = window.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let backdrop = Wallpaper.crop(imageAt: url, screenSize: screen.frame.size, region: region,
                                      scaling: Wallpaper.scaling(for: screen), scale: screen.backingScaleFactor)
        await capture(window, name, into: folder, background: backdrop)
    }

    private static func capture(_ window: NSWindow, _ name: String, into folder: URL, background: CGImage?) async {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
            let scale = window.screen?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = background != nil
            config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
            var output = image
            if let background, let space = CGColorSpace(name: CGColorSpace.sRGB),
               let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                context.draw(background, in: rect)
                context.draw(image, in: rect)
                output = context.makeImage() ?? image
            }
            try NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("\(name).png"))
        } catch {
            NSLog("Shots: \(name) failed: \(error)")
        }
    }
}
#endif
