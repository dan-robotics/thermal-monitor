// thermal-probe — Phase 1 sensor check for ThermalMonitor.
//
// HOW TO RUN (from the project folder):
//   swift run thermal-probe                 one full snapshot (waits 2 s so process deltas exist)
//   swift run thermal-probe --raw           every raw sensor name/value, grouped
//   swift run thermal-probe --watch         live one-line view, 1 s refresh, Ctrl+C to stop
//   swift run thermal-probe --watch --interval 0.25
//   swift run thermal-probe --help
//
// Read-only: reads IOHID + AppleSMC sensors and per-process rusage. Writes no files,
// needs no sudo, makes no network calls.

import Foundation
import ThermalCore

let usage = """
thermal-probe — ThermalMonitor sensor check (read-only, no sudo, writes nothing)

USAGE
  swift run thermal-probe [--raw] [--watch] [--interval SECONDS] [--top N]

OPTIONS
  (none)              One full snapshot: groups, fans, GPU load, heat suspects.
  --raw               Also list every raw sensor (HID + SMC) with its value.
  --bench             Time each sensor source (the monitor's own cost).
  --watch             Live one-line view until Ctrl+C.
  --interval SECONDS  Refresh for --watch, 0.25–5 (default 1).
  --top N             How many heat suspects to show (default 5).
  -h, --help          This help.

EXAMPLES
  swift run thermal-probe
  swift run thermal-probe --raw
  swift run thermal-probe --watch --interval 0.5
"""

var raw = false, bench = false, watch = false, interval = 1.0, top = 5
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "-h", "--help": print(usage); exit(0)
    case "--raw": raw = true
    case "--bench": bench = true
    case "--watch": watch = true
    case "--interval":
        guard let v = args.popFirst().flatMap(Double.init), (0.25...5).contains(v) else {
            FileHandle.standardError.write("--interval needs a number between 0.25 and 5\n".data(using: .utf8)!); exit(2)
        }
        interval = v
    case "--top":
        guard let v = args.popFirst().flatMap(Int.init), v > 0 else {
            FileHandle.standardError.write("--top needs a positive whole number\n".data(using: .utf8)!); exit(2)
        }
        top = v
    default:
        FileHandle.standardError.write("Unknown option: \(arg)\n\n\(usage)\n".data(using: .utf8)!); exit(2)
    }
}

let scale = HeatScale.default      // body scale; chip groups use HeatScale.chip
let useColor = isatty(STDOUT_FILENO) != 0

func paint(_ text: String, _ tone: HeatTone) -> String {
    guard useColor else { return text }
    let code = switch tone { case .cool: "32"; case .warm: "33"; case .hot: "38;5;208"; case .critical: "31;1" }
    return "\u{1B}[\(code)m\(text)\u{1B}[0m"
}

func temp(_ c: Double?, _ group: SensorGroup = .cpu) -> String {
    guard let c else { return "  —  " }
    return paint(String(format: "%5.1f°", c), HeatScale.for(group).tone(for: c))
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

let setupStart = Date()
let engine = ThermalEngine()
engine.topProcessCount = top
engine.processInterval = watch ? max(interval, 2) : 0
let setupTime = Date().timeIntervalSince(setupStart)

if bench {
    print("Average cost per part (10 runs):")
    print("  PART                  WALL       CPU")
    for (part, wall, cpu) in engine.benchmark() {
        print("  \(pad(part, 18)) \(String(format: "%7.2f ms  %7.2f ms", wall, cpu))")
    }
    print("SMC keys: \(engine.smcFastKeyCount) fast (every tick) · \(engine.smcSlowKeyCount) slow (every \(Int(engine.slowSensorInterval)) s, with HID)")
    exit(0)
}

if watch {
    _ = engine.sample()
    signal(SIGINT) { _ in print(""); exit(0) }
    while true {
        let s = engine.sample()
        let suspect = s.topProcesses.first.map { String(format: "%@ %.0f%%", $0.name, $0.cpuPercent) } ?? "…"
        let fan = s.fans.first.map { String(format: "%.0f rpm", $0.rpm) } ?? "no fan"
        let gpuLoad = s.gpuUtilization.map { String(format: "%.0f%%", $0) } ?? "—"
        let line = "CPU \(temp(s.cpuMax))  GPU \(temp(s.gpuMax)) (\(gpuLoad))  Fan \(fan)  \(s.pressure.rawValue)  🔥 \(suspect)"
        print("\r\u{1B}[2K\(line)", terminator: "")
        fflush(stdout)
        Thread.sleep(forTimeInterval: interval)
    }
}

// Single snapshot: the first sample primes process deltas, the second (2 s later) ranks them.
_ = engine.sample()
Thread.sleep(forTimeInterval: 2)
let s = engine.sample()

print("ThermalMonitor · thermal-probe   \(s.timestamp.formatted(date: .abbreviated, time: .standard))")
print("Sources: HID \(engine.hidAvailable ? "OK" : "UNAVAILABLE")  ·  SMC \(engine.smcAvailable ? "OK (\(engine.smcKeyCount) keys)" : "UNAVAILABLE")"
      + String(format: "  ·  setup %.0f ms, sample %.1f ms", setupTime * 1000, s.sampleDuration * 1000))
print("Thermal pressure: \(s.pressure.rawValue)    Red from: chip ≥\(Int(HeatScale.chip.critical))° (CPU/GPU/SoC/memory/near chip) · body ≥\(Int(scale.critical))° (palm rest/battery/SSD/airflow)")
print("")

print("GROUP                 MAX     AVG   SENSORS")
for g in s.groups {
    print("\(pad(g.group.rawValue, 20))  \(temp(g.maxCelsius, g.group))  \(temp(g.averageCelsius, g.group))  \(g.sensorCount)")
}
if let hottest = s.hottest {
    print("\nHottest: \(hottest.rawName) [\(hottest.source.rawValue)] \(temp(hottest.celsius, hottest.group))")
}

print("")
if s.fans.isEmpty { print("Fans: none reported") }
for f in s.fans {
    let range = (f.minRPM != nil && f.maxRPM != nil) ? String(format: "  (min %.0f / max %.0f)", f.minRPM!, f.maxRPM!) : ""
    print(String(format: "Fan %d: %.0f rpm", f.index, f.rpm) + range)
}
print("GPU load: \(s.gpuUtilization.map { String(format: "%.0f%%", $0) } ?? "not reported")")

print("\nHEAT SUSPECTS (last 2 s)          CPU     POWER")
for p in s.topProcesses {
    let watts = p.watts.map { String(format: "%5.2f W", $0) } ?? "  n/a  "
    print("\(pad(p.name, 30))  \(String(format: "%5.1f%%", p.cpuPercent))   \(watts)   pid \(p.pid)\(p.isSystem ? "  (system, via ps)" : "")")
}
if s.topProcesses.isEmpty { print("(none measured)") }
print("(\(s.systemProcessCount) system processes measured via /bin/ps: CPU only, no watts)")

if raw {
    print("\nRAW SENSORS")
    for reading in s.sensors.sorted(by: { ($0.group, $0.source.rawValue, $0.rawName) < ($1.group, $1.source.rawValue, $1.rawName) }) {
        print("  \(pad(reading.group.rawValue, 18)) \(reading.source.rawValue)  \(pad(reading.rawName, 26)) \(temp(reading.celsius, reading.group))")
    }
}
