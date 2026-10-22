import SwiftUI
import ThermalCore

/// What the widget's right-click menu can ask the app to do.
struct WidgetActions {
    var openSettings: () -> Void
    var hide: () -> Void
    var quit: () -> Void
}

/// The floating card: solid background, rounded corners, soft shadow, optional hairline border.
/// Normal mode: CPU / GPU / fan rows with gauges + the top heater. Mini mode: CPU + GPU lines.
struct WidgetView: View {
    @ObservedObject var store: ThermalStore
    @ObservedObject var settings: AppSettings
    let actions: WidgetActions
    @Environment(\.colorScheme) private var colorScheme

    private var cornerRadius: CGFloat { settings.miniMode ? 14 : 18 }
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        let card = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(.horizontal, settings.miniMode ? 12 : 14)
            .padding(.vertical, settings.miniMode ? 10 : 13)
            .frame(width: settings.miniMode ? 176 : 236)
            .background(
                card.fill(Theme.panelBackground)
                    .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 8, y: 3)
            )
            .overlay(
                // Hairline edge in the text colour, faint enough to only separate the card from
                // a background of the same shade.
                card.strokeBorder(Color.primary.opacity(settings.showBorder ? (dark ? 0.16 : 0.12) : 0), lineWidth: 1)
            )
            .modifier(DragUnlessLocked(locked: settings.lockPosition))
            .contextMenu {
                Toggle("Mini Mode", isOn: $settings.miniMode)
                Toggle("Show Top Heater", isOn: $settings.widgetShowsHeater)
                Toggle("Lock Position", isOn: $settings.lockPosition)
                Toggle("Keep on Top", isOn: $settings.keepOnTop)
                Divider()
                Button("Settings…", action: actions.openSettings)
                Button("Hide Widget", action: actions.hide)
                Divider()
                Button("Quit ThermalMonitor", action: actions.quit)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let snap = store.snapshot {
            if settings.miniMode { mini(snap) } else { normal(snap) }
        } else {
            Text("Reading sensors…").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40)
        }
    }

    // MARK: Mini — one line per reading (badge · name · coloured value)

    private func mini(_ snap: ThermalSnapshot) -> some View {
        VStack(spacing: 6) {
            miniRow("CPU", symbol: "cpu", tint: Theme.cpuTint, value: snap.cpuMax)
            miniRow("GPU", symbol: SensorGroup.gpu.symbol, tint: Theme.gpuTint, value: snap.gpuMax)
            if settings.widgetShowsHeater, let top = snap.topProcesses.first {
                heaterRow(top, compact: true)
            }
        }
    }

    private func miniRow(_ title: String, symbol: String, tint: Color, value: Double?) -> some View {
        HStack(spacing: 7) {
            IconBadge(symbol: symbol, tint: tint, size: 15)
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer(minLength: 4)
            Text(Format.temp(value))
                .font(.system(size: 13.5, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(settings.chipScale.tone(for: value ?? 0).color)
        }
    }

    // MARK: Normal

    private func normal(_ snap: ThermalSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            gaugeRow("CPU", symbol: "cpu", tint: Theme.cpuTint, value: snap.cpuMax,
                     detail: cpuDetail(snap))
            gaugeRow("GPU", symbol: SensorGroup.gpu.symbol, tint: Theme.gpuTint, value: snap.gpuMax,
                     detail: snap.gpuUtilization.map { "\(Int($0.rounded()))% busy" })
            if let fan = fanSummary(snap) {
                HStack(spacing: 8) {
                    IconBadge(symbol: "fan.fill", tint: Theme.fanTint, size: 18)
                    Text("Fans").font(.system(size: 14, weight: .bold, design: .rounded))
                    Spacer(minLength: 4)
                    Text(fan < 1 ? "Off" : "\(Int(fan.rounded())) rpm")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(fan < 1 ? Color.secondary : Theme.fanTint)
                        .help(fan < 1 ? "Fans are stopped — normal at light load on Apple Silicon" : "Average of all fans")
                }
            }
            if settings.widgetShowsHeater, let top = snap.topProcesses.first {
                Divider().opacity(0.7)
                heaterRow(top, compact: false)
            }
            HStack(spacing: 5) {
                Circle().fill(snap.pressure.color).frame(width: 6, height: 6)
                Text("Thermal pressure \(snap.pressure.rawValue)")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func gaugeRow(_ title: String, symbol: String, tint: Color, value: Double?, detail: String?) -> some View {
        let tone = settings.chipScale.tone(for: value ?? 0)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                IconBadge(symbol: symbol, tint: tint, size: 18)
                Text(title).font(.system(size: 14, weight: .bold, design: .rounded))
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Format.temp(value))
                    .font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tone.color)
            }
            TempBar(celsius: value, tone: tone, height: 5)
        }
    }

    private func heaterRow(_ p: ProcessHeat, compact: Bool) -> some View {
        let tone = Format.cpuTone(p.cpuPercent)
        return HStack(spacing: compact ? 7 : 8) {
            Image(systemName: "flame.fill")
                .font(.system(size: compact ? 11 : 13))
                .foregroundStyle(tone.color)
                .frame(width: compact ? 15 : 18)
            Text(p.name)
                .font(.system(size: compact ? 11.5 : 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(Format.cpu(p.cpuPercent))
                .font(.system(size: compact ? 11.5 : 12.5, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tone.color)
        }
        .help("Top heater by CPU over the last 2 s · pid \(p.pid)")
    }

    private func cpuDetail(_ snap: ThermalSnapshot) -> String? {
        let p = snap.group(.cpuPerformance)?.maxCelsius, e = snap.group(.cpuEfficiency)?.maxCelsius
        guard let p, let e else { return nil }
        return "P \(Format.temp(p)) · E \(Format.temp(e))"
    }

    private func fanSummary(_ snap: ThermalSnapshot) -> Double? {
        guard !snap.fans.isEmpty else { return nil }
        return snap.fans.map(\.rpm).reduce(0, +) / Double(snap.fans.count)
    }
}

/// Drag the card from anywhere on it — unless the user locked its position.
/// On macOS 27, isMovableByWindowBackground does nothing for a window whose content is all
/// SwiftUI (NSHostingView answers false to mouseDownCanMoveWindow), so the drag comes from
/// SwiftUI's own WindowDragGesture instead.
private struct DragUnlessLocked: ViewModifier {
    let locked: Bool
    func body(content: Content) -> some View {
        if locked { content } else { content.simultaneousGesture(WindowDragGesture()) }
    }
}
