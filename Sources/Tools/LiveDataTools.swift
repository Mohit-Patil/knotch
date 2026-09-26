import Foundation
import Observation
import Security
import SwiftUI

enum LiveDataTool {
    case weather
    case stocks
}

struct WeatherCity: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let admin1: String?
    let timezone: String

    var label: String {
        [name, admin1, country].compactMap { value in
            guard let value, !value.isEmpty, value != name else { return nil }
            return value
        }.joined(separator: ", ")
    }
}

private struct CitySearchResponse: Decodable {
    let results: [WeatherCity]?
}

struct WeatherForecast: Codable {
    struct Current: Codable {
        let time: String
        let temperature_2m: Double
        let relative_humidity_2m: Int
        let apparent_temperature: Double
        let weather_code: Int
        let wind_speed_10m: Double
        let is_day: Int
    }

    struct Daily: Codable {
        let time: [String]
        let weather_code: [Int]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let precipitation_probability_max: [Int]

        var count: Int {
            min(7, time.count, weather_code.count, temperature_2m_max.count,
                temperature_2m_min.count, precipitation_probability_max.count)
        }
    }

    let current: Current
    let daily: Daily
}

private struct SavedWeather: Codable {
    let city: WeatherCity
    let forecast: WeatherForecast
    let fetchedAt: Date
}

struct StockQuote: Codable, Identifiable {
    var id: String { symbol }
    let symbol: String
    let price: Double
    let change: Double
    let changePercent: Double
    let tradingDay: String
    let fetchedAt: Date
}

private struct StockResponse: Decodable {
    let quote: [String: String]?
    let note: String?
    let information: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case quote = "Global Quote"
        case note = "Note"
        case information = "Information"
        case errorMessage = "Error Message"
    }
}

private struct SavedStocks: Codable {
    let symbols: [String]
    let quotes: [String: StockQuote]
}

private enum LiveDataError: LocalizedError {
    case invalidResponse
    case tooLarge
    case http(Int)
    case noCities
    case noQuote(String)
    case provider(String)
    case invalidSymbol
    case duplicateSymbol
    case watchlistFull
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The data provider returned an unexpected response."
        case .tooLarge: "The data provider returned more data than expected."
        case .http(let code): "The data provider is unavailable (HTTP \(code))."
        case .noCities: "No matching cities. Try a more specific name."
        case .noQuote(let symbol): "No quote was returned for \(symbol). Check its exchange suffix."
        case .provider(let message): message
        case .invalidSymbol: "Enter a ticker using letters, numbers, periods, or hyphens."
        case .duplicateSymbol: "That ticker is already in your watchlist."
        case .watchlistFull: "The watchlist is limited to five tickers to conserve API requests."
        case .keychain(let status): "Could not save the API key in Keychain (\(status))."
        }
    }
}

/// Uses documented Open-Meteo and Alpha Vantage endpoints. Cached successful data
/// stays visible with its retrieval time when a later request fails.
@MainActor @Observable
final class LiveDataToolsStore {
    private(set) var selectedCity: WeatherCity?
    private(set) var cityResults: [WeatherCity] = []
    private(set) var weather: WeatherForecast?
    private(set) var weatherFetchedAt: Date?
    private(set) var weatherError: String?
    private(set) var citySearchError: String?
    private(set) var isSearchingCities = false
    private(set) var isLoadingWeather = false

    private(set) var symbols: [String] = []
    private(set) var quotes: [String: StockQuote] = [:]
    private(set) var stockError: String?
    private(set) var isLoadingStocks = false
    private(set) var hasStockAPIKey = false

    private let defaults: UserDefaults
    private let session: URLSession
    private var searchTask: Task<Void, Never>?
    private var weatherTask: Task<Void, Never>?
    private var stockTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var weatherGeneration = 0
    private var stockGeneration = 0
    private var hasCheckedStockAPIKey = false
    private var isShutdown = false

