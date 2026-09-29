import Foundation

private struct FakeWeatherProvider: WeatherProvider {
    let conditions: WeatherConditions

    func searchCities(_ query: String) async throws -> [WeatherCity] {
        [WeatherCity(id: 1, name: "Vienna", country: "Austria", latitude: 48.2, longitude: 16.37)]
    }

    func currentConditions(for city: WeatherCity) async throws -> WeatherConditions { conditions }
}

private struct OfflineWeatherProvider: WeatherProvider {
    func searchCities(_ query: String) async throws -> [WeatherCity] { throw URLError(.notConnectedToInternet) }
    func currentConditions(for city: WeatherCity) async throws -> WeatherConditions {
        throw URLError(.notConnectedToInternet)
    }
}

@main
@MainActor
struct WeatherCheck {
    static func main() async {
        let base = RainParameters.rain
        let dry = WeatherConditions(precipitation: 0, windSpeed: 0, windDirection: 0,
                                    cloudCover: 0, weatherCode: 0, fetchedAt: Date())
        let drizzle = WeatherConditions(precipitation: 0.2, windSpeed: 10, windDirection: 90,
                                        cloudCover: 60, weatherCode: 61, fetchedAt: Date())
        let storm = WeatherConditions(precipitation: 6, windSpeed: 40, windDirection: 270,
                                      cloudCover: 100, weatherCode: 95, fetchedAt: Date())
        assert(dry.sceneParameters(base: base).dropCount == 0)
        assert(drizzle.sceneParameters(base: base).intensity > 0)
        assert(drizzle.sceneParameters(base: base).wind < 0)
        assert(storm.sceneParameters(base: base).wind > 0)
        assert(storm.sceneParameters(base: base).lightningEnabled)
        assert(storm.sceneParameters(base: base).dropCount > drizzle.sceneParameters(base: base).dropCount)

        let suite = "dev.rainglass.weather-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = WeatherController(provider: FakeWeatherProvider(conditions: drizzle), defaults: defaults)
        await controller.search("Vienna")
        assert(controller.searchResults.count == 1)
        controller.select(controller.searchResults[0])
        controller.setEnabled(true)
        await controller.refresh()
        assert(controller.effectiveParameters(base: base).wind < 0)
        let restored = WeatherController(provider: FakeWeatherProvider(conditions: drizzle), defaults: defaults)
        assert(restored.city?.name == "Vienna")
        assert(restored.conditions?.precipitation == 0.2)
        let offline = WeatherController(provider: OfflineWeatherProvider(), defaults: defaults)
        await offline.refresh()
        assert(offline.conditions?.precipitation == 0.2)
        assert(offline.errorMessage != nil)
        controller.setEnabled(false)
        assert(controller.effectiveParameters(base: base) == base)
        print("Weather mapping, city selection, offline cache, and manual mode valid")
    }
}
