import Foundation

enum RenderQuality: String, CaseIterable, Identifiable {
    case eco, balanced, ultra

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var targetFPS: Int {
        switch self {
        case .eco: 30
        case .balanced: 60
        case .ultra: 120
        }
    }
    var waterScale: Int {
        switch self {
        case .eco: 3
        case .balanced: 2
        case .ultra: 1
        }
    }
    var atmosphereScale: Int { self == .ultra ? 3 : 4 }
    var blurScale: Int { self == .ultra ? 1 : 2 }
}

struct AtmosphereSettings: Codable, Equatable {
    var condensation: Double = 0.45
    var haze: Double = 0
    var imperfections: Double = 0
    var fogSoftness: Double = 0.65
    var fogReturnTime: Double = 18

    private enum CodingKeys: String, CodingKey {
        case condensation, haze, imperfections, fogSoftness, fogReturnTime
    }

    init(condensation: Double = 0.45, haze: Double = 0, imperfections: Double = 0,
         fogSoftness: Double = 0.65, fogReturnTime: Double = 18) {
        self.condensation = condensation
        self.haze = haze
        self.imperfections = imperfections
        self.fogSoftness = fogSoftness
        self.fogReturnTime = fogReturnTime
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        condensation = try values.decode(Double.self, forKey: .condensation)
        haze = try values.decode(Double.self, forKey: .haze)
        imperfections = try values.decode(Double.self, forKey: .imperfections)
        fogSoftness = try values.decodeIfPresent(Double.self, forKey: .fogSoftness) ?? 0.65
        fogReturnTime = try values.decodeIfPresent(Double.self, forKey: .fogReturnTime) ?? 18
    }
}

enum WindowPaneLayout: String, CaseIterable, Codable, Identifiable {
    case off, two, four, six
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .two: "Two panes"
        case .four: "Four panes"
        case .six: "Six panes"
        }
    }
    var columns: Int {
        switch self {
        case .off: 0
        case .two, .four: 2
        case .six: 3
        }
    }
    var rows: Int { self == .four || self == .six ? 2 : 1 }
}

struct WindowFrameSettings: Codable, Equatable {
    var layout: WindowPaneLayout = .off
    var thickness: Double = 12
}

struct SnowSettings: Codable, Equatable {
    var amount: Double = 0
    var flakeSize: Double = 1
    var speed: Double = 1
    var wind: Double = 0

    func clamped() -> Self {
        Self(amount: winterClamp(amount, 0...1, fallback: 0),
             flakeSize: winterClamp(flakeSize, 0.5...2, fallback: 1),
             speed: winterClamp(speed, 0.2...2, fallback: 1),
             wind: winterClamp(wind, -1...1, fallback: 0))
    }
    var isValid: Bool { self == clamped() }
}

struct FrostSettings: Codable, Equatable {
    var coverage: Double = 0
    var detail: Double = 0.6

    func clamped() -> Self {
        Self(coverage: winterClamp(coverage, 0...1, fallback: 0),
             detail: winterClamp(detail, 0...1, fallback: 0.6))
    }
    var isValid: Bool { self == clamped() }
}

private func winterClamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}

extension RenderQuality {
    var snowLimit: Int {
        switch self { case .eco: 450; case .balanced: 900; case .ultra: 1_500 }
    }
    var frostScale: Int { self == .ultra ? 1 : (self == .balanced ? 2 : 3) }
    var winterScale: Int { self == .ultra ? 2 : (self == .balanced ? 3 : 4) }
}
