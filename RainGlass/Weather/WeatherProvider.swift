import Foundation

struct WeatherCity: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let name: String
    let country: String
    let latitude: Double
    let longitude: Double

    var title: String { "\(name), \(country)" }
}

struct WeatherConditions: Codable, Equatable, Sendable {
    /// Rain and showers in millimeters per hour (Open-Meteo's current 15-minute sums multiplied by four).
    let precipitation: Double
    let windSpeed: Double
    let windDirection: Double
    let cloudCover: Double
    let weatherCode: Int
    let fetchedAt: Date

    var isThunderstorm: Bool { (95...99).contains(weatherCode) }

    func sceneParameters(base: RainParameters) -> RainParameters {
        var result = base
        let rain = max(0, precipitation)
        let level = min(1, rain / 5)
        result.intensity = rain < 0.05 ? 0 : min(1, 0.22 + level * 0.78)
        result.dropCount = rain < 0.05 ? 0 : min(6_000, 2_000 + level * 4_000)
        result.dropletSize = min(1.5, 0.75 + level * 0.75)
        result.gravity = min(1.7, 0.8 + level * 0.9)
        // Meteorological direction is where the wind comes from; positive screen X points east.
        result.wind = max(-1, min(1, -sin(windDirection * .pi / 180) * windSpeed / 40))
        result.blur = min(4, 1 + max(0, min(100, cloudCover)) / 100 * 2)
        result.lightningEnabled = isThunderstorm
        result.stormFrequency = isThunderstorm ? min(12, 3 + level * 9) : 0
        return result.clamped()
    }
}

protocol WeatherProvider: Sendable {
    func searchCities(_ query: String) async throws -> [WeatherCity]
    func currentConditions(for city: WeatherCity) async throws -> WeatherConditions
}

struct OpenMeteoWeatherProvider: WeatherProvider {
    private struct SearchResponse: Decodable {
        let results: [WeatherCity]?
    }
    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let rain: Double
            let showers: Double
            let windSpeed: Double
            let windDirection: Double
            let cloudCover: Double
            let weatherCode: Int

            enum CodingKeys: String, CodingKey {
                case rain, showers
                case windSpeed = "wind_speed_10m"
                case windDirection = "wind_direction_10m"
                case cloudCover = "cloud_cover"
                case weatherCode = "weather_code"
            }
        }
        let current: Current
    }

    func searchCities(_ query: String) async throws -> [WeatherCity] {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [URLQueryItem(name: "name", value: query), URLQueryItem(name: "count", value: "8")]
        let response: SearchResponse = try await request(parts.url!)
        return response.results ?? []
    }

    func currentConditions(for city: WeatherCity) async throws -> WeatherConditions {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(city.latitude)),
            URLQueryItem(name: "longitude", value: String(city.longitude)),
            URLQueryItem(name: "current", value: "rain,showers,wind_speed_10m,wind_direction_10m,cloud_cover,weather_code")
        ]
        let response: ForecastResponse = try await request(parts.url!)
        return WeatherConditions(precipitation: (response.current.rain + response.current.showers) * 4,
                                 windSpeed: response.current.windSpeed,
                                 windDirection: response.current.windDirection,
                                 cloudCover: response.current.cloudCover,
                                 weatherCode: response.current.weatherCode,
                                 fetchedAt: Date())
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
