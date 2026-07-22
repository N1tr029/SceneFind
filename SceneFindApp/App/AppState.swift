import Foundation
import SwiftUI

enum AppRoute: Hashable {
    case analyze(UUID)
    case result(UUID)
    case alternatives(UUID)
    case savedDetail(UUID)
    case settings
    case services
    case paywall
}

enum AppTab: Hashable {
    case home
    case saved
    case settings
}

enum StreamingAccessState: String, Codable, CaseIterable, Identifiable {
    case subscribed
    case notSubscribed
    case unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subscribed: "I have access"
        case .notSubscribed: "No access"
        case .unknown: "Not set"
        }
    }

    var shortLabel: String {
        switch self {
        case .subscribed: "Your service"
        case .notSubscribed: "No access"
        case .unknown: "Access not set"
        }
    }

    var symbolName: String {
        switch self {
        case .subscribed: "checkmark.circle.fill"
        case .notSubscribed: "minus.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct StreamingServiceDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let symbolName: String
    let brandColorHex: String
    let aliases: [String]
}

enum StreamingServiceCatalog {
    static let all: [StreamingServiceDefinition] = [
        service("hulu", "Hulu", "h.square.fill", "1CE783"),
        service("netflix", "Netflix", "n.square.fill", "E50914"),
        service("apple-tv", "Apple TV", "appletv.fill", "A8A8AD", aliases: ["apple tv+", "itunes"]),
        service("disney-plus", "Disney+", "d.square.fill", "2E7DFF", aliases: ["disney plus"]),
        service("prime-video", "Prime Video", "play.rectangle.fill", "00A8E1", aliases: ["amazon prime video", "amazon video"]),
        service("max", "Max", "m.square.fill", "7B61FF", aliases: ["hbo max"]),
        service("peacock", "Peacock", "p.square.fill", "F5C518"),
        service("paramount-plus", "Paramount+", "mountain.2.fill", "0064FF", aliases: ["paramount plus"]),
        service("youtube", "YouTube", "play.rectangle.fill", "FF0033", aliases: ["youtube tv", "youtube premium"]),
        service("tubi", "Tubi", "t.square.fill", "FAFF00"),
        service("pluto-tv", "Pluto TV", "p.square.fill", "6C5CE7"),
        service("roku-channel", "The Roku Channel", "r.square.fill", "6F1AB1", aliases: ["roku"]),
        service("fandango", "Fandango at Home", "ticket.fill", "F47B20", aliases: ["vudu", "fandango"]),
        service("starz", "STARZ", "s.square.fill", "F0F0F0"),
        service("mgm-plus", "MGM+", "m.square.fill", "D6B46A", aliases: ["mgm plus"]),
        service("amc-plus", "AMC+", "a.square.fill", "F6C744", aliases: ["amc plus"]),
        service("britbox", "BritBox", "b.square.fill", "00A6D6"),
        service("crunchyroll", "Crunchyroll", "c.square.fill", "F47521"),
        service("plex", "Plex", "play.square.fill", "E5A00D"),
        service("philo", "Philo", "p.square.fill", "5A3FFF"),
        service("sling", "Sling TV", "s.square.fill", "14ABE0", aliases: ["sling"])
    ]

    static func service(for provider: WatchProvider) -> StreamingServiceDefinition? {
        let values = [provider.name, provider.episodeURL.host ?? ""]
            .map(normalize)
            .filter { !$0.isEmpty }
        return all.first { service in
            let names = ([service.name, service.id] + service.aliases).map(normalize)
            return values.contains { value in names.contains { value.contains($0) || $0.contains(value) } }
        }
    }

    private static func service(
        _ id: String,
        _ name: String,
        _ symbolName: String,
        _ color: String,
        aliases: [String] = []
    ) -> StreamingServiceDefinition {
        StreamingServiceDefinition(id: id, name: name, symbolName: symbolName, brandColorHex: color, aliases: aliases)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var homePath: [AppRoute] = []
    @Published var savedPath: [AppRoute] = []
    @Published var settingsPath: [AppRoute] = []
    @Published var resultsByID: [UUID: ClipAnalysisResult] = [:]

    func navigate(to route: AppRoute) {
        switch route {
        case .savedDetail:
            selectedTab = .saved
            if savedPath.last != route { savedPath.append(route) }
        case .settings:
            selectedTab = .settings
            settingsPath = []
        case .services, .paywall:
            selectedTab = .settings
            if settingsPath.last != route { settingsPath.append(route) }
        default:
            selectedTab = .home
            if homePath.last != route { homePath.append(route) }
        }
    }

    func handle(url: URL) {
        guard url.scheme == "scenefind" else { return }
        if url.host() == "analyze",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "requestID" })?
            .value
            .flatMap(UUID.init(uuidString:)) {
            navigate(to: .analyze(id))
        } else if url.host() == "result",
                  let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "id" })?
            .value
            .flatMap(UUID.init(uuidString:)) {
            navigate(to: .result(id))
        } else if url.host() == "saved" {
            selectedTab = .saved
        } else if url.host() == "settings" {
            selectedTab = .settings
        }
    }

    func finishAnalysis(requestID: UUID, resultID: UUID) {
        homePath.removeAll { $0 == .analyze(requestID) }
        navigate(to: .result(resultID))
    }

    func returnHome() {
        selectedTab = .home
        homePath = []
    }
}

