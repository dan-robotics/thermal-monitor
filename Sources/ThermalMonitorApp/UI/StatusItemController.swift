import AppKit
import SwiftUI
import Combine
import ThermalCore

/// The menu bar item: a pill coloured by the heat bands, with a thermometer + the live temperature.
/// Left-click opens the dropdown; right-click opens a short menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: ThermalStore
    private let settings: AppSettings
    private let actions: AppActions
    private var cancellables: Set<AnyCancellable> = []

    init(store: ThermalStore, settings: AppSettings, actions: AppActions) {
        self.store = store
        self.settings = settings
        self.actions = actions
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render()

        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.render() } }
            .store(in: &cancellables)
        // the pill always shows a chip reading (hottest chip / CPU / GPU) -> chip scale
        Publishers.Merge4(settings.$menuBarReading.map { _ in () },
                          settings.$chipWarmThreshold.map { _ in () },
                          settings.$chipHotThreshold.map { _ in () },
                          settings.$chipCriticalThreshold.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.render() } }
            .store(in: &cancellables)
    }

    /// Draws the reading as a solid coloured pill image. Coloured *text* in the macOS 27 menu bar
    /// is rendered dimmed/vibrant and was unreadable on dark wallpapers; a non-template image
    /// keeps its exact colours, so the pill stays legible on any menu bar.
    private func render() {
        guard let button = item.button else { return }
        let value = store.menuBarValue(settings.menuBarReading)
        button.title = ""
        button.imagePosition = .imageOnly
        button.contentTintColor = nil
        if let value {
            let tone = settings.chipScale.tone(for: value)
            button.image = Self.pill(text: "\(Int(value.rounded()))°", fill: tone.nsColor, ink: Self.ink(on: tone))
            button.toolTip = "ThermalMonitor · \(settings.menuBarReading.rawValue) \(Int(value.rounded())) °C · \(tone.label)"
        } else {
            let image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "ThermalMonitor")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "ThermalMonitor · reading sensors…"
        }
    }

    /// Dark text on the light fills (green, yellow), white on the strong ones (orange, red).
    private static func ink(on tone: HeatTone) -> NSColor {
        switch tone {
        case .cool, .warm: return NSColor(white: 0.08, alpha: 1)
        case .hot, .critical: return .white
        }
    }

    private static func pill(text: String, fill: NSColor, ink: NSColor) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        let symbol = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let symbolSize = symbol?.size ?? .zero

        let height: CGFloat = 18, padX: CGFloat = 7, gap: CGFloat = 3
        let width = ceil(padX + symbolSize.width + gap + textSize.width + padX)
        let scale: CGFloat = 2   // Retina
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSImage() }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        fill.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
        symbol?.draw(in: NSRect(x: padX, y: (height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
        (text as NSString).draw(at: NSPoint(x: padX + symbolSize.width + gap, y: (height - textSize.height) / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A fresh view each time it opens; dropped on close so nothing renders while hidden.
        let hosting = NSHostingController(rootView: PopoverView(store: store, settings: settings, actions: actions))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: settings.widgetVisible ? "Hide Widget" : "Show Widget", action: #selector(toggleWidget), keyEquivalent: "").target = self
        let mini = menu.addItem(withTitle: "Mini Mode", action: #selector(toggleMini), keyEquivalent: "")
        mini.target = self
        mini.state = settings.miniMode ? .on : .off
        if settings.clickThrough {
            menu.addItem(withTitle: "Turn Off Click-Through", action: #selector(disableClickThrough), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ThermalMonitor", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil   // keep left-click opening the dropdown
    }

    @objc private func toggleWidget() { actions.toggleWidget() }
    @objc private func toggleMini() { settings.miniMode.toggle() }
    @objc private func disableClickThrough() { settings.clickThrough = false }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func quit() { actions.quit() }
}
