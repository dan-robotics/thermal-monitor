import SwiftUI
import AppKit
import ServiceManagement
import ThermalCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var resetWidgetPosition: () -> Void
    var requestAlertPermission: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("General") {
                Picker("Refresh every", selection: $settings.refreshInterval) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { v in
                        Text(v < 1 ? "\(Int(v * 1000)) ms" : "\(Int(v)) s").tag(v)
                    }
                }
                Text("CPU, GPU and fans refresh at this rate. SoC, SSD, battery and case sensors refresh every 5 s, and processes every 2 s. The sensors themselves update about once a second, so faster rates mostly repeat values.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Menu bar shows", selection: $settings.menuBarReading) {
                    ForEach(MenuBarReading.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }

            Section("Chip colours (°C) — CPU, GPU, SoC, memory, near chip, menu bar") {
                threshold("Yellow from", value: $settings.chipWarmThreshold, range: 40...(settings.chipHotThreshold - 1), tone: .warm)
                threshold("Orange from", value: $settings.chipHotThreshold, range: (settings.chipWarmThreshold + 1)...(settings.chipCriticalThreshold - 1), tone: .hot)
                threshold("Red from", value: $settings.chipCriticalThreshold, range: (settings.chipHotThreshold + 1)...110, tone: .critical)
                HStack(spacing: 0) {
                    swatch("< \(Int(settings.chipWarmThreshold))", .cool)
                    swatch("\(Int(settings.chipWarmThreshold))–\(Int(settings.chipHotThreshold))", .warm)
                    swatch("\(Int(settings.chipHotThreshold))–\(Int(settings.chipCriticalThreshold))", .hot)
                    swatch("≥ \(Int(settings.chipCriticalThreshold))", .critical)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("Apple Silicon runs in the 90s under load; macOS only slows it down (thermal pressure) above ~100 °C.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Body colours (°C) — palm rest, battery, SSD, airflow") {
                threshold("Yellow from", value: $settings.warmThreshold, range: 30...(settings.hotThreshold - 1), tone: .warm)
                threshold("Orange from", value: $settings.hotThreshold, range: (settings.warmThreshold + 1)...(settings.criticalThreshold - 1), tone: .hot)
                threshold("Red from", value: $settings.criticalThreshold, range: (settings.hotThreshold + 1)...105, tone: .critical)
                HStack(spacing: 0) {
                    swatch("< \(Int(settings.warmThreshold))", .cool)
                    swatch("\(Int(settings.warmThreshold))–\(Int(settings.hotThreshold))", .warm)
                    swatch("\(Int(settings.hotThreshold))–\(Int(settings.criticalThreshold))", .hot)
                    swatch("≥ \(Int(settings.criticalThreshold))", .critical)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Button("Reset both scales to defaults (chip 70 / 85 / 95 · body 50 / 57 / 62)") { settings.resetColours() }
            }

            Section("Floating widget") {
                Toggle("Show widget", isOn: $settings.widgetVisible)
                Toggle("Mini mode", isOn: $settings.miniMode)
                Toggle("Show top heater", isOn: $settings.widgetShowsHeater)
                Toggle("Keep on top of other windows", isOn: $settings.keepOnTop)
                Toggle("Lock position", isOn: $settings.lockPosition)
                Toggle("Click-through (mouse passes through the widget)", isOn: $settings.clickThrough)
                if settings.clickThrough {
                    Text("To turn this off later, right-click the menu bar thermometer → Turn Off Click-Through.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Border", isOn: $settings.showBorder)
                HStack {
                    Text("Opacity")
                    Slider(value: $settings.widgetOpacity, in: 0.4...1)
                    Text("\(Int(settings.widgetOpacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Button("Move widget back to the top-right corner", action: resetWidgetPosition)
            }

            Section("Alerts") {
                Toggle("Notify me when the hottest chip sensor reaches", isOn: $settings.alertsEnabled)
                    .onChange(of: settings.alertsEnabled) { _, on in if on { requestAlertPermission() } }
                Stepper(value: $settings.alertThreshold, in: 60...105, step: 1) {
                    Text("\(Int(settings.alertThreshold)) °C").monospacedDigit()
                }
                .disabled(!settings.alertsEnabled)
                Text("At most one notification every 5 minutes. It names the top heater at that moment.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Text("Read-only: AppleSMC + IOHID sensors, the kernel's per-process CPU counters, and /bin/ps for system processes. No sudo, no network, no data stored besides these settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
    }

    private func threshold(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, tone: HeatTone) -> some View {
        Stepper(value: value, in: range, step: 1) {
            HStack {
                Circle().fill(tone.color).frame(width: 9, height: 9)
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) °C").monospacedDigit()
            }
        }
    }

    private func swatch(_ text: String, _ tone: HeatTone) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.black.opacity(0.75))
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(tone.color)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change the login item: \(error.localizedDescription). Move ThermalMonitor.app to /Applications and try again."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> SettingsView

    init(makeView: @escaping () -> SettingsView) { self.makeView = makeView }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: makeView()))
            w.title = "ThermalMonitor Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
