import Foundation

/// Where a reading came from. Both are read-only, no root required.
public enum SensorSource: String, Sendable, Codable {
    case hid = "HID"   // Apple Silicon IOHID temperature sensors (die / SoC / battery / NAND)
    case smc = "SMC"   // AppleSMC keys (temperatures + fans)
}

/// Friendly grouping of the cryptic raw sensor names, in display order.
public enum SensorGroup: String, Sendable, Codable, CaseIterable, Comparable {
    case cpuPerformance = "CPU P-cores"
    case cpuEfficiency  = "CPU E-cores"
    case cpu            = "CPU"
    case gpu            = "GPU"
    case neuralEngine   = "Neural Engine"
    case soc            = "SoC"
    case memory         = "Memory"
    case storage        = "SSD"
    case battery        = "Battery"
    case skin           = "Palm rest"
    case nearChip       = "Near chip (case)"
    case ambient        = "Airflow / ambient"
    case wireless       = "Wi-Fi / Bluetooth"
    case power          = "Power / charger"
    case other          = "Other"

    public static func < (lhs: SensorGroup, rhs: SensorGroup) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Silicon and parts right next to it. They are built to run in the 90s °C under load, so they
    /// get the chip colour scale; everything you can touch or that ages with heat gets the body scale.
    public var isChip: Bool {
        switch self {
        case .cpuPerformance, .cpuEfficiency, .cpu, .gpu, .neuralEngine, .soc, .memory, .nearChip, .power, .other:
            return true
        case .storage, .battery, .skin, .ambient, .wireless:
            return false
        }
    }
}

public struct SensorReading: Sendable, Identifiable, Codable {
    public var id: String { "\(source.rawValue):\(rawName)" }
    public let rawName: String
    public let group: SensorGroup
    public let source: SensorSource
    public let celsius: Double
}

public struct FanReading: Sendable, Identifiable, Codable {
    public var id: Int { index }
    public let index: Int
    public let rpm: Double
    public let minRPM: Double?
    public let maxRPM: Double?

    /// 0...1 position between min and max speed, when both are known.
    public var fraction: Double? {
        guard let minRPM, let maxRPM, maxRPM > minRPM else { return nil }
        return min(max((rpm - minRPM) / (maxRPM - minRPM), 0), 1)
    }
}

/// One process's share of the heat over the last sampling window.
public struct ProcessHeat: Sendable, Identifiable, Codable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    /// CPU time / wall time × 100. Can exceed 100 for multi-threaded work (like Activity Monitor).
    public let cpuPercent: Double
    /// Average power over the window, from the kernel's per-process energy counter (ri_energy_nj).
    /// nil for other users' processes — the kernel only shares that counter with the owner.
    public let watts: Double?
    /// Owned by another user (root, _windowserver …): CPU % comes from /bin/ps instead.
    public let isSystem: Bool
}

/// macOS' own thermal pressure verdict (ProcessInfo.thermalState).
public enum ThermalPressure: String, Sendable, Codable {
    case nominal = "Nominal", fair = "Fair", serious = "Serious", critical = "Critical"

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

/// Colour bands for a temperature. Two scales, both adjustable in Settings:
///   body (`default`) — palm rest, battery, SSD, airflow: red from 62 °C
///   chip (`chip`)    — CPU / GPU / SoC / memory: Apple Silicon runs 90+ °C under load and only
///                      slows down (thermal pressure) above ~100 °C, so red from 95 °C
public struct HeatScale: Sendable, Codable, Equatable {
    public var warm: Double     // green  → yellow
    public var hot: Double      // yellow → orange
    public var critical: Double // orange → red

    public static let `default` = HeatScale(warm: 50, hot: 57, critical: 62)
    public static let chip = HeatScale(warm: 70, hot: 85, critical: 95)

    /// The default scale for a sensor group (the app uses the user's own values instead).
    public static func `for`(_ group: SensorGroup) -> HeatScale { group.isChip ? .chip : .default }

    public init(warm: Double, hot: Double, critical: Double) {
        self.warm = warm; self.hot = hot; self.critical = critical
    }

    public func tone(for celsius: Double) -> HeatTone {
        switch celsius {
        case critical...: return .critical
        case hot..<critical: return .hot
        case warm..<hot: return .warm
        default: return .cool
        }
    }
}

public enum HeatTone: String, Sendable, Codable, Comparable {
    case cool, warm, hot, critical

    public static func < (lhs: HeatTone, rhs: HeatTone) -> Bool {
        let order: [HeatTone] = [.cool, .warm, .hot, .critical]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public struct GroupSummary: Sendable, Identifiable, Codable {
    public var id: SensorGroup { group }
    public let group: SensorGroup
    public let maxCelsius: Double
    public let averageCelsius: Double
    public let sensorCount: Int
}

public struct ThermalSnapshot: Sendable, Codable {
    public let timestamp: Date
    public let sensors: [SensorReading]
    public let fans: [FanReading]
    public let pressure: ThermalPressure
    /// GPU busy % from IOAccelerator "Device Utilization %", if the driver reports it.
    public let gpuUtilization: Double?
    /// Top processes by CPU %, all users. Empty on the very first sample (needs a delta).
    public let topProcesses: [ProcessHeat]
    /// Other users' processes whose CPU came from /bin/ps (no watts for these).
    public let systemProcessCount: Int
    /// How long the sample itself took — keeps the monitor honest about its own cost.
    public let sampleDuration: TimeInterval

    public init(frame: SensorFrame, processes: ProcessFrame) {
        timestamp = frame.timestamp
        sensors = frame.sensors
        fans = frame.fans
        pressure = frame.pressure
        gpuUtilization = frame.gpuUtilization
        topProcesses = processes.top
        systemProcessCount = processes.systemCount
        sampleDuration = frame.sampleDuration
        groups = Self.summarise(frame.sensors)
    }

    /// Per-group max/average, computed once per snapshot (the UI reads it many times per render).
    /// HID preferred where a group has HID sensors.
    public let groups: [GroupSummary]

    static func summarise(_ sensors: [SensorReading]) -> [GroupSummary] {
        let byGroup = Dictionary(grouping: sensors, by: \.group)
        return byGroup.keys.sorted().compactMap { group in
            let all = byGroup[group]!
            let hid = all.filter { $0.source == .hid }
            let use = hid.isEmpty ? all : hid
            let values = use.map(\.celsius)
            guard let maxValue = values.max() else { return nil }
            return GroupSummary(group: group, maxCelsius: maxValue,
                                averageCelsius: values.reduce(0, +) / Double(values.count),
                                sensorCount: values.count)
        }
    }

    public func group(_ group: SensorGroup) -> GroupSummary? { groups.first { $0.group == group } }

    /// Hottest CPU reading across P/E/generic CPU groups.
    public var cpuMax: Double? {
        [SensorGroup.cpuPerformance, .cpuEfficiency, .cpu].compactMap { self.group($0)?.maxCelsius }.max()
    }

    public var gpuMax: Double? { group(.gpu)?.maxCelsius }

    /// Hottest of the chip groups — the number shown in the menu bar.
    public var hottest: SensorReading? {
        let chip: Set<SensorGroup> = [.cpuPerformance, .cpuEfficiency, .cpu, .gpu, .soc, .neuralEngine]
        return sensors.filter { chip.contains($0.group) }.max { $0.celsius < $1.celsius }
            ?? sensors.max { $0.celsius < $1.celsius }
    }
}
