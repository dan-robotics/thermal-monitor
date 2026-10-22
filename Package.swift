// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThermalMonitor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ThermalCore", targets: ["ThermalCore"]),
        .executable(name: "thermal-probe", targets: ["thermal-probe"]),
        .executable(name: "ThermalMonitor", targets: ["ThermalMonitor"]),
    ],
    targets: [
        .target(name: "CSensors", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "ThermalCore", dependencies: ["CSensors"]),
        .executableTarget(name: "thermal-probe", dependencies: ["ThermalCore"]),
        .executableTarget(name: "ThermalMonitor", dependencies: ["ThermalCore"], path: "Sources/ThermalMonitorApp"),
    ]
)
