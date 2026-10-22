import SwiftUI
import Charts
import ThermalCore

/// What the menu bar dropdown can ask the app to do.
struct AppActions {
    var toggleWidget: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
}

/// The menu bar dropdown: everything about what is heating the Mac right now.
struct PopoverView: View {
    @ObservedObject var store: ThermalStore
    @ObservedObject var settings: AppSettings
    let actions: AppActions
    @State private var showAllSensors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snap = store.snapshot {
                header(snap)
                groups(snap)
                fans(snap)
                chart
                suspects(snap)
                allSensors(snap)
            } else {
                ProgressView("Reading sensors…").frame(maxWidth: .infinity, minHeight: 120)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 350)
    }

    // MARK: Header — hottest reading, its verdict, macOS thermal pressure

    private func header(_ snap: ThermalSnapshot) -> some View {
        let hottest = snap.hottest
        let tone = settings.scale(for: hottest?.group ?? .cpu).tone(for: hottest?.celsius ?? 0)
        // the colour says how hot; macOS' thermal pressure says whether it is slowing the Mac down
        let verdict: String = {
            guard tone >= .hot else { return tone.label }
            switch snap.pressure {
            case .nominal: return "\(tone.label) · no slowdown"
            case .fair: return "\(tone.label) · near the limit"
            case .serious, .critical: return "\(tone.label) · macOS slowing down"
            }
        }()
        return HStack(alignment: .center, spacing: 12) {
            Text(Format.temp(hottest?.celsius))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("Hottest: \(hottest.map { "\($0.group.rawValue) · \($0.rawName)" } ?? "—")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(snap.pressure.color).frame(width: 7, height: 7)
                    Text("macOS thermal pressure: \(snap.pressure.rawValue)")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Sensor groups

    private func groups(_ snap: ThermalSnapshot) -> some View {
        let rows = SensorGroup.headline.compactMap { snap.group($0) }
        return VStack(spacing: 7) {
            ForEach(rows) { g in
                let tone = settings.scale(for: g.group).tone(for: g.maxCelsius)
                HStack(spacing: 8) {
                    IconBadge(symbol: g.group.symbol, tint: g.group.tint, size: 18)
                    Text(g.group.rawValue).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .frame(width: 112, alignment: .leading)
                    TempBar(celsius: g.maxCelsius, tone: tone)
                    if g.group == .gpu, let load = snap.gpuUtilization {
                        Text("\(Int(load.rounded()))%").font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    Text(Format.temp(g.maxCelsius))
                        .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(tone.color)
                        .frame(width: 38, alignment: .trailing)
                }
                .help("\(g.group.rawValue): max \(Format.temp(g.maxCelsius)), average \(Format.temp(g.averageCelsius)) across \(g.sensorCount) sensors")
            }
        }
    }

    // MARK: Fans

    @ViewBuilder
    private func fans(_ snap: ThermalSnapshot) -> some View {
        if !snap.fans.isEmpty {
            VStack(spacing: 6) {
                ForEach(snap.fans) { fan in
                    HStack(spacing: 8) {
                        IconBadge(symbol: "fan.fill", tint: Theme.fanTint, size: 18)
                        Text("Fan \(fan.index + 1)").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .frame(width: 112, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule().fill(Theme.fanTint.gradient)
                                    .frame(width: proxy.size.width * (fan.fraction ?? 0))
                            }
                        }
                        .frame(height: 4)
                        Text(fan.rpm < 1 ? "Off" : "\(Int(fan.rpm.rounded())) rpm")
                            .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(fan.rpm < 1 ? Color.secondary : Color.primary)
                            .frame(width: 68, alignment: .trailing)
                    }
                    .help(fan.rpm < 1 ? "Stopped — Apple Silicon fans switch off at light load"
                          : (fan.minRPM != nil && fan.maxRPM != nil ? "Range \(Int(fan.minRPM!))–\(Int(fan.maxRPM!)) rpm while spinning" : ""))
                }
            }
        }
    }

    // MARK: 60 s history

    private var chart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last 60 seconds").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                legend("CPU", Theme.cpuTint)
                legend("GPU", Theme.gpuTint)
            }
            Chart {
                ForEach(store.history) { point in
                    if let cpu = point.cpu {
                        LineMark(x: .value("Time", point.id), y: .value("°C", cpu), series: .value("Sensor", "CPU"))
                            .foregroundStyle(Theme.cpuTint)
                            .interpolationMethod(.monotone)
                    }
                    if let gpu = point.gpu {
                        LineMark(x: .value("Time", point.id), y: .value("°C", gpu), series: .value("Sensor", "GPU"))
                            .foregroundStyle(Theme.gpuTint)
                            .interpolationMethod(.monotone)
                    }
                }
                RuleMark(y: .value("Red from", settings.criticalThreshold))
                    .foregroundStyle(.red.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: chartDomain)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))°").font(.system(size: 9)) } }
                }
            }
            .frame(height: 70)
        }
    }

    private var chartDomain: ClosedRange<Double> {
        let values = store.history.flatMap { [$0.cpu, $0.gpu].compactMap { $0 } } + [settings.criticalThreshold]
        let low = (values.min() ?? 30) - 3, high = (values.max() ?? 80) + 3
        return low...max(high, low + 10)
    }

    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 10, height: 3)
            Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: Heat suspects

    private func suspects(_ snap: ThermalSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("What's heating it (CPU, last 2 s)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if snap.topProcesses.isEmpty {
                Text("Measuring…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(snap.topProcesses) { p in
                let tone = Format.cpuTone(p.cpuPercent)
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill").foregroundStyle(tone.color).font(.system(size: 12))
                        .frame(width: 18)
                    Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if p.isSystem {
                        Text("system").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(Format.cpu(p.cpuPercent))
                        .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(tone.color)
                }
                .help("pid \(p.pid)\(p.isSystem ? " · owned by a system user, CPU read via /bin/ps" : "")")
            }
        }
    }

    // MARK: Every raw sensor (collapsed)

    private func allSensors(_ snap: ThermalSnapshot) -> some View {
        DisclosureGroup(isExpanded: $showAllSensors) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(snap.sensors.sorted { ($0.group, $0.rawName) < ($1.group, $1.rawName) }) { r in
                        HStack {
                            Text(r.group.rawValue).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Text("\(r.rawName)").lineLimit(1)
                            Spacer()
                            Text(Format.temp(r.celsius)).monospacedDigit()
                                .foregroundStyle(settings.scale(for: r.group).tone(for: r.celsius).color)
                        }
                        .font(.system(size: 10.5))
                    }
                }
            }
            .frame(height: 160)
        } label: {
            Text("All sensors (\(snap.sensors.count))").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer — refresh, widget, settings, quit

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Refresh").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $settings.refreshInterval) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { v in
                        Text(v < 1 ? "\(Int(v * 1000)) ms" : "\(Int(v)) s").tag(v)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            HStack(spacing: 10) {
                Toggle("Widget", isOn: Binding(get: { settings.widgetVisible }, set: { _ in actions.toggleWidget() }))
                Toggle("Mini", isOn: $settings.miniMode)
                Spacer()
                Button("Settings…", action: actions.openSettings)
                Button("Quit", action: actions.quit)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            if let snap = store.snapshot {
                Text(String(format: "Sensor tick %.0f ms · %d system processes read via ps", snap.sampleDuration * 1000, snap.systemProcessCount))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
