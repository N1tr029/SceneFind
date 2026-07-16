import SwiftUI

@main
struct SceneFindApp: App {
    @StateObject private var router = AppRouter()
    @StateObject private var model = SceneFindModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onOpenURL { router.handle(url: $0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @Environment(\.scenePhase) private var scenePhase

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
        .onAppear { routePendingShare() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                routePendingShare()
            }
        }
    }

    private func routePendingShare() {
        guard let requestID = model.store.consumePendingRequestID() else { return }
        router.navigate(to: .analyze(requestID))
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
        }
    }
}
