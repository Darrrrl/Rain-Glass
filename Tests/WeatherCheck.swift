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

private actor ControlledWeatherProvider: WeatherProvider {
    private var searches: [String: CheckedContinuation<[WeatherCity], Error>] = [:]
    private var refreshes: [Int: CheckedContinuation<WeatherConditions, Error>] = [:]
    private var searchWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var refreshWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var refreshCount = 0

    func searchCities(_ query: String) async throws -> [WeatherCity] {
        try await withCheckedThrowingContinuation { continuation in
            searches[query] = continuation
            searchWaiters.removeValue(forKey: query)?.resume()
        }
    }
    func currentConditions(for city: WeatherCity) async throws -> WeatherConditions {
        refreshCount += 1
        let id = refreshCount
        return try await withCheckedThrowingContinuation { continuation in
            refreshes[id] = continuation
            refreshWaiters.removeValue(forKey: id)?.resume()
        }
    }
    func waitForSearch(_ query: String) async {
        if searches[query] != nil { return }
        await withCheckedContinuation { searchWaiters[query] = $0 }
    }
    func waitForRefresh(_ id: Int) async {
        if refreshes[id] != nil { return }
        await withCheckedContinuation { refreshWaiters[id] = $0 }
    }
    func finishSearch(_ query: String, _ result: Result<[WeatherCity], Error>) {
        searches.removeValue(forKey: query)!.resume(with: result)
    }
    func finishRefresh(_ id: Int, _ result: Result<WeatherConditions, Error>) {
        refreshes.removeValue(forKey: id)!.resume(with: result)
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
        defaults.set(true, forKey: AppSettings.weatherEnabledKey)
        let active = WeatherController(provider: FakeWeatherProvider(conditions: drizzle), defaults: defaults)
        await active.refresh()
        assert(active.effectiveParameters(base: base).wind < 0)
        let restored = WeatherController(provider: FakeWeatherProvider(conditions: drizzle), defaults: defaults)
        assert(restored.city?.name == "Vienna")
        assert(restored.conditions?.precipitation == 0.2)
        let offline = WeatherController(provider: OfflineWeatherProvider(), defaults: defaults)
        await offline.refresh()
        assert(offline.conditions?.precipitation == 0.2)
        assert(offline.errorMessage != nil)
        active.setEnabled(false)
        assert(active.effectiveParameters(base: base) == base)
        await checkOverlappingRequests(drizzle: drizzle, storm: storm)
        print("Weather mapping, cache, cancellation, and overlapping requests valid")
    }
    static func checkOverlappingRequests(drizzle: WeatherConditions, storm: WeatherConditions) async {
        let suite = "dev.rainglass.weather-races.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ControlledWeatherProvider()
        let controller = WeatherController(provider: provider, defaults: defaults)
        let vienna = WeatherCity(id: 1, name: "Vienna", country: "Austria", latitude: 48.2, longitude: 16.37)
        let graz = WeatherCity(id: 2, name: "Graz", country: "Austria", latitude: 47.1, longitude: 15.4)
        let older = Task { await controller.search("Vienna") }
        await provider.waitForSearch("Vienna")
        let newer = Task { await controller.search("Graz") }
        await provider.waitForSearch("Graz")
        await provider.finishSearch("Graz", .success([graz]))
        await newer.value
        await provider.finishSearch("Vienna", .success([vienna]))
        await older.value
        assert(controller.searchResults == [graz] && !controller.isSearching)

        let cleared = Task { await controller.search("Vienna") }
        await provider.waitForSearch("Vienna")
        await controller.search("")
        await provider.finishSearch("Vienna", .failure(URLError(.notConnectedToInternet)))
        await cleared.value
        assert(controller.searchResults.isEmpty && !controller.isSearching && controller.errorMessage == nil)

        controller.select(vienna)
        controller.setEnabled(true)
        await provider.waitForRefresh(1)
        let oldCity = Task { await controller.refresh() }
        await provider.waitForRefresh(2)
        controller.select(graz)
        await provider.waitForRefresh(3)
        let latest = Task { await controller.refresh() }
        await provider.waitForRefresh(4)
        await provider.finishRefresh(4, .success(storm))
        await latest.value
        // Complete both older successful and failed requests after the latest one.
        await provider.finishRefresh(3, .success(drizzle))
        await provider.finishRefresh(1, .failure(URLError(.cancelled)))
        await provider.finishRefresh(2, .failure(URLError(.notConnectedToInternet)))
        await oldCity.value
        assert(controller.city == graz && controller.conditions?.precipitation == storm.precipitation && controller.errorMessage == nil)
        let restored = WeatherController(provider: provider, defaults: defaults)
        assert(restored.city == graz && restored.conditions?.precipitation == storm.precipitation)

        let disabled = Task { await controller.refresh() }
        await provider.waitForRefresh(5)
        controller.setEnabled(false)
        await provider.finishRefresh(5, .failure(CancellationError()))
        await disabled.value
        assert(controller.errorMessage == nil && controller.conditions?.precipitation == storm.precipitation)
    }

}
