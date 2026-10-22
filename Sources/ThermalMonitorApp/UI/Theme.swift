import SwiftUI
import AppKit
import ThermalCore

/// Colours and icons. The card is a cool slate in dark mode and a cool off-white in light mode.
enum Theme {
    static let panelBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.086, green: 0.106, blue: 0.122, alpha: 1)
            : NSColor(srgbRed: 0.953, green: 0.961, blue: 0.969, alpha: 1)
    })

    static let cpuTint = Color(red: 0.58, green: 0.44, blue: 0.92)   // violet
    static let gpuTint = Color(red: 0.20, green: 0.70, blue: 0.75)   // teal
    static let fanTint = Color(red: 0.35, green: 0.62, blue: 0.95)   // blue
    static let heatTint = Color(red: 0.96, green: 0.55, blue: 0.25)  // orange
}

extension HeatTone {
    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .cool: return .systemGreen
        case .warm: return .systemYellow
        case .hot: return .systemOrange
        case .critical: return .systemRed
        }
    }

    var label: String {
        switch self {
        case .cool: return "Cool"
        case .warm: return "Warm"
        case .hot: return "Hot"
        case .critical: return "Very hot"
        }
    }
}

extension ThermalPressure {
    var color: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }
}

extension SensorGroup {
    var symbol: String {
        switch self {
        case .cpuPerformance, .cpuEfficiency, .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up.fill"
        case .neuralEngine: return "brain"
        case .soc: return "memorychip"
        case .memory: return "memorychip.fill"
        case .storage: return "internaldrive.fill"
        case .battery: return "battery.75percent"
        case .skin: return "hand.raised.fill"
        case .nearChip: return "thermometer.high"
        case .ambient: return "wind"
        case .wireless: return "wifi"
        case .power: return "bolt.fill"
        case .other: return "thermometer.medium"
        }
    }

    var tint: Color {
        switch self {
        case .cpuPerformance, .cpuEfficiency, .cpu: return Theme.cpuTint
        case .gpu: return Theme.gpuTint
        case .battery: return .green
        case .storage, .memory: return .purple
        case .power: return .yellow
        default: return .gray
        }
    }

    /// Groups shown by default in the dropdown; the rest live under "All sensors".
    static let headline: [SensorGroup] = [.cpuPerformance, .cpuEfficiency, .gpu, .neuralEngine, .soc,
                                          .memory, .storage, .battery, .skin, .nearChip, .ambient]
}

enum Format {
    static func temp(_ c: Double?) -> String {
        guard let c else { return "—" }
        return "\(Int(c.rounded()))°"
    }

    static func cpu(_ p: Double) -> String {
        p >= 10 ? "\(Int(p.rounded()))%" : String(format: "%.1f%%", p)
    }

    /// Colour for a process' CPU share: green < 5 %, yellow < 20 %, orange < 50 %, red above.
    static func cpuTone(_ p: Double) -> HeatTone {
        switch p {
        case 50...: return .critical
        case 20..<50: return .hot
        case 5..<20: return .warm
        default: return .cool
        }
    }
}

/// Small rounded-square badge holding an SF Symbol in white on a tinted gradient.
struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.58, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// Thin capsule gauge, filled and coloured by temperature (25 °C empty → 100 °C full).
struct TempBar: View {
    let celsius: Double?
    let tone: HeatTone
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let fraction = celsius.map { min(max(($0 - 25) / 75, 0), 1) } ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tone.color.gradient).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: height)
    }
}
