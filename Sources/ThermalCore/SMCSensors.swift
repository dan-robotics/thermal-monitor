import CSensors

/// AppleSMC temperature keys + fans. The full key table (~1–3k keys) is scanned once at start;
/// each tick only re-reads the temperature keys that returned a plausible value.
final class SMCSensors {
    /// Read every tick: CPU P/E cores, CPU cluster/max keys, GPU.
    private var fastKeys: [tm_smc_key] = []
    /// Read on the slow cadence: everything else (SoC, memory, SSD, battery, case, ambient …).
    private var slowKeys: [tm_smc_key] = []
    private var fanKeys: [(index: Int, actual: tm_smc_key, min: tm_smc_key?, max: tm_smc_key?)] = []

    private(set) var available = false
    private(set) var totalKeyCount = 0

    init() {
        guard tm_smc_open() == 0 else { return }
        available = true
        discover()
    }

    deinit { tm_smc_close() }

    private func discover() {
        totalKeyCount = Int(tm_smc_key_count())
        guard totalKeyCount > 0 else { return }

        for index in 0..<UInt32(totalKeyCount) {
            var key = tm_smc_key()
            guard tm_smc_key_at(index, &key) == 0 else { continue }
            let name = Self.string(key.key)
            let type = Self.string(key.type)
            guard name.hasPrefix("T"), ["flt ", "sp78", "fpe2"].contains(type) else { continue }
            var value = 0.0
            if tm_smc_read_double(&key, &value) == 0, value > 1, value < 130 {
                if Self.isFast(name) { fastKeys.append(key) } else { slowKeys.append(key) }
            }
        }

        var count = 0.0
        if var fnum = info("FNum"), tm_smc_read_double(&fnum, &count) == 0 {
            for i in 0..<Int(count) {
                if let actual = info("F\(i)Ac") {
                    fanKeys.append((i, actual, info("F\(i)Mn"), info("F\(i)Mx")))
                }
            }
        }
    }

    private func info(_ name: String) -> tm_smc_key? {
        var key = tm_smc_key()
        return tm_smc_key_info(name, &key) == 0 ? key : nil
    }

    var fastKeyCount: Int { fastKeys.count }
    var slowKeyCount: Int { slowKeys.count }

    func readTemperatures(fast: Bool) -> [SensorReading] {
        (fast ? fastKeys : slowKeys).compactMap { key in
            var key = key
            var value = 0.0
            guard tm_smc_read_double(&key, &value) == 0, value > 1, value < 130 else { return nil }
            let name = Self.string(key.key)
            return SensorReading(rawName: name, group: Self.classify(name), source: .smc, celsius: value)
        }
    }

    func readFans() -> [FanReading] {
        fanKeys.compactMap { fan in
            guard let rpm = read(fan.actual) else { return nil }
            return FanReading(index: fan.index, rpm: rpm,
                              minRPM: fan.min.flatMap(read), maxRPM: fan.max.flatMap(read))
        }
    }

    private func read(_ key: tm_smc_key) -> Double? {
        var key = key
        var value = 0.0
        return tm_smc_read_double(&key, &value) == 0 ? value : nil
    }

    /// SMC key prefixes → groups. Apple doesn't document these; the mapping follows the
    /// long-standing community tables (Stats / iStat / smcFanControl).
    static func classify(_ key: String) -> SensorGroup {
        let p = String(key.prefix(2))
        switch p {
        case "Tp": return .cpuPerformance
        case "Te": return .cpuEfficiency
        case "TC": return .cpu
        case "Tg", "TG": return .gpu
        case "Tm", "TM": return .memory
        case "TH": return .storage
        case "TB": return .battery
        // Ts0P / Ts1P = palm rest (~30-40 °C). The other Ts keys (Ts00-Ts06 on M1 Pro) read
        // 65+ °C under load and track the CPU - inside the case near the chip, not where you touch.
        case "Ts": return key.hasSuffix("P") ? .skin : .nearChip
        case "Ta", "TA": return .ambient
        case "TW": return .wireless
        case "TP", "TV", "Tc": return .power
        default: return .other
        }
    }

    static func isFast(_ key: String) -> Bool {
        ["Tp", "Te", "TC", "Tg", "TG"].contains(String(key.prefix(2)))
    }

    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}
