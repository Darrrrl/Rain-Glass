import AVFAudio
import Foundation

@MainActor
final class AmbientAudioEngine: NSObject {
    private final class LayerState {
        let kind: AmbientLayer
        let nodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
        var files: [AVAudioFile] = []
        var active = 0
        var variant = -1
        var startedAt = 0.0
        var fadeStartedAt: Double?

        init(kind: AmbientLayer) { self.kind = kind }
    }

    var errorHandler: ((String?) -> Void)?
    private let engine = AVAudioEngine()
    private let bundle: Bundle
    private let layers = AmbientLayer.allCases.map(LayerState.init)
    private let thunderNodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private let tapNodes = (0..<4).map { _ in AVAudioPlayerNode() }
    private var tapBuffers: [AVAudioPCMBuffer] = []
    private var nextTapNode = 0
    private var tapRandomState = UInt64.random(in: UInt64.min...UInt64.max)
    private var nearThunder: AVAudioFile?
    private var farThunder: AVAudioFile?
    private var nextThunderNode = 0
    private var thunderGains: [Float] = [0, 0]
    private var timer: Timer?
    private var settings = AudioSettings()
    private var ready = false
    private var graphPrepared = false
    private let fadeSeconds = 5.0

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        super.init()
    }

    func start(settings: AudioSettings) throws {
        guard !ready else { return }
        self.settings = settings
        if !graphPrepared {
            let files = try layers.map { layer in
                try (["a", "b", "c"]).map { try load("\(layer.kind.rawValue)-\($0)") }
            }
            let near = try load("thunder-near")
            let far = try load("thunder-far")
            for (layer, variants) in zip(layers, files) {
                layer.files = variants
                for node in layer.nodes {
                    engine.attach(node)
                    engine.connect(node, to: engine.mainMixerNode, format: nil)
                }
            }
            nearThunder = near
            farThunder = far
            for node in thunderNodes {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: nil)
            }
            tapBuffers = (0..<6).map(Self.makeTapBuffer)
            for node in tapNodes {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: nil)
            }
            graphPrepared = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(configurationChanged(_:)),
                name: .AVAudioEngineConfigurationChange, object: engine
            )
        }
        try engine.start()
        ready = true
        let now = ProcessInfo.processInfo.systemUptime
        for layer in layers { begin(layer, on: 0, at: now) }
        timer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
    }

    func apply(_ settings: AudioSettings) {
        self.settings = settings
        if settings.muted || settings.glassTaps == 0 { tapNodes.forEach { $0.volume = 0 } }
    }

    func playGlassTap(id: UInt64, radius: Float, x: Float) {
        guard ready, engine.isRunning, !settings.muted, settings.glassTaps > 0,
              !tapBuffers.isEmpty else { return }
        let node = tapNodes[nextTapNode]
        nextTapNode = (nextTapNode + 1) % tapNodes.count
        node.stop()
        let soundRandom = nextTapRandom() ^ (id &* 0x9E3779B97F4A7C15)
        node.scheduleBuffer(tapBuffers[Int(soundRandom % UInt64(tapBuffers.count))], at: nil)
        node.pan = max(-0.45, min(0.45, (x * 2 - 1) * 0.45))
        let variation = Float(0.75 + Double((soundRandom >> 8) % 23) / 100)
        node.volume = Float(settings.master * settings.glassTaps) *
            min(1, max(0.55, radius / 8)) * variation
        node.play()
    }

    private func nextTapRandom() -> UInt64 {
        tapRandomState &+= 0x9E3779B97F4A7C15
        var value = tapRandomState
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    private static func makeTapBuffer(_ variant: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let duration = 0.065 + Double(variant) * 0.014
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        var noise = UInt32(0x9E37 &+ variant * 997)
        for frame in 0..<Int(frames) {
            let time = Double(frame) / format.sampleRate
            noise = noise &* 1_664_525 &+ 1_013_904_223
            let hiss = Double(noise >> 16) / 32_768 - 1
            let attack = 1 - exp(-time / 0.002)
            let decay = exp(-time * (36 + Double(variant) * 3))
            let tone = sin(2 * .pi * (850 + Double(variant) * 85) * time) * 0.7 +
                sin(2 * .pi * (1_500 + Double(variant) * 62) * time) * 0.25
            let sample = Float(0.13 * attack * decay * (tone + hiss * exp(-time * 100) * 0.25))
            buffer.floatChannelData![0][frame] = sample
            buffer.floatChannelData![1][frame] = sample
        }
        return buffer
    }

    func retry() {
        restartAfterConfigurationChange()
    }

    func playThunder(distance: Double, pan: Float) {
        guard ready, engine.isRunning else { return }
        guard let file = distance < 1_500 ? nearThunder : farThunder else { return }
        let node = thunderNodes[nextThunderNode]
        let index = nextThunderNode
        nextThunderNode = 1 - nextThunderNode
        node.stop()
        node.scheduleFile(file, at: nil)
        node.pan = max(-1, min(pan, 1))
        let distanceGain = Float(max(0.16, min(1, 600 / max(distance, 600))))
        thunderGains[index] = distanceGain
        node.volume = Float(settings.muted ? 0 : settings.master * settings.thunder) * distanceGain
        node.play()
    }

    private func load(_ name: String) throws -> AVAudioFile {
        guard let url = bundle.url(forResource: name, withExtension: "m4a", subdirectory: "Audio") else {
            throw AudioError.missingAsset(name)
        }
        return try AVAudioFile(forReading: url)
    }

    private func begin(_ layer: LayerState, on index: Int, at now: Double) {
        let choices = layer.files.indices.filter { $0 != layer.variant }
        guard let variant = choices.randomElement() else { return }
        layer.variant = variant
        layer.active = index
        layer.startedAt = now
        layer.fadeStartedAt = nil
        let node = layer.nodes[index]
        node.stop()
        node.scheduleFile(layer.files[variant], at: nil)
        node.volume = 0
        node.play()
    }

    @objc private func tick(_ timer: Timer) {
        guard ready else { return }
        if !engine.isRunning {
            restartAfterConfigurationChange()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        for layer in layers {
            let active = layer.nodes[layer.active]
            let target = Float(settings.muted ? 0 : settings.master * settings.volume(for: layer.kind))
            let file = layer.files[layer.variant]
            let duration = Double(file.length) / file.processingFormat.sampleRate
            if layer.fadeStartedAt == nil && now - layer.startedAt >= duration - fadeSeconds {
                let incoming = 1 - layer.active
                begin(layer, on: incoming, at: now)
                layer.fadeStartedAt = now
                layer.nodes[1 - incoming].volume = target
                layer.nodes[incoming].volume = 0
            }
            if let fadeStart = layer.fadeStartedAt {
                let fraction = min(1, max(0, (now - fadeStart) / fadeSeconds))
                layer.nodes[layer.active].volume = target * Float(fraction)
                layer.nodes[1 - layer.active].volume = target * Float(1 - fraction)
                if fraction >= 1 {
                    layer.nodes[1 - layer.active].stop()
                    layer.fadeStartedAt = nil
                }
            } else {
                active.volume += (target - active.volume) * 0.12
            }
        }
        for (index, node) in thunderNodes.enumerated() {
            let target = Float(settings.muted ? 0 : settings.master * settings.thunder) * thunderGains[index]
            node.volume += (target - node.volume) * 0.12
        }
    }

    @objc private func configurationChanged(_ notification: Notification) {
        restartAfterConfigurationChange()
    }

    private func restartAfterConfigurationChange() {
        guard ready else { return }
        for layer in layers { layer.nodes.forEach { $0.stop() } }
        thunderNodes.forEach { $0.stop() }
        tapNodes.forEach { $0.stop() }
        if engine.isRunning { engine.stop() }
        do {
            try engine.start()
            let now = ProcessInfo.processInfo.systemUptime
            for layer in layers { begin(layer, on: 0, at: now) }
            errorHandler?(nil)
        } catch {
            errorHandler?("Audio output is unavailable: \(error.localizedDescription)")
        }
    }

    private enum AudioError: LocalizedError {
        case missingAsset(String)
        var errorDescription: String? {
            switch self {
            case .missingAsset(let name): "Missing bundled audio: \(name).m4a"
            }
        }
    }
}
