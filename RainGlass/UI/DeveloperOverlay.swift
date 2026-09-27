import SwiftUI

struct DeveloperOverlay: View {
    let snapshot: RenderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FPS  \(snapshot.framesPerSecond, specifier: "%.0f")")
            Text("CPU frame  \(snapshot.cpuFrameMilliseconds, specifier: "%.2f") ms")
            Text("Drawable  \(snapshot.drawableWidth) × \(snapshot.drawableHeight) px")
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }
}
