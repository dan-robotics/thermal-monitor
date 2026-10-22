import Foundation
import ThermalCore

/// Which reading the menu bar shows.
enum MenuBarReading: String, CaseIterable, Identifiable {
    case hottest = "Hottest chip sensor"
    case cpu = "CPU"
    case gpu = "GPU"
    var id: String { rawValue }
}

/// All user preferences, persisted in UserDefaults (io.github.dan-robotics.ThermalMonitor).
@MainActor
final class AppSettings: ObservableObject {
    static let refreshChoices: [Double] = [0.25, 0.5, 1, 2, 5]

    private let defaults = UserDefaults.standard

    @Published var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var menuBarReading: MenuBarReading { didSet { defaults.set(menuBarReading.rawValue, forKey: "menuBarReading") } }

    // Colour bands (°C). Kept ordered warm < hot < critical by the Settings UI.
    @Published var warmThreshold: Double { didSet { defaults.set(warmThreshold, forKey: "warmThreshold") } }
    @Published var hotThreshold: Double { didSet { defaults.set(hotThreshold, forKey: "hotThreshold") } }
    @Published var criticalThreshold: Double { didSet { defaults.set(criticalThreshold, forKey: "criticalThreshold") } }
    @Published var chipWarmThreshold: Double { didSet { defaults.set(chipWarmThreshold, forKey: "chipWarmThreshold") } }
    @Published var chipHotThreshold: Double { didSet { defaults.set(chipHotThreshold, forKey: "chipHotThreshold") } }
    @Published var chipCriticalThreshold: Double { didSet { defaults.set(chipCriticalThreshold, forKey: "chipCriticalThreshold") } }

    // Floating widget
    @Published var widgetVisible: Bool { didSet { defaults.set(widgetVisible, forKey: "widgetVisible") } }
    @Published var miniMode: Bool { didSet { defaults.set(miniMode, forKey: "miniMode") } }
    @Published var keepOnTop: Bool { didSet { defaults.set(keepOnTop, forKey: "keepOnTop") } }
    @Published var widgetOpacity: Double { didSet { defaults.set(widgetOpacity, forKey: "widgetOpacity") } }
    @Published var lockPosition: Bool { didSet { defaults.set(lockPosition, forKey: "lockPosition") } }
    @Published var clickThrough: Bool { didSet { defaults.set(clickThrough, forKey: "clickThrough") } }
    @Published var showBorder: Bool { didSet { defaults.set(showBorder, forKey: "showBorder") } }
    @Published var widgetShowsHeater: Bool { didSet { defaults.set(widgetShowsHeater, forKey: "widgetShowsHeater") } }

    // Alerts
    @Published var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled") } }
    @Published var alertThreshold: Double { didSet { defaults.set(alertThreshold, forKey: "alertThreshold") } }

    /// Body scale: palm rest, battery, SSD, airflow (the original "red from 62").
    var scale: HeatScale { HeatScale(warm: warmThreshold, hot: hotThreshold, critical: criticalThreshold) }
    /// Chip scale: CPU, GPU, SoC, memory, near-chip.
    var chipScale: HeatScale { HeatScale(warm: chipWarmThreshold, hot: chipHotThreshold, critical: chipCriticalThreshold) }
    func scale(for group: SensorGroup) -> HeatScale { group.isChip ? chipScale : scale }

    init() {
        let d = UserDefaults.standard
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) == nil ? fallback : d.double(forKey: key) }
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }

        let storedInterval = double("refreshInterval", 1)
        refreshInterval = Self.refreshChoices.contains(storedInterval) ? storedInterval : 1
        menuBarReading = MenuBarReading(rawValue: d.string(forKey: "menuBarReading") ?? "") ?? .hottest
        warmThreshold = double("warmThreshold", HeatScale.default.warm)
        hotThreshold = double("hotThreshold", HeatScale.default.hot)
        criticalThreshold = double("criticalThreshold", HeatScale.default.critical)
        chipWarmThreshold = double("chipWarmThreshold", HeatScale.chip.warm)
        chipHotThreshold = double("chipHotThreshold", HeatScale.chip.hot)
        chipCriticalThreshold = double("chipCriticalThreshold", HeatScale.chip.critical)
        widgetVisible = bool("widgetVisible", true)
        miniMode = bool("miniMode", false)
        keepOnTop = bool("keepOnTop", true)
        widgetOpacity = double("widgetOpacity", 1)
        lockPosition = bool("lockPosition", false)
        clickThrough = bool("clickThrough", false)
        showBorder = bool("showBorder", true)
        widgetShowsHeater = bool("widgetShowsHeater", true)
        alertsEnabled = bool("alertsEnabled", false)
        alertThreshold = double("alertThreshold", 85)
    }

    func resetColours() {
        warmThreshold = HeatScale.default.warm
        hotThreshold = HeatScale.default.hot
        criticalThreshold = HeatScale.default.critical
        chipWarmThreshold = HeatScale.chip.warm
        chipHotThreshold = HeatScale.chip.hot
        chipCriticalThreshold = HeatScale.chip.critical
    }
}
