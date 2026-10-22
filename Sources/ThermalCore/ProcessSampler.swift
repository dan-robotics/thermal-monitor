import Darwin
import Foundation

/// Per-process CPU and power from proc_pid_rusage(RUSAGE_INFO_V6). Values are deltas between
/// two calls, so the first call returns no ranking.
///
/// Processes owned by other users (root daemons, WindowServer, coreaudiod) return EPERM to
/// proc_pid_rusage. For those, CPU % comes from /bin/ps — a setuid-root system binary that
/// may read every process — so the biggest system heaters still show up. ps' %CPU is the
/// kernel's short decaying average rather than an exact delta, and ps cannot give watts.

final class ProcessSampler {
    private struct Sample { let cpuNs: UInt64; let energyNj: UInt64 }

    private var previous: [pid_t: Sample] = [:]
    private var previousTime: UInt64 = 0
    private var names: [pid_t: String] = [:]

    /// /bin/ps costs ~50 ms CPU per run and its %CPU is already a decaying average, so it runs
    /// on this slower cadence and its result is reused in between.
    var psInterval: TimeInterval = 6
    private var psCache: [(pid: pid_t, cpu: Double, name: String)] = []
    private var psCacheTime: Date = .distantPast
    /// pids that already refused proc_pid_rusage (other users' processes stay that way), so
    /// the scan stops asking the kernel about them every 2 s.
    private var knownUnreadable: Set<pid_t> = []
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    func sample(top limit: Int) -> (top: [ProcessHeat], system: Int) {
        let now = mach_absolute_time()
        let pids = Self.allPids()
        var current: [pid_t: Sample] = [:]
        current.reserveCapacity(pids.count)
        var unreadable: Set<pid_t> = []

        let alive = Set(pids)
        knownUnreadable.formIntersection(alive)   // forget exited pids (pids get reused)
        for pid in pids where pid > 0 {
            if knownUnreadable.contains(pid) { unreadable.insert(pid); continue }
            var info = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard rc == 0 else { unreadable.insert(pid); knownUnreadable.insert(pid); continue }
            // ri_user_time / ri_system_time are in mach ticks on Apple Silicon (not ns).
            let cpuNs = (info.ri_user_time &+ info.ri_system_time) &* timebase.numer / timebase.denom
            current[pid] = Sample(cpuNs: cpuNs, energyNj: info.ri_energy_nj)
        }

        defer {
            previous = current
            previousTime = now
            names = names.filter { current[$0.key] != nil }   // drop exited processes
        }
        guard previousTime != 0 else { return ([], unreadable.count) }

        let wallNs = Double((now - previousTime) &* timebase.numer / timebase.denom)
        guard wallNs > 0 else { return ([], unreadable.count) }

        var ranked: [ProcessHeat] = []
        for (pid, now) in current {
            guard let before = previous[pid], now.cpuNs >= before.cpuNs else { continue }
            let cpu = Double(now.cpuNs - before.cpuNs) / wallNs * 100
            let joules = now.energyNj >= before.energyNj ? Double(now.energyNj - before.energyNj) / 1e9 : 0
            let watts = joules / (wallNs / 1e9)
            guard cpu > 0.05 || watts > 0.001 else { continue }
            ranked.append(ProcessHeat(pid: pid, name: name(of: pid), cpuPercent: cpu, watts: watts, isSystem: false))
        }
        if !unreadable.isEmpty {
            if Date().timeIntervalSince(psCacheTime) >= psInterval {
                psCache = Self.psSnapshot()
                psCacheTime = Date()
            }
            for entry in psCache where unreadable.contains(entry.pid) && entry.cpu > 0.05 {
                ranked.append(ProcessHeat(pid: entry.pid, name: entry.name, cpuPercent: entry.cpu, watts: nil, isSystem: true))
            }
        }
        // CPU % is the one measure every process has, so it is the ranking key; watts are shown
        // alongside where the kernel provides them.
        ranked.sort { $0.cpuPercent > $1.cpuPercent }
        return (Array(ranked.prefix(limit)), unreadable.count)
    }

    /// `/bin/ps -A -o pid=,%cpu=,comm=` → (pid, cpu, executable name).
    private static func psSnapshot() -> [(pid: pid_t, cpu: Double, name: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,%cpu=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), let cpu = Double(parts[1]) else { return nil }
            let path = String(parts[2])
            return (pid, cpu, path.split(separator: "/").last.map(String.init) ?? path)
        }
    }

    private func name(of pid: pid_t) -> String {
        if let cached = names[pid] { return cached }
        // proc_pidpath gives the full executable path, so "Google Chrome Helper (GPU)" isn't
        // truncated to proc_name's 32 characters.
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var result = "pid \(pid)"
        if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
            let path = Self.string(pathBuf)
            result = path.split(separator: "/").last.map(String.init) ?? path
        } else {
            var nameBuf = [CChar](repeating: 0, count: 256)
            if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 { result = Self.string(nameBuf) }
        }
        names[pid] = result
        return result
    }

    private static func string(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }
}