    private static let cityKey = "LiveDataTools.selectedCity.v1"
    private static let weatherKey = "LiveDataTools.weather.v1"
    private static let stocksKey = "LiveDataTools.stocks.v1"
    private static let keychainService = "dev.personal.Knotch.AlphaVantage"
    private static let keychainAccount = "APIKey"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)

        if let data = defaults.data(forKey: Self.cityKey) {
            selectedCity = try? JSONDecoder().decode(WeatherCity.self, from: data)
        }
        if let data = defaults.data(forKey: Self.weatherKey),
           let saved = try? JSONDecoder().decode(SavedWeather.self, from: data),
           saved.city.id == selectedCity?.id {
            weather = saved.forecast
            weatherFetchedAt = saved.fetchedAt
        }
        if let data = defaults.data(forKey: Self.stocksKey),
           let saved = try? JSONDecoder().decode(SavedStocks.self, from: data) {
            symbols = Array(saved.symbols.prefix(5))
            quotes = saved.quotes.filter { symbols.contains($0.key) }
        }
    }

    /// The Keychain is consulted only after the user opens Stocks.
    func activateStocks() {
        guard !isShutdown else { return }
        if !hasCheckedStockAPIKey {
            hasStockAPIKey = Self.readAPIKey() != nil
            hasCheckedStockAPIKey = true
        }
        if hasStockAPIKey { refreshStocks() }
    }

    /// Call when the owning coordinator is torn down. Invalidation stops any
    /// pending responses from being delivered after the store is discarded.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        searchTask?.cancel()
        weatherTask?.cancel()
        stockTask?.cancel()
        searchGeneration += 1
        weatherGeneration += 1
        stockGeneration += 1
        isSearchingCities = false
        isLoadingWeather = false
        isLoadingStocks = false
        session.invalidateAndCancel()
    }

    func searchCities(_ input: String) {
        guard !isShutdown else { return }
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        cityResults = []
        citySearchError = nil
        guard (2...100).contains(query.count) else {
            isSearchingCities = false
            citySearchError = "Enter a city name of 2–100 characters."
            return
        }
        isSearchingCities = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                components.queryItems = [
                    URLQueryItem(name: "name", value: query),
                    URLQueryItem(name: "count", value: "8"),
                    URLQueryItem(name: "language", value: "en"),
                    URLQueryItem(name: "format", value: "json")
                ]
                let data = try await self.get(components.url!, maximumBytes: 128_000)
                let response = try JSONDecoder().decode(CitySearchResponse.self, from: data)
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.cityResults = response.results ?? []
                if self.cityResults.isEmpty { self.citySearchError = LiveDataError.noCities.localizedDescription }
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.searchGeneration else { return }
                self.citySearchError = error.localizedDescription
            }
            guard generation == self.searchGeneration else { return }
            self.isSearchingCities = false
        }
    }

    func selectCity(_ city: WeatherCity) {
        guard !isShutdown else { return }
        weatherTask?.cancel()
        weatherGeneration += 1
        selectedCity = city
        cityResults = []
        citySearchError = nil
        weatherError = nil
        weather = nil
        weatherFetchedAt = nil
        defaults.set(try? JSONEncoder().encode(city), forKey: Self.cityKey)
        defaults.removeObject(forKey: Self.weatherKey)
        refreshWeather()
    }

    func refreshWeather() {
        guard !isShutdown else { return }
        guard let city = selectedCity else { return }
        weatherTask?.cancel()
        weatherGeneration += 1
        let generation = weatherGeneration
        weatherError = nil
        isLoadingWeather = true
        weatherTask = Task { [weak self] in
            guard let self else { return }
            do {
                var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
                components.queryItems = [
                    URLQueryItem(name: "latitude", value: String(city.latitude)),
                    URLQueryItem(name: "longitude", value: String(city.longitude)),
                    URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,is_day"),
                    URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
                    URLQueryItem(name: "timezone", value: city.timezone),
                    URLQueryItem(name: "forecast_days", value: "7")
                ]
                let data = try await self.get(components.url!, maximumBytes: 128_000)
                let forecast = try JSONDecoder().decode(WeatherForecast.self, from: data)
                guard !Task.isCancelled, generation == self.weatherGeneration,
                      city.id == self.selectedCity?.id else { return }
                guard forecast.daily.count == 7 else { throw LiveDataError.invalidResponse }
                let fetchedAt = Date()
                self.weather = forecast
                self.weatherFetchedAt = fetchedAt
                self.defaults.set(try? JSONEncoder().encode(SavedWeather(city: city,
                                                                          forecast: forecast,
                                                                          fetchedAt: fetchedAt)),
                                  forKey: Self.weatherKey)
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.weatherGeneration else { return }
                self.weatherError = error.localizedDescription
            }
            guard generation == self.weatherGeneration else { return }
            self.isLoadingWeather = false
        }
    }

    func saveStockAPIKey(_ input: String) throws {
        guard !isShutdown else { return }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw LiveDataError.provider("Enter your Alpha Vantage API key.")
        }
        let data = Data(key.utf8)
        let query = Self.keychainQuery()
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw LiveDataError.keychain(updateStatus) }
        } else if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw LiveDataError.keychain(addStatus) }
        } else {
            throw LiveDataError.keychain(status)
        }
        hasStockAPIKey = true
        hasCheckedStockAPIKey = true
        stockError = nil
        refreshStocks()
    }

    func removeStockAPIKey() {
        guard !isShutdown else { return }
        stockTask?.cancel()
        stockGeneration += 1
        isLoadingStocks = false
        let status = SecItemDelete(Self.keychainQuery() as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            hasStockAPIKey = false
            hasCheckedStockAPIKey = true
            stockError = nil
        } else {
            stockError = LiveDataError.keychain(status).localizedDescription
        }
    }

    func addSymbol(_ input: String) throws {
        guard !isShutdown else { return }
        let symbol = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty, symbol.count <= 16,
              symbol.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }) else {
            throw LiveDataError.invalidSymbol
        }
        guard !symbols.contains(symbol) else { throw LiveDataError.duplicateSymbol }
        guard symbols.count < 5 else { throw LiveDataError.watchlistFull }
        symbols.append(symbol)
        saveStocks()
        if hasStockAPIKey { refreshStocks() }
    }

    func removeSymbol(_ symbol: String) {
        guard !isShutdown else { return }
        stockTask?.cancel()
        stockGeneration += 1
        isLoadingStocks = false
        symbols.removeAll { $0 == symbol }
        quotes.removeValue(forKey: symbol)
        stockError = nil
        saveStocks()
    }

    /// Automatic refresh only requests missing or 15-minute-old quotes. The
    /// user can explicitly refresh sooner, subject to their provider quota.
    func refreshStocks(force: Bool = false) {
        guard !isShutdown else { return }
        guard hasStockAPIKey, let key = Self.readAPIKey() else {
            stockError = "Add an Alpha Vantage API key to load stock quotes."
            return
        }
        let due = symbols.filter { symbol in
            force || quotes[symbol].map { Date().timeIntervalSince($0.fetchedAt) >= 900 } ?? true
        }
        guard !due.isEmpty else { return }
        stockTask?.cancel()
        stockGeneration += 1
        let generation = stockGeneration
        stockError = nil
        isLoadingStocks = true
        stockTask = Task { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for symbol in due {
                guard !Task.isCancelled, generation == self.stockGeneration else { return }
                do {
                    var components = URLComponents(string: "https://www.alphavantage.co/query")!
                    components.queryItems = [
                        URLQueryItem(name: "function", value: "GLOBAL_QUOTE"),
                        URLQueryItem(name: "symbol", value: symbol),
                        URLQueryItem(name: "apikey", value: key)
                    ]
                    let data = try await self.get(components.url!, maximumBytes: 64_000)
                    let response = try JSONDecoder().decode(StockResponse.self, from: data)
                    if let message = response.note ?? response.information ?? response.errorMessage {
                        throw LiveDataError.provider(String(message.prefix(300)))
                    }
                    guard let fields = response.quote,
                          let returnedSymbol = fields["01. symbol"],
                          returnedSymbol.uppercased() == symbol,
                          let price = Double(fields["05. price"] ?? ""), price.isFinite,
                          let change = Double(fields["09. change"] ?? ""), change.isFinite,
                          let percent = Double((fields["10. change percent"] ?? "").replacingOccurrences(of: "%", with: "")), percent.isFinite,
                          let tradingDay = fields["07. latest trading day"], !tradingDay.isEmpty else {
                        throw LiveDataError.noQuote(symbol)
                    }
                    guard !Task.isCancelled, generation == self.stockGeneration,
                          self.symbols.contains(symbol) else { return }
                    self.quotes[symbol] = StockQuote(symbol: symbol, price: price, change: change,
                                                     changePercent: percent, tradingDay: tradingDay,
                                                     fetchedAt: Date())
                    self.saveStocks()
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == self.stockGeneration else { return }
                    failures.append("\(symbol): \(error.localizedDescription)")
                    // Quota and entitlement messages apply to the whole batch.
                    if case LiveDataError.provider = error { break }
                }
            }
            guard generation == self.stockGeneration else { return }
            self.stockError = failures.isEmpty ? nil : failures.joined(separator: "  ")
            self.isLoadingStocks = false
        }
    }

    private func saveStocks() {
        defaults.set(try? JSONEncoder().encode(SavedStocks(symbols: symbols, quotes: quotes)),
                     forKey: Self.stocksKey)
    }

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private static func readAPIKey() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func get(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveDataError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw LiveDataError.http(http.statusCode) }
        if response.expectedContentLength > Int64(maximumBytes) { throw LiveDataError.tooLarge }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 16_384))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw LiveDataError.tooLarge }
            data.append(byte)
        }
        return data
    }
}

