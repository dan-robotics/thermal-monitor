import Foundation

/// Temperatures, fans, thermal pressure and GPU load — everything except processes.
public struct SensorFrame: Sendable {
    public let timestamp: Date
    public let sensors: [SensorReading]
    public let fans: [FanReading]
    public let pressure: ThermalPressure
    public let gpuUtilization: Double?
    public let sampleDuration: TimeInterval
}

/// The heat-suspect ranking from one process scan.
public struct ProcessFrame: Sendable {
    public let top: [ProcessHeat]
    public let systemCount: Int
    public static let empty = ProcessFrame(top: [], systemCount: 0)
}

/// Reads the hardware sensors. Not thread-safe on its own: call `sample()` from one serial
/// queue only (the app's sensor queue, or the CLI's main thread).
public final class SensorSampler: @unchecked Sendable {
    let hid = HIDSensors()
    let smc = SMCSensors()

    /// HID + the non-CPU/GPU SMC keys change slowly and are the expensive reads (~80 + ~30 ms
    /// wall on M1 Pro), so they refresh on this slower cadence and are cached in between.
    public var slowSensorInterval: TimeInterval = 5

    private var lastSlowRead: Date = .distantPast
    private var slowCache: [SensorReading] = []

    public init() {}

    public var hidAvailable: Bool { hid.available }
    public var smcAvailable: Bool { smc.available }
    public var smcKeyCount: Int { smc.totalKeyCount }
    public var smcFastKeyCount: Int { smc.fastKeyCount }
    public var smcSlowKeyCount: Int { smc.slowKeyCount }

    public func sample() -> SensorFrame {
        let start = Date()
        if start.timeIntervalSince(lastSlowRead) >= slowSensorInterval {
            slowCache = hid.read() + smc.readTemperatures(fast: false)
            lastSlowRead = start
        }
        let sensors = smc.readTemperatures(fast: true) + slowCache
        return SensorFrame(timestamp: start,
                           sensors: sensors,
                           fans: smc.readFans(),
                           pressure: ThermalPressure(ProcessInfo.processInfo.thermalState),
                           gpuUtilization: GPUStats.utilization(),
                           sampleDuration: Date().timeIntervalSince(start))
    }
}

/// Ranks processes by CPU (and watts where available). Call from one serial queue only — the
/// app runs it on its own queue because the /bin/ps fallback takes ~60–150 ms wall.
public final class ProcessMonitor: @unchecked Sendable {
    let sampler = ProcessSampler()
    public init() {}

    public func sample(top limit: Int) -> ProcessFrame {
        let result = sampler.sample(top: limit)
        return ProcessFrame(top: result.top, systemCount: result.system)
    }
}

/// Convenience for the CLI: both samplers on one thread, producing full snapshots.
public final class ThermalEngine {
    public let sensors = SensorSampler()
    public let processes = ProcessMonitor()

    /// The process scan runs on its own cadence; in between, the last ranking is reused.
    public var processInterval: TimeInterval = 2
    public var topProcessCount = 5

    private var lastProcessScan: Date = .distantPast
    private var lastProcesses = ProcessFrame.empty

    public init() {}

    public var hidAvailable: Bool { sensors.hidAvailable }
    public var smcAvailable: Bool { sensors.smcAvailable }
    public var smcKeyCount: Int { sensors.smcKeyCount }
    public var smcFastKeyCount: Int { sensors.smcFastKeyCount }
    public var smcSlowKeyCount: Int { sensors.smcSlowKeyCount }
    public var slowSensorInterval: TimeInterval { sensors.slowSensorInterval }

    /// Average wall + CPU milliseconds per part over `iterations` runs. Wall time is mostly the
    /// kernel/SMC answering; CPU time is what actually adds heat (`thermal-probe --bench`).
    public func benchmark(iterations: Int = 10) -> [(part: String, wallMs: Double, cpuMs: Double)] {
        func cpuNow() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let user = Double(usage.ru_utime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec) / 1000
            let system = Double(usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_stime.tv_usec) / 1000
            return user + system
        }
        func time(_ part: String, _ body: () -> Void) -> (String, Double, Double) {
            let start = Date(), cpuStart = cpuNow()
            for _ in 0..<iterations { body() }
            let n = Double(iterations)
            return (part, Date().timeIntervalSince(start) * 1000 / n, (cpuNow() - cpuStart) / n)
        }
        return [
            time("HID temps (slow)") { _ = sensors.hid.read() },
            time("SMC temps fast") { _ = sensors.smc.readTemperatures(fast: true) },
            time("SMC temps (slow)") { _ = sensors.smc.readTemperatures(fast: false) },
            time("SMC fans") { _ = sensors.smc.readFans() },
            time("GPU load") { _ = GPUStats.utilization() },
            time("Process scan") { _ = processes.sample(top: topProcessCount) },
            time("Sensor tick (fast)") { _ = sensors.sample() },
        ]
    }

    public func sample() -> ThermalSnapshot {
        let frame = sensors.sample()
        if frame.timestamp.timeIntervalSince(lastProcessScan) >= processInterval {
            lastProcesses = processes.sample(top: topProcessCount)
            lastProcessScan = frame.timestamp
        }
        return ThermalSnapshot(frame: frame, processes: lastProcesses)
    }
}