@MainActor
final class SceneFindModel: ObservableObject {
    @Published private(set) var allResults: [ClipAnalysisResult] = []
    @Published var recentResults: [ClipAnalysisResult] = []
    @Published var savedResults: [ClipAnalysisResult] = []
    @Published var showAnalysisDetails = true {
        didSet { defaults.set(showAnalysisDetails, forKey: Self.showAnalysisDetailsKey) }
    }
    @Published private(set) var streamingAccess: [String: StreamingAccessState] = [:]

    let repository: ResultRepository
    let store: SharedContainerStore
    let identificationService: ClipIdentificationService
    private let defaults: UserDefaults
    private var savedResultIDs: Set<UUID> = []

    private static let savedResultIDsKey = "savedResultIDs.v2"
    private static let streamingAccessKey = "streamingAccess.v1"
    private static let showAnalysisDetailsKey = "showAnalysisDetails.v1"

    init(
        repository: ResultRepository = LocalJSONResultRepository.shared,
        store: SharedContainerStore = .shared,
        identificationService: ClipIdentificationService? = nil,
        defaults: UserDefaults = UserDefaults(suiteName: AppGroupConfiguration.identifier) ?? .standard
    ) {
        self.repository = repository
        self.store = store
        self.identificationService = identificationService ?? ClipIdentificationServiceFactory.makeDefault()
        self.defaults = defaults
        if defaults.object(forKey: Self.showAnalysisDetailsKey) != nil {
            showAnalysisDetails = defaults.bool(forKey: Self.showAnalysisDetailsKey)
        }
        loadPreferences()
        reload()
    }

    func reload() {
        allResults = (try? repository.fetchAll()) ?? []
        recentResults = Array(allResults.prefix(8))
        savedResults = allResults.filter { savedResultIDs.contains($0.id) }
    }

    func record(_ result: ClipAnalysisResult) {
        try? repository.save(result)
        reload()
    }

    func save(_ result: ClipAnalysisResult) {
        try? repository.save(result)
        savedResultIDs.insert(result.id)
        persistSavedResultIDs()
        reload()
    }

    func removeSaved(id: UUID) {
        savedResultIDs.remove(id)
        persistSavedResultIDs()
        reload()
    }

    func clearSaved() {
        savedResultIDs.removeAll()
        persistSavedResultIDs()
        reload()
    }

    func clearHistory() {
        try? repository.clear()
        savedResultIDs.removeAll()
        persistSavedResultIDs()
        reload()
    }

    func result(id: UUID) -> ClipAnalysisResult? {
        allResults.first { $0.id == id }
    }

    func isSaved(_ result: ClipAnalysisResult) -> Bool {
        savedResultIDs.contains(result.id)
    }

    var subscribedServiceCount: Int {
        streamingAccess.values.filter { $0 == .subscribed }.count
    }

    func accessState(for service: StreamingServiceDefinition) -> StreamingAccessState {
        streamingAccess[service.id] ?? .unknown
    }

    func accessState(for provider: WatchProvider) -> StreamingAccessState {
        guard let service = StreamingServiceCatalog.service(for: provider) else { return .unknown }
        return accessState(for: service)
    }

    func setAccessState(_ state: StreamingAccessState, for service: StreamingServiceDefinition) {
        streamingAccess[service.id] = state
        defaults.set(streamingAccess.mapValues(\.rawValue), forKey: Self.streamingAccessKey)
    }

    private func loadPreferences() {
        if let values = defaults.stringArray(forKey: Self.savedResultIDsKey) {
            savedResultIDs = Set(values.compactMap(UUID.init(uuidString:)))
        } else {
            let existing = (try? repository.fetchAll()) ?? []
            savedResultIDs = Set(existing.map(\.id))
            persistSavedResultIDs()
        }

        let storedAccess = defaults.dictionary(forKey: Self.streamingAccessKey) as? [String: String] ?? [:]
        streamingAccess = storedAccess.compactMapValues(StreamingAccessState.init(rawValue:))
    }

    private func persistSavedResultIDs() {
        defaults.set(savedResultIDs.map(\.uuidString).sorted(), forKey: Self.savedResultIDsKey)
    }
}

extension AppRoute {
    var id: String { String(describing: self) }
}
