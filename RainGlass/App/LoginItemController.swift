import Combine
import OSLog
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?
    private let log = Logger(subsystem: "dev.rainglass.app", category: "login")

    var statusDescription: String {
        switch status {
        case .notRegistered: "Off"
        case .enabled: "Enabled"
        case .requiresApproval: "Needs approval in System Settings"
        case .notFound: "Unavailable in this build"
        @unknown default: "Unknown"
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            errorMessage = nil
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Start at Login could not be changed: \(error.localizedDescription)"
        }
        refresh()
    }
}
