// ThermalMonitor — menu bar + floating-widget temperature monitor for Apple Silicon Macs.
//
// HOW TO RUN
//   ./build.sh                 build ThermalMonitor.app + timestamped DMG into dist/
//   open dist/ThermalMonitor.app
//   swift run ThermalMonitor   quick dev run without a bundle (no notifications / login item)

import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let store = ThermalStore()
    private var statusItem: StatusItemController?
    private var widget: WidgetController?
    private var settingsWindow: SettingsWindowController?
    private var alerts: AlertManager?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon (also LSUIElement)

        let widget = WidgetController(store: store, settings: settings, actions: WidgetActions(
            openSettings: { [weak self] in self?.settingsWindow?.show() },
            hide: { [weak self] in self?.settings.widgetVisible = false },
            quit: { NSApp.terminate(nil) }))
        self.widget = widget

        let alerts = AlertManager(store: store, settings: settings)
        self.alerts = alerts

        settingsWindow = SettingsWindowController { [settings] in
            SettingsView(settings: settings,
                         resetWidgetPosition: { widget.resetPosition() },
                         requestAlertPermission: { alerts.requestPermission() })
        }

        statusItem = StatusItemController(store: store, settings: settings, actions: AppActions(
            toggleWidget: { [weak self] in self?.settings.widgetVisible.toggle() },
            openSettings: { [weak self] in self?.settingsWindow?.show() },
            quit: { NSApp.terminate(nil) }))

        settings.$widgetVisible
            .receive(on: RunLoop.main)
            .sink { visible in MainActor.assumeIsolated { visible ? widget.show() : widget.hide() } }
            .store(in: &cancellables)
        settings.$refreshInterval
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] interval in MainActor.assumeIsolated { self?.store.start(interval: interval) } }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) { store.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
