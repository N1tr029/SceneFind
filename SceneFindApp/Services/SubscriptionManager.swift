import Foundation
import StoreKit

enum SubscriptionProductIDs {
    static let starter = "com.kavigandham.scenefind.starter.monthly"
    static let pro = "com.kavigandham.scenefind.pro.monthly"
    static let lifetime = "com.kavigandham.scenefind.lifetime"
    static let all = [starter, pro, lifetime]

    static func order(_ productID: String) -> Int {
        all.firstIndex(of: productID) ?? .max
    }
}

enum SubscriptionAccessState: Equatable {
    case loading
    case online(BackendEntitlementState)
    case offline(lastKnown: BackendEntitlementState?)

    var entitlement: BackendEntitlementState? {
        switch self {
        case .online(let entitlement), .offline(let entitlement?): entitlement
        case .loading, .offline(nil): nil
        }
    }

    var canAnalyze: Bool {
        if case .online(let entitlement) = self { return entitlement.canAnalyze }
        return false
    }

    var label: String {
        switch self {
        case .loading:
            "Checking allowance"
        case .online(let entitlement):
            "\(entitlement.plan.name) · \(entitlement.status.label)"
        case .offline:
            "Allowance unavailable offline"
        }
    }
}

@MainActor
final class SubscriptionManager: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var accessState: SubscriptionAccessState = .loading
    @Published private(set) var purchaseInProgress = false
    @Published var lastErrorMessage: String?

    private let client: SceneFindBackendClient
    private var updatesTask: Task<Void, Never>?

    init(client: SceneFindBackendClient = .shared) {
        self.client = client
        updatesTask = observeTransactions()
        Task { await refresh() }
    }

    deinit {
        updatesTask?.cancel()
    }

    var entitlement: BackendEntitlementState? { accessState.entitlement }
    var canStartAnalysis: Bool { accessState.canAnalyze }
    var accessLabel: String { accessState.label }

    var allowanceLabel: String {
        guard let entitlement else { return "Unavailable" }
        return "\(entitlement.remaining) of \(entitlement.allowance) remaining"
    }

    func refresh() async {
        async let loadedProducts = loadProducts()
        async let syncedEntitlement = syncTransactionsAndFetchEntitlement()
        products = await loadedProducts
        do {
            accessState = .online(try await syncedEntitlement)
            lastErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            accessState = .offline(lastKnown: accessState.entitlement)
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshEntitlement() async {
        do {
            accessState = .online(try await client.entitlement())
            lastErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            accessState = .offline(lastKnown: accessState.entitlement)
            lastErrorMessage = error.localizedDescription
        }
    }

    func purchase(_ product: Product) async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            let result = try await product.purchase(options: [
                .appAccountToken(client.installationUUID)
            ])
            switch result {
            case .success(let verification):
                let transaction = try verified(verification)
                let serverState = try await client.submit(
                    signedTransaction: verification.jwsRepresentation
                )
                accessState = .online(serverState)
                await transaction.finish()
                lastErrorMessage = nil
            case .pending:
                lastErrorMessage = "The purchase is awaiting approval."
            case .userCancelled:
                break
            @unknown default:
                lastErrorMessage = "The App Store returned an unknown purchase state."
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            accessState = .offline(lastKnown: accessState.entitlement)
        }
    }

    func restorePurchases() async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            try await AppStore.sync()
            accessState = .online(try await syncTransactionsAndFetchEntitlement())
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            accessState = .offline(lastKnown: accessState.entitlement)
        }
    }

    private func loadProducts() async -> [Product] {
        do {
            return try await Product.products(for: SubscriptionProductIDs.all)
                .sorted { SubscriptionProductIDs.order($0.id) < SubscriptionProductIDs.order($1.id) }
        } catch {
            return []
        }
    }

    private func syncTransactionsAndFetchEntitlement() async throws -> BackendEntitlementState {
        var latest: BackendEntitlementState?
        for await verification in Transaction.currentEntitlements {
            let transaction = try verified(verification)
            latest = try await client.submit(signedTransaction: verification.jwsRepresentation)
            await transaction.finish()
        }
        if let latest { return latest }
        return try await client.entitlement()
    }

    private func observeTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await verification in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try self.verified(verification)
                    let serverState = try await self.client.submit(
                        signedTransaction: verification.jwsRepresentation
                    )
                    self.accessState = .online(serverState)
                    self.lastErrorMessage = nil
                    await transaction.finish()
                } catch {
                    self.lastErrorMessage = error.localizedDescription
                    self.accessState = .offline(lastKnown: self.accessState.entitlement)
                }
            }
        }
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): value
        case .unverified: throw StoreKitError.notEntitled
        }
    }
}
