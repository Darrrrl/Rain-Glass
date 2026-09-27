import Metal
import SwiftUI

struct ContentView: View {
    @AppStorage(AppSettings.developerOverlayKey) private var developerOverlayEnabled = false
    @StateObject private var diagnostics = RenderDiagnostics()
    private let device = MTLCreateSystemDefaultDevice()

    var body: some View {
        Group {
            if let device {
                ZStack(alignment: .topLeading) {
                    MetalView(device: device, diagnostics: diagnostics, continuousRendering: developerOverlayEnabled)
                        .ignoresSafeArea()

                    if developerOverlayEnabled {
                        DeveloperOverlay(snapshot: diagnostics.snapshot)
                            .padding(16)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Metal is unavailable",
                    systemImage: "display.trianglebadge.exclamationmark",
                    description: Text("RainGlass needs a Mac with Metal support.")
                )
            }
        }
    }
}
