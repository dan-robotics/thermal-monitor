import Foundation
import ThermalCore

struct HistoryPoint: Identifiable {
    let id: Date
    let cpu: Double?
    let gpu: Double?
}

/// Box so a non-Sendable sampler can live on its own serial queue. Only ever touched there.
private final class QueueBound<T>: @unchecked Sendable {
    private let make: () -> T
    private var _value: T?
    init(_ make: @escaping () -> T) { self.make = make }
    var value: T {
        if let _value { return _value }
        let v = make(); _value = v; return v
    }
}

/// Owns the two sampling loops and publishes the latest snapshot + a short history.
///
/// - Sensor loop: every `refreshInterval` (0.25–5 s) on its own utility queue (~13 ms wall,
///   ~2 ms CPU per tick on M1 Pro; the expensive HID/slow SMC reads refresh every 5 s inside).
/// - Process loop: every 2 s on a second queue, because the /bin/ps fallback takes ~60–150 ms
///   wall and must never delay a temperature tick.
@MainActor
final class ThermalStore: ObservableObject {
    @Published private(set) var snapshot: ThermalSnapshot?
    @Published private(set) var history: [HistoryPoint] = []

    nonisolated static let historySpan: TimeInterval = 60
    nonisolated static let processInterval: TimeInterval = 2
    nonisolated static let topProcessCount = 5

    private let sensorQueue = DispatchQueue(label: "io.github.dan-robotics.ThermalMonitor.sensors", qos: .utility)
    private let processQueue = DispatchQueue(label: "io.github.dan-robotics.ThermalMonitor.processes", qos: .utility)
    private let sensors = QueueBound { SensorSampler() }
    private let processes = QueueBound { ProcessMonitor() }
    private var sensorTimer: DispatchSourceTimer?
    private var processTimer: DispatchSourceTimer?
    private var latestProcesses = ProcessFrame.empty

    private(set) var interval: TimeInterval = 1

    func start(interval: TimeInterval) {
        self.interval = interval
        sensorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sensorQueue)
        // 10% leeway lets macOS coalesce wake-ups with other timers — less energy, same data.
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler(handler: Self.sensorTick(sensors, store: self))
        timer.resume()
        sensorTimer = timer

        if processTimer == nil {
            let pTimer = DispatchSource.makeTimerSource(queue: processQueue)
            pTimer.schedule(deadline: .now(), repeating: Self.processInterval, leeway: .milliseconds(200))
            pTimer.setEventHandler(handler: Self.processTick(processes, store: self))
            pTimer.resume()
            processTimer = pTimer
        }
    }

    // The timer handlers run on the background queues. They are built in nonisolated functions
    // on purpose: a closure written inside a @MainActor method inherits main-actor isolation,
    // and Swift 6 traps at runtime (dispatch_assert_queue) when it then runs off the main thread.
    nonisolated private static func sensorTick(_ sensors: QueueBound<SensorSampler>, store: ThermalStore) -> @Sendable () -> Void {
        { [weak store] in
            let frame = sensors.value.sample()
            Task { @MainActor in store?.apply(frame) }
        }
    }

    nonisolated private static func processTick(_ processes: QueueBound<ProcessMonitor>, store: ThermalStore) -> @Sendable () -> Void {
        { [weak store] in
            let frame = processes.value.sample(top: topProcessCount)
            Task { @MainActor in store?.latestProcesses = frame }
        }
    }

    func stop() {
        sensorTimer?.cancel(); sensorTimer = nil
        processTimer?.cancel(); processTimer = nil
    }

    private func apply(_ frame: SensorFrame) {
        let snap = ThermalSnapshot(frame: frame, processes: latestProcesses)
        snapshot = snap
        history.append(HistoryPoint(id: frame.timestamp, cpu: snap.cpuMax, gpu: snap.gpuMax))
        let cutoff = frame.timestamp.addingTimeInterval(-Self.historySpan)
        if let firstKept = history.firstIndex(where: { $0.id >= cutoff }), firstKept > 0 {
            history.removeFirst(firstKept)
        }
    }

    /// The temperature the menu bar shows, per the user's choice.
    func menuBarValue(_ reading: MenuBarReading) -> Double? {
        guard let snapshot else { return nil }
        switch reading {
        case .hottest: return snapshot.hottest?.celsius
        case .cpu: return snapshot.cpuMax
        case .gpu: return snapshot.gpuMax
        }
    }
}
