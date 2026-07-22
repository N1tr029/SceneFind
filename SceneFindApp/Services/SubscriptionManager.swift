import Foundation
import StoreKit

enum SubscriptionProductIDs {
    static let monthly = "com.example.SceneFind.premium.monthly"
    static let yearly = "com.example.SceneFind.premium.yearly"
    static let all = [monthly, yearly]
}

enum SubscriptionAccessState: Equatable {
    case loading
    case free
    case subscribed
    case gracePeriod
    case billingRetry
    case expired
    case revoked
    case offline(lastKnownPremium: Bool)

    var hasPremiumAccess: Bool {
        switch self {
        case .subscribed, .gracePeriod, .billingRetry: true
        case .offline(let lastKnownPremium): lastKnownPremium
        default: false
        }
    }

    var label: String {
        switch self {
        case .loading: "Checking access"
        case .free: "Free plan"
        case .subscribed: "Premium active"
        case .gracePeriod: "Premium grace period"
        case .billingRetry: "Premium billing retry"
        case .expired: "Premium expired"
        case .revoked: "Premium revoked"
        case .offline: "Entitlement unavailable offline"
        }
    }
}

@MainActor
final class SubscriptionManager: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var accessState: SubscriptionAccessState = .loading
    @Published private(set) var purchaseInProgress = false
    @Published var lastErrorMessage: String?

    private let defaults: UserDefaults
    private var updatesTask: Task<Void, Never>?
    private static let lastKnownPremiumKey = "subscription.lastKnownPremium.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        updatesTask = observeTransactions()
        Task { await refresh() }
    }

    deinit {
        updatesTask?.cancel()
    }

    var hasPremiumAccess: Bool { accessState.hasPremiumAccess }

    func refresh() async {
        do {
            products = try await Product.products(for: SubscriptionProductIDs.all)
                .sorted { $0.price < $1.price }
            accessState = try await currentAccessState()
            defaults.set(accessState.hasPremiumAccess, forKey: Self.lastKnownPremiumKey)
            lastErrorMessage = nil
        } catch {
            accessState = .offline(lastKnownPremium: defaults.bool(forKey: Self.lastKnownPremiumKey))
            lastErrorMessage = error.localizedDescription
        }
    }

    func purchase(_ product: Product) async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try verified(verification)
                await transaction.finish()
                await refresh()
            case .pending:
                lastErrorMessage = "The purchase is awaiting approval."
            case .userCancelled:
                break
            @unknown default:
                lastErrorMessage = "The App Store returned an unknown purchase state."
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            try await AppStore.sync()
            await refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func currentAccessState() async throws -> SubscriptionAccessState {
        var foundEntitlement = false
        for await entitlement in Transaction.currentEntitlements {
            let transaction = try verified(entitlement)
            guard SubscriptionProductIDs.all.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  transaction.expirationDate.map({ $0 > Date() }) ?? true else { continue }
            foundEntitlement = true
        }

        var bestState: SubscriptionAccessState = foundEntitlement ? .subscribed : .free
        for product in products where SubscriptionProductIDs.all.contains(product.id) {
            guard let statuses = try await product.subscription?.status else { continue }
            for status in statuses {
                switch status.state {
                case .subscribed: bestState = .subscribed
                case .inGracePeriod where bestState != .subscribed: bestState = .gracePeriod
                case .inBillingRetryPeriod where ![.subscribed, .gracePeriod].contains(bestState):
                    bestState = .billingRetry
                case .expired where bestState == .free: bestState = .expired
                case .revoked where bestState == .free: bestState = .revoked
                default: break
                }
            }
        }
        return bestState
    }

    private func observeTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self.refresh()
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
