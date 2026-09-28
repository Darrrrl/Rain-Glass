import AVFAudio
import Foundation

@main
struct AudioAssetsCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Pass the built RainGlass.app path")
        }
        let names = ["window", "distant", "wind", "room"].flatMap { layer in
            ["a", "b", "c"].map { "\(layer)-\($0)" }
        } + ["thunder-near", "thunder-far"]
        for name in names {
            guard let url = bundle.url(forResource: name, withExtension: "m4a", subdirectory: "Audio") else {
                fatalError("Missing \(name)")
            }
            let file = try AVAudioFile(forReading: url)
            assert(file.length > 0 && file.processingFormat.sampleRate > 0)
        }
        print("All \(names.count) bundled audio files decode")
    }
}
