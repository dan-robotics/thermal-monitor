import AppKit
import SwiftUI
import Combine

/// The widget's window. It may take key status (so its right-click menu and toggles work) but
/// never becomes the main window, so the app you are working in keeps focus.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WidgetController {
    /// The widget's top-left corner (screen coordinates) is saved here. Not AppKit's frame
    /// autosave: for this borderless, self-sizing panel it restored to a wrong place (x 34).
    static let positionKey = "widgetTopLeft"
    /// Gap between a freshly placed widget and the top-right corner of the usable screen area.
    private static let cornerInset: CGFloat = 16

    private let store: ThermalStore
    private let settings: AppSettings
    private let actions: WidgetActions
    private var panel: WidgetPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var placed = false

    init(store: ThermalStore, settings: AppSettings, actions: WidgetActions) {
        self.store = store
        self.settings = settings
        self.actions = actions
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Lay the SwiftUI card out first so the panel has its real size before it is placed —
        // placing it at its pre-layout (near-zero) width put it mostly off the right edge.
        if let view = panel.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let fit = view.fittingSize
            if fit.width > 0, fit.height > 0 { panel.setContentSize(fit) }
        }
        if !placed {
            if let saved = savedTopLeft() { panel.setFrameTopLeftPoint(saved) } else { placeInTopRightCorner(panel) }
            placed = true
        }
        keepFullyOnScreen(panel)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func resetPosition() {
        guard let panel else { return }
        placeInTopRightCorner(panel)
        saveTopLeft(panel)
    }

    private func savedTopLeft() -> NSPoint? {
        guard let xy = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double], xy.count == 2 else { return nil }
        return NSPoint(x: xy[0], y: xy[1])
    }

    private func saveTopLeft(_ panel: NSPanel) {
        UserDefaults.standard.set([Double(panel.frame.minX), Double(panel.frame.maxY)], forKey: Self.positionKey)
    }

    private func makePanel() -> WidgetPanel {
        let panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 236, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "ThermalMonitor"
        // Behaviour: floats over other apps, on every Space and over full-screen apps, stays put
        // when the app is in the background, and is left out of Cmd-` window cycling.
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        panel.isMovableByWindowBackground = true
        // Look: the SwiftUI card paints its own rounded background and shadow, so the window
        // underneath is fully transparent and draws no shadow of its own.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        // The window follows the SwiftUI card's own size (normal ↔ mini, heater row on/off).
        let hosting = NSHostingController(rootView: WidgetView(store: store, settings: settings, actions: actions))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        panel.contentViewController = hosting

        settings.$keepOnTop
            .sink { [weak panel] onTop in MainActor.assumeIsolated { panel?.level = onTop ? .floating : .normal } }
            .store(in: &cancellables)
        settings.$widgetOpacity
            .sink { [weak panel] opacity in MainActor.assumeIsolated { panel?.alphaValue = opacity } }
            .store(in: &cancellables)
        settings.$clickThrough
            .sink { [weak panel] through in MainActor.assumeIsolated { panel?.ignoresMouseEvents = through } }
            .store(in: &cancellables)

        // Window events, each handled only once the widget is on screen: during the first
        // layout pass the panel briefly has a bogus size, and clamping then pushed it to the
        // far left.
        let events: [(Notification.Name, AnyObject?, (WidgetController, NSPanel) -> Void)] = [
            // The card resized itself (normal ↔ mini, heater row on/off): keep it fully visible.
            (NSWindow.didResizeNotification, panel, { $0.keepFullyOnScreen($1) }),
            // The user dragged it: remember where.
            (NSWindow.didMoveNotification, panel, { $0.saveTopLeft($1) }),
            // Displays were added, removed or rearranged: pull it back onto one that exists.
            (NSApplication.didChangeScreenParametersNotification, nil, { $0.keepFullyOnScreen($1) }),
        ]
        for (name, object, handle) in events {
            NotificationCenter.default.publisher(for: name, object: object)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let widget = self.panel, widget.isVisible else { return }
                        handle(self, widget)
                    }
                }
                .store(in: &cancellables)
        }

        return panel
    }

    /// Slides the panel so it sits entirely inside the visible area of the screen it is mostly
    /// on (or the main screen if it is on none — e.g. a monitor was unplugged). Dragging it
    /// anywhere is still free; this only stops it ending up partly off-screen.
    private func keepFullyOnScreen(_ panel: NSPanel) {
        let frame = panel.frame
        let screen = NSScreen.screens.max { a, b in
            area(a.visibleFrame.intersection(frame)) < area(b.visibleFrame.intersection(frame))
        }
        guard let target = (screen.map { area($0.visibleFrame.intersection(frame)) > 0 } == true ? screen : NSScreen.main)?.visibleFrame
        else { return }
        var origin = frame.origin
        origin.x = min(max(origin.x, target.minX), target.maxX - frame.width)
        origin.y = min(max(origin.y, target.minY), target.maxY - frame.height)
        if origin != frame.origin { panel.setFrameOrigin(origin) }
    }

    private func area(_ r: NSRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// First-run / "Reset position" placement: top-right corner of the main screen's usable
    /// area (below the menu bar, clear of the Dock).
    private func placeInTopRightCorner(_ panel: NSPanel) {
        guard let usable = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let topLeft = NSPoint(x: usable.maxX - panel.frame.width - Self.cornerInset,
                              y: usable.maxY - Self.cornerInset)
        panel.setFrameTopLeftPoint(topLeft)
    }
}
