import SwiftUI

@main
struct SceneFindApp: App {
    @StateObject private var router = AppRouter()
    @StateObject private var model = SceneFindModel()
    @StateObject private var subscription = SubscriptionManager()
    @StateObject private var coordinator: AnalysisCoordinator

    init() {
        let model = SceneFindModel()
        let subscription = SubscriptionManager()
        _model = StateObject(wrappedValue: model)
        _subscription = StateObject(wrappedValue: subscription)
        _coordinator = StateObject(wrappedValue: AnalysisCoordinator(
            model: model,
            subscription: subscription
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .environmentObject(model)
                .environmentObject(subscription)
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)
                .onOpenURL { router.handle(url: $0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var didRouteMarketingPreview = false

    var body: some View {
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.homePath) {
                HomeView()
                    .navigationDestination(for: AppRoute.self, destination: routeView)
            }
            .tabItem { Label("Home", systemImage: "sparkle.magnifyingglass") }
            .tag(AppTab.home)

            NavigationStack(path: $router.savedPath) {
                SavedView()
                    .navigationDestination(for: AppRoute.self, destination: routeView)
            }
            .tabItem { Label("Saved", systemImage: "bookmark.fill") }
            .tag(AppTab.saved)

            NavigationStack(path: $router.settingsPath) {
                SettingsView()
                    .navigationDestination(for: AppRoute.self, destination: routeView)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .tint(Color.sceneCyan)
        // No manual tab-bar background: on iOS 26 that override replaces the
        // system's floating Liquid Glass bar with a flat material slab.
        .sensoryFeedback(.selection, trigger: router.selectedTab)
        .onAppear {
            routeMarketingPreviewIfNeeded()
            routePendingShare()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                routePendingShare()
            }
        }
    }

    private func routePendingShare() {
        guard !MarketingPreview.isEnabled else { return }
        guard let requestID = model.store.consumePendingRequestID() else { return }
        router.navigate(to: .analyze(requestID))
    }

    private func routeMarketingPreviewIfNeeded() {
        guard MarketingPreview.isEnabled, !didRouteMarketingPreview else { return }
        didRouteMarketingPreview = true

        switch MarketingPreview.destination {
        case .home:
            router.returnHome()
        case .saved:
            router.selectedTab = .saved
            router.savedPath = []
        case .services:
            router.selectedTab = .settings
            router.settingsPath = [.services]
        case .result:
            guard let result = model.recentResults.first else { return }
            router.navigate(to: .result(result.id))
        }
    }

    @ViewBuilder
    private func routeView(_ route: AppRoute) -> some View {
        switch route {
        case .analyze(let requestID):
            AnalyzeView(requestID: requestID)
        case .result(let resultID), .savedDetail(let resultID):
            ResultView(resultID: resultID)
        case .alternatives(let resultID):
            AlternativesView(resultID: resultID)
        case .settings:
            SettingsView()
        case .services:
            MyServicesView()
        case .paywall:
            PaywallView()
        }
    }
}
