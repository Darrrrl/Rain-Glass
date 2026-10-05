import Foundation

private actor ControlledWeather: WeatherProvider {
    private var searches: [String: CheckedContinuation<[WeatherCity], Error>] = [:]
    private var readings: [Int: CheckedContinuation<WeatherConditions, Error>] = [:]
    func searchCities(_ query: String) async throws -> [WeatherCity] {
        try await withCheckedThrowingContinuation { searches[query] = $0 }
    }
    func currentConditions(for city: WeatherCity) async throws -> WeatherConditions {
        try await withCheckedThrowingContinuation { readings[city.id] = $0 }
    }
    func hasSearch(_ query: String) -> Bool { searches[query] != nil }
    func hasReading(_ id: Int) -> Bool { readings[id] != nil }
    func finishSearch(_ query: String, _ result: Result<[WeatherCity], Error>) {
        searches.removeValue(forKey: query)!.resume(with: result)
    }
    func finishReading(_ id: Int, _ result: Result<WeatherConditions, Error>) {
        readings.removeValue(forKey: id)!.resume(with: result)
    }
}

@main
@MainActor
struct WeatherRaceCheck {
    static func main() async {
        let suite = "dev.rainglass.weather-races.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ControlledWeather()
        let controller = WeatherController(provider: provider, defaults: defaults)
        let vienna = WeatherCity(id: 1, name: "Vienna", country: "Austria", latitude: 48, longitude: 16)
        let oslo = WeatherCity(id: 2, name: "Oslo", country: "Norway", latitude: 60, longitude: 11)
        let first = Task { await controller.search("Vienna") }
        while !(await provider.hasSearch("Vienna")) { await Task.yield() }
        let second = Task { await controller.search("Oslo") }
        while !(await provider.hasSearch("Oslo")) { await Task.yield() }
        await provider.finishSearch("Vienna", .failure(URLError(.notConnectedToInternet)))
        await first.value
        assert(controller.isSearching && controller.errorMessage == nil)
        await provider.finishSearch("Oslo", .success([oslo]))
        await second.value
        assert(controller.searchResults == [oslo] && !controller.isSearching)

        let cancelled = Task { await controller.search("Cancelled") }
        while !(await provider.hasSearch("Cancelled")) { await Task.yield() }
        cancelled.cancel()
        await provider.finishSearch("Cancelled", .success([vienna]))
        await cancelled.value
        assert(controller.searchResults == [oslo] && controller.errorMessage == nil)

        let obsolete = Task { await controller.search("Obsolete") }
        while !(await provider.hasSearch("Obsolete")) { await Task.yield() }
        controller.select(vienna)
        await provider.finishSearch("Obsolete", .success([oslo]))
        await obsolete.value
        assert(controller.searchResults.isEmpty)

        controller.setEnabled(true)
        while !(await provider.hasReading(1)) { await Task.yield() }
        controller.select(oslo)
        while !(await provider.hasReading(2)) { await Task.yield() }
        await provider.finishReading(1, .failure(URLError(.cancelled)))
        let date = Date(timeIntervalSince1970: 100_000)
        let conditions = WeatherConditions(precipitation: 1, windSpeed: 2, windDirection: 0,
                                          cloudCover: 50, weatherCode: 61, fetchedAt: date)
        await provider.finishReading(2, .success(conditions))
        while controller.conditions == nil { await Task.yield() }
        assert(controller.conditions == conditions && controller.errorMessage == nil)
        assert(!controller.isStale(at: date.addingTimeInterval(1800)))
        assert(controller.isStale(at: date.addingTimeInterval(1801)))
        let refresh = Task { await controller.refresh() }
        while !(await provider.hasReading(2)) { await Task.yield() }
        controller.setEnabled(false)
        await provider.finishReading(2, .failure(URLError(.notConnectedToInternet)))
        await refresh.value
        assert(controller.errorMessage == nil && controller.conditions == conditions)
        assert(controller.effectiveParameters(base: .rain) == .rain)
        print("Latest search, cancellation, city changes, disabled refresh, cache retention and stale time checked")
    }
}
