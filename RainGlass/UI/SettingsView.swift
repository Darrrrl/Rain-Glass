import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.developerOverlayKey) private var developerOverlayEnabled = false

    var body: some View {
        Form {
            Toggle("Show developer overlay", isOn: $developerOverlayEnabled)
                .help("Shows render rate, CPU frame time, and drawable size. Enables continuous rendering while visible.")
        }
        .formStyle(.grouped)
        .frame(width: 430, height: 170)
    }
}
