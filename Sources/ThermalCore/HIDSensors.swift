import CSensors

/// Apple Silicon IOHID temperature sensors.
final class HIDSensors {
    private var buffer = [tm_hid_sensor](repeating: tm_hid_sensor(), count: 128)

    /// False if the HID event system client could not be created (e.g. a future macOS change).
    private(set) var available = true

    func read() -> [SensorReading] {
        let count = buffer.withUnsafeMutableBufferPointer { tm_hid_read($0.baseAddress, Int32($0.count)) }
        guard count >= 0 else { available = false; return [] }

        var readings: [SensorReading] = []
        var seen: [String: Int] = [:]
        for i in 0..<Int(count) {
            let name = withUnsafeBytes(of: buffer[i].name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let value = buffer[i].celsius
            // tcal is a fixed calibration value, not a live temperature; out-of-range values are
            // sensors that are powered down or not populated on this model.
            guard !name.lowercased().contains("tcal"), value > 1, value < 130 else { continue }
            // Some sensors share a product name; keep them distinct.
            let n = seen[name, default: 0]; seen[name] = n + 1
            let rawName = n == 0 ? name : "\(name) #\(n + 1)"
            readings.append(SensorReading(rawName: rawName, group: Self.classify(name), source: .hid, celsius: value))
        }
        return readings
    }

    static func classify(_ name: String) -> SensorGroup {
        let n = name.lowercased()
        if n.hasPrefix("pacc") { return .cpuPerformance }
        if n.hasPrefix("eacc") { return .cpuEfficiency }
        if n.hasPrefix("gpu") { return .gpu }
        if n.hasPrefix("ane") { return .neuralEngine }
        if n.contains("nand") { return .storage }
        if n.contains("battery") || n.contains("gas gauge") { return .battery }
        if n.hasPrefix("soc") || n.hasPrefix("pmu") || n.hasPrefix("isp") { return .soc }
        return .other
    }
}
