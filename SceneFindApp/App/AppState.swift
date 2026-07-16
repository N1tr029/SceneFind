import Foundation
import SwiftUI

enum AppRoute: Hashable {
    case analyze(UUID)
    case result(UUID)
    case alternatives(UUID)
    case savedDetail(UUID)
    case settings
}

enum AppTab: Hashable {
    case home
    case saved
    case settings
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var path: [AppRoute] = []
    @Published var resultsByID: [UUID: ClipAnalysisResult] = [:]

    func navigate(to route: AppRoute) {
        selectedTab = route == .settings ? .settings : .home
        if path.last != route {
            path.append(route)
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
}

@MainActor
final class SceneFindModel: ObservableObject {
    @Published var recentResults: [ClipAnalysisResult] = []
    @Published var savedResults: [ClipAnalysisResult] = []
    @Published var localOnlyMode = true
    @Published var showAnalysisDetails = true

    let repository: ResultRepository
    let store: SharedContainerStore
    let identificationService: ClipIdentificationService

    init(
        repository: ResultRepository = LocalJSONResultRepository.shared,
        store: SharedContainerStore = .shared,
        identificationService: ClipIdentificationService = HybridClipIdentificationService()
    ) {
        self.repository = repository
        self.store = store
        self.identificationService = identificationService
        reload()
    }

    func reload() {
        savedResults = (try? repository.fetchAll()) ?? []
        recentResults = Array(savedResults.prefix(5))
    }

    func save(_ result: ClipAnalysisResult) {
        try? repository.save(result)
        reload()
    }

    func deleteSaved(id: UUID) {
        try? repository.delete(id: id)
        reload()
    }

    func clearSaved() {
        try? repository.clear()
        reload()
    }
}

extension AppRoute {
    var id: String { String(describing: self) }
}
