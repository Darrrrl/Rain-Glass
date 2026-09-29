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
        if value { start() } else { refreshTask?.cancel(); refreshTask = nil }
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
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { searchResults = []; return }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await provider.searchCities(query)
            errorMessage = searchResults.isEmpty ? "No matching cities found." : nil
        } catch {
            log.error("Weather search failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "City search failed: \(error.localizedDescription)"
        }
    }

    func select(_ selected: WeatherCity) {
        city = selected
        conditions = nil
        searchResults = []
        defaults.set(try? JSONEncoder().encode(selected), forKey: AppSettings.weatherCityKey)
        defaults.removeObject(forKey: AppSettings.weatherCacheKey)
        refreshTask?.cancel()
        refreshTask = nil
        if enabled { start() }
    }

    func refresh() async {
        guard enabled, let city else { return }
        do {
            let latest = try await provider.currentConditions(for: city)
            guard self.city?.id == city.id, enabled else { return }
            conditions = latest
            errorMessage = nil
            defaults.set(try? JSONEncoder().encode(WeatherCache(cityID: city.id, conditions: latest)),
                         forKey: AppSettings.weatherCacheKey)
        } catch {
            log.error("Weather refresh failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Weather update failed: \(error.localizedDescription)"
        }
    }
}
