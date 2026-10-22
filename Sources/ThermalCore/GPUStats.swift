import Foundation
import IOKit

/// GPU busy % from the IOAccelerator driver's "PerformanceStatistics" dictionary.
enum GPUStats {
    static func utilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, value)
        }
        return best
    }
}
