import Combine
import Foundation
import OSLog

private struct WeatherCache: Codable {
    let cityID: Int
    let conditions: WeatherConditions
}

@MainActor
final class WeatherController: ObservableObject {
    private let log = Logger(subsystem: "dev.rainglass.app", category: "weather")
    @Published private(set) var enabled: Bool
    @Published private(set) var city: WeatherCity?
    @Published private(set) var conditions: WeatherConditions?
    @Published private(set) var searchResults: [WeatherCity] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSearching = false

    private let provider: any WeatherProvider
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var searchRequest = UUID()
    private var refreshRequest = UUID()

    init(provider: any WeatherProvider = OpenMeteoWeatherProvider(), defaults: UserDefaults = .standard) {
        self.provider = provider
        self.defaults = defaults
        enabled = defaults.bool(forKey: AppSettings.weatherEnabledKey)
        city = defaults.data(forKey: AppSettings.weatherCityKey).flatMap { try? JSONDecoder().decode(WeatherCity.self, from: $0) }
        if let city, let data = defaults.data(forKey: AppSettings.weatherCacheKey),
           let cache = try? JSONDecoder().decode(WeatherCache.self, from: data), cache.cityID == city.id {
            conditions = cache.conditions
        }
    }

    var isStale: Bool { conditions.map { Date().timeIntervalSince($0.fetchedAt) > 30 * 60 } ?? true }

    func effectiveParameters(base: RainParameters) -> RainParameters {
        guard enabled, let conditions else { return base }
        return conditions.sceneParameters(base: base)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: AppSettings.weatherEnabledKey)
        if value { start() } else {
            refreshRequest = UUID()
            clearSearch()
            refreshTask?.cancel()
            refreshTask = nil
            errorMessage = nil
        }
    }

    func start() {
        guard enabled, city != nil, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func search(_ raw: String) async {
        let request = UUID()
        searchRequest = request
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { clearSearch(); return }
        isSearching = true
        defer { if searchRequest == request { isSearching = false } }
        do {
            let results = try await provider.searchCities(query)
            guard searchRequest == request, !Task.isCancelled else { return }
            searchResults = results
            errorMessage = searchResults.isEmpty ? "No matching cities found." : nil
        } catch {
            guard searchRequest == request, !Task.isCancelled,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            log.error("Weather search failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "City search failed: \(error.localizedDescription)"
        }
    }

    func clearSearch() {
        searchRequest = UUID()
        searchResults = []
        isSearching = false
        errorMessage = nil
    }

    func select(_ selected: WeatherCity) {
        city = selected
        conditions = nil
        clearSearch()
        refreshRequest = UUID()
        defaults.set(try? JSONEncoder().encode(selected), forKey: AppSettings.weatherCityKey)
        defaults.removeObject(forKey: AppSettings.weatherCacheKey)
        refreshTask?.cancel()
        refreshTask = nil
        if enabled { start() }
    }

    func refresh() async {
        guard enabled, let city else { return }
        let request = UUID()
        refreshRequest = request
        do {
            let latest = try await provider.currentConditions(for: city)
            guard refreshRequest == request, self.city?.id == city.id, enabled,
                  !Task.isCancelled else { return }
            conditions = latest
            errorMessage = nil
            defaults.set(try? JSONEncoder().encode(WeatherCache(cityID: city.id, conditions: latest)),
                         forKey: AppSettings.weatherCacheKey)
        } catch {
            guard refreshRequest == request, self.city?.id == city.id, enabled,
                  !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            log.error("Weather refresh failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Weather update failed: \(error.localizedDescription)"
        }
    }
}