struct LiveDataToolsView: View {
    let tool: LiveDataTool
    @Bindable var store: LiveDataToolsStore

    @State private var cityQuery = ""
    @State private var symbolInput = ""
    @State private var apiKeyInput = ""
    @State private var inputError: String?

    private let panel = Color(red: 0.105, green: 0.111, blue: 0.124)
    private let accent = Color(red: 0.52, green: 0.69, blue: 0.91)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if tool == .weather { weatherContent } else { stocksContent }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panel)
        .preferredColorScheme(.dark)
        .task(id: tool == .weather ? "weather" : "stocks") {
            if tool == .weather, store.selectedCity != nil,
               store.weatherFetchedAt.map({ Date().timeIntervalSince($0) > 900 }) ?? true {
                store.refreshWeather()
            }
            if tool == .stocks { store.activateStocks() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tool == .weather ? "cloud.sun.fill" : "chart.line.uptrend.xyaxis")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 35, height: 35)
                .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(tool == .weather ? "Weather" : "Stocks")
                    .font(.system(size: 18, weight: .semibold))
                Text(tool == .weather ? "Current conditions and a seven-day forecast" : "Your watchlist · end-of-day prices")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.54))
            }
            Spacer(minLength: 0)
        }
    }

    private var weatherContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("Search city or postal code", text: $cityQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { store.searchCities(cityQuery) }
                    .accessibilityLabel("Search city")
                Button("Search") { store.searchCities(cityQuery) }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(store.isSearchingCities)
            }
            .padding(10)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))

            if store.isSearchingCities { ProgressView("Finding cities…").controlSize(.small) }
            if let error = store.citySearchError { errorText(error) }
            if !store.cityResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(store.cityResults) { city in
                        Button {
                            cityQuery = ""
                            store.selectCity(city)
                        } label: {
                            HStack {
                                Image(systemName: "mappin.circle")
                                    .foregroundStyle(accent)
                                Text(city.label).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .font(.system(size: 12))
                            .padding(10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            }

            if let city = store.selectedCity {
                HStack {
                    Text(city.label)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if store.isLoadingWeather { ProgressView().controlSize(.small) }
                    Button { store.refreshWeather() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .disabled(store.isLoadingWeather)
                        .accessibilityLabel("Refresh weather")
                }
                if let fetchedAt = store.weatherFetchedAt {
                    timestamp(fetchedAt, isStale: store.weatherError != nil)
                }
                if let error = store.weatherError { errorText(error) }
                if let weather = store.weather {
                    currentWeather(weather.current)
                    Text("Next seven days")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    ForEach(0..<weather.daily.count, id: \.self) { index in
                        dailyRow(weather.daily, at: index, timeZone: city.timezone)
                    }
                }
            } else {
                emptyState("Choose a city", "Search for a city to see its current weather and forecast.", symbol: "mappin.and.ellipse")
            }
            Link("Weather by Open-Meteo · locations by GeoNames",
                 destination: URL(string: "https://open-meteo.com/")!)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func currentWeather(_ current: WeatherForecast.Current) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: Self.weatherSymbol(current.weather_code, isDay: current.is_day != 0))
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 34))
                    .foregroundStyle(accent)
                    .frame(width: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(current.temperature_2m, specifier: "%.0f")°C")
                        .font(.system(size: 29, weight: .medium, design: .rounded))
                    Text(Self.weatherDescription(current.weather_code))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            }
            HStack(spacing: 14) {
                detail("Feels like", "\(current.apparent_temperature.formatted(.number.precision(.fractionLength(0))))°")
                detail("Humidity", "\(current.relative_humidity_2m)%")
                detail("Wind", "\(current.wind_speed_10m.formatted(.number.precision(.fractionLength(0)))) km/h")
            }
            Text("Conditions at \(current.time.replacingOccurrences(of: "T", with: " · ")) local time")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.43))
        }
        .padding(14)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
    }

    private func dailyRow(_ daily: WeatherForecast.Daily, at index: Int, timeZone: String) -> some View {
        HStack(spacing: 9) {
            Text(Self.dayLabel(daily.time[index], timeZone: timeZone))
                .frame(width: 65, alignment: .leading)
            Image(systemName: Self.weatherSymbol(daily.weather_code[index], isDay: true))
                .foregroundStyle(accent)
                .frame(width: 22)
            Text(Self.weatherDescription(daily.weather_code[index]))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.66))
            Spacer(minLength: 2)
            Text("\(daily.precipitation_probability_max[index])%")
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 31, alignment: .trailing)
            Text("\(daily.temperature_2m_max[index], specifier: "%.0f")° / \(daily.temperature_2m_min[index], specifier: "%.0f")°")
                .frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }

    private var stocksContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !store.hasStockAPIKey {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Connect Alpha Vantage")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Enter your own API key for end-of-day stock quotes. The key is saved in this Mac’s Keychain. The free tier generally allows 25 requests per day.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                    HStack {
                        SecureField("API key", text: $apiKeyInput)
                            .textFieldStyle(.plain)
                            .onSubmit(saveAPIKey)
                            .accessibilityLabel("Alpha Vantage API key")
                        Button("Save key", action: saveAPIKey)
                            .buttonStyle(.borderedProminent)
                            .tint(accent)
                    }
                    Link("Get an Alpha Vantage API key", destination: URL(string: "https://www.alphavantage.co/support/#api-key")!)
                        .font(.system(size: 11))
                }
                .padding(13)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            } else {
                HStack {
                    Label("Alpha Vantage connected", systemImage: "checkmark.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Button("Remove key") { store.removeStockAPIKey() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(accent)
                }
            }

            HStack(spacing: 8) {
                TextField("Ticker, e.g. AAPL", text: $symbolInput)
                    .textFieldStyle(.plain)
                    .onSubmit(addSymbol)
                    .accessibilityLabel("Stock ticker")
                Button("Add", action: addSymbol)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            }
            .padding(10)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))

            if let error = inputError { errorText(error) }
            if let error = store.stockError { errorText(error) }
            HStack {
                Text("Watchlist · \(store.symbols.count)/5")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if store.isLoadingStocks { ProgressView().controlSize(.small) }
                Button { store.refreshStocks(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .disabled(!store.hasStockAPIKey || store.symbols.isEmpty || store.isLoadingStocks)
                    .accessibilityLabel("Refresh stock quotes")
            }
            if store.symbols.isEmpty {
                emptyState("No stocks yet", "Add up to five ticker symbols to build your watchlist.", symbol: "chart.xyaxis.line")
            } else {
                ForEach(store.symbols, id: \.self) { symbol in
                    stockRow(symbol)
                }
            }
            Text("Quotes are end-of-day for standard Alpha Vantage access. Prices use each listing’s market currency. Refreshing uses one API request per ticker.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.47))
            Link("Data by Alpha Vantage", destination: URL(string: "https://www.alphavantage.co/")!)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func stockRow(_ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(symbol).font(.system(size: 14, weight: .semibold))
                if let quote = store.quotes[symbol] {
                    Text("Session \(quote.tradingDay) · fetched \(quote.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.48))
                    if store.stockError != nil {
                        Text("Last available quote")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(store.hasStockAPIKey ? "Awaiting quote" : "Connect a key to load")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }
            Spacer(minLength: 2)
            if let quote = store.quotes[symbol] {
                VStack(alignment: .trailing, spacing: 5) {
                    Text(quote.price.formatted(.number.precision(.fractionLength(2))))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("\(quote.change >= 0 ? "+" : "")\(quote.change.formatted(.number.precision(.fractionLength(2)))) (\(quote.changePercent >= 0 ? "+" : "")\(quote.changePercent.formatted(.number.precision(.fractionLength(2))))%)")
                        .font(.system(size: 10))
                        .foregroundStyle(quote.change >= 0 ? .green : .red)
                }
            }
            Button { store.removeSymbol(symbol) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityLabel("Remove \(symbol)")
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }

    private func saveAPIKey() {
        do {
            try store.saveStockAPIKey(apiKeyInput)
            apiKeyInput = ""
            inputError = nil
        } catch { inputError = error.localizedDescription }
    }

    private func addSymbol() {
        do {
            try store.addSymbol(symbolInput)
            symbolInput = ""
            inputError = nil
        } catch { inputError = error.localizedDescription }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).foregroundStyle(.white.opacity(0.47))
            Text(value).foregroundStyle(.white.opacity(0.87))
        }
        .font(.system(size: 10))
    }

    private func timestamp(_ date: Date, isStale: Bool) -> some View {
        Text("\(isStale ? "Last available forecast" : "Updated") · \(date.formatted(date: .abbreviated, time: .shortened))")
            .font(.system(size: 10))
            .foregroundStyle(isStale ? .orange : .white.opacity(0.47))
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyState(_ title: String, _ description: String, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(description))
            .frame(maxWidth: .infinity, minHeight: 120)
    }

    private static func dayLabel(_ value: String, timeZone: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: timeZone)
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.timeZone = parser.timeZone
        formatter.dateFormat = "EEE d"
        return formatter.string(from: date)
    }

    private static func weatherDescription(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1, 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67, 80...82: "Rain"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorm"
        default: "Conditions unavailable"
        }
    }

    private static func weatherSymbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57, 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}
