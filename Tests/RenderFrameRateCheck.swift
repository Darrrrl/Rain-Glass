import AppKit
import MetalKit

@main
@MainActor
struct RenderFrameRateCheck {
    static func main() {
        for (quality, at60, at120) in [(RenderQuality.eco, 30, 30), (.balanced, 60, 60), (.ultra, 60, 120)] {
            assert(quality.framesPerSecond(displayMaximum: 60) == at60)
            assert(quality.framesPerSecond(displayMaximum: 120) == at120)
            assert(quality.framesPerSecond(displayMaximum: nil) == quality.targetFPS)
            assert(quality.framesPerSecond(displayMaximum: 0) == quality.targetFPS)
        }
        _ = NSApplication.shared
        let device = MTLCreateSystemDefaultDevice()!
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let renderer = MetalRenderer(device: device, diagnostics: RenderDiagnostics(),
                                     flashState: nil, libraryBundle: bundle)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = RainMetalView(frame: window.contentView!.bounds, device: device)
        view.isPaused = true
        window.contentView = view
        renderer.observeWindow(of: view)
        for quality in RenderQuality.allCases {
            renderer.setQuality(quality, in: view)
            let expected = quality.framesPerSecond(displayMaximum: window.screen?.maximumFramesPerSecond)
            assert(view.preferredFramesPerSecond == expected)
            for name in [NSWindow.didChangeScreenNotification,
                         NSApplication.didChangeScreenParametersNotification] {
                view.preferredFramesPerSecond = 1
                NotificationCenter.default.post(name: name, object: name == NSWindow.didChangeScreenNotification ? window : nil)
                assert(view.preferredFramesPerSecond == expected)
            }
        }
        // Reattaching the same renderer must observe the new window.
        let other = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.contentView = view
        renderer.observeWindow(of: view)
        view.preferredFramesPerSecond = 1
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        assert(view.preferredFramesPerSecond == 1)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: other)
        assert(view.preferredFramesPerSecond == RenderQuality.ultra.framesPerSecond(displayMaximum: other.screen?.maximumFramesPerSecond))
        view.isPaused = true
        other.close()
        window.close()
        print("Frame rate updates on display notifications and window reattachment")
    }
}
