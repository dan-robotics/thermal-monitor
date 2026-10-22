import Foundation
import Combine
import UserNotifications
import ThermalCore

/// Posts a notification when the hottest chip sensor reaches the user's limit — at most once
/// every 5 minutes. Only works from the bundled .app (UNUserNotificationCenter needs a bundle id).
@MainActor
final class AlertManager {
    static let cooldown: TimeInterval = 5 * 60

    private let store: ThermalStore
    private let settings: AppSettings
    private var lastAlert: Date = .distantPast
    private var cancellable: AnyCancellable?

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    init(store: ThermalStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        cancellable = store.$snapshot
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in MainActor.assumeIsolated { self?.check(snap) } }
    }

    func requestPermission() {
        guard canNotify else { return }
        // async form: a completion-handler closure written here would inherit main-actor
        // isolation and trap when UserNotifications calls it on its own queue.
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private func check(_ snap: ThermalSnapshot) {
        guard settings.alertsEnabled, canNotify,
              let hottest = snap.hottest, hottest.celsius >= settings.alertThreshold,
              Date().timeIntervalSince(lastAlert) >= Self.cooldown else { return }
        lastAlert = Date()

        let content = UNMutableNotificationContent()
        content.title = "Mac is running hot: \(Int(hottest.celsius.rounded())) °C"
        if let top = snap.topProcesses.first {
            content.body = "Top heater: \(top.name) at \(Format.cpu(top.cpuPercent)) CPU. Thermal pressure: \(snap.pressure.rawValue)."
        } else {
            content.body = "\(hottest.group.rawValue) sensor \(hottest.rawName). Thermal pressure: \(snap.pressure.rawValue)."
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "thermal-\(Int(lastAlert.timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
