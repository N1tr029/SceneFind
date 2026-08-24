import StoreKit
import SwiftUI

struct PaywallView: View {
    @EnvironmentObject private var subscription: SubscriptionManager
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "sparkles.tv.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color.sceneCyan)
                    Text("Choose your allowance")
                        .font(.largeTitle.bold())
                    Text("Every plan uses the same evidence-first identification and episode verification.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                currentAllowance

                ForEach(subscription.products, id: \.id) { product in
                    productButton(product)
                }

                if subscription.products.isEmpty {
                    ContentUnavailableView(
                        "Plans unavailable",
                        systemImage: "wifi.slash",
                        description: Text("Connect to the App Store and try again.")
                    )
                }

                HStack {
                    Button("Restore Purchases") {
                        Task { await subscription.restorePurchases() }
                    }
                    .buttonStyle(.bordered)

                    Button("Manage Subscriptions") {
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            openURL(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Free trial", systemImage: "gift.fill")
                        .font(.headline)
                    Text("Includes 2 successful identifications total. Failed, cancelled, duplicate, and server-error analyses do not use an identification.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Starter and Pro renew monthly unless cancelled at least 24 hours before the end of the current billing period. Payment is charged to your Apple Account. Lifetime is a one-time purchase and provides 10 successful identifications per calendar month. Allowances never roll over.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    legalLink("Terms of Use", key: "SCENEFIND_TERMS_URL")
                    legalLink("Privacy Policy", key: "SCENEFIND_PRIVACY_URL")
                }
                .font(.footnote)

                if let error = subscription.lastErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.sceneCoral)
                }
            }
            .padding()
        }
        .background(CinematicBackground())
        .navigationTitle("Plans")
        .navigationBarTitleDisplayMode(.inline)
        .task { await subscription.refresh() }
    }

    private var currentAllowance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current allowance")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(subscription.accessLabel)
                .font(.headline)
            Text(subscription.allowanceLabel)
                .font(.subheadline)
                .foregroundStyle(Color.sceneGreen)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.sceneSurfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func productButton(_ product: Product) -> some View {
        Button {
            Task { await subscription.purchase(product) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(product.displayName)
                        .font(.headline)
                    Text(planDetails(product.id))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(product.displayPrice)
                        .font(.headline)
                    Text(product.id == SubscriptionProductIDs.lifetime ? "one time" : "per month")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color.sceneSurface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(subscription.purchaseInProgress)
        .accessibilityHint("Purchases \(product.displayName) through the App Store")
    }

    private func planDetails(_ productID: String) -> String {
        switch productID {
        case SubscriptionProductIDs.starter:
            "10 successful identifications each billing period"
        case SubscriptionProductIDs.pro:
            "50 successful identifications each billing period"
        case SubscriptionProductIDs.lifetime:
            "10 successful identifications each calendar month"
        default:
            "Successful identifications according to the displayed allowance"
        }
    }

    @ViewBuilder
    private func legalLink(_ title: String, key: String) -> some View {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           !value.contains("$("),
           let url = URL(string: value),
           url.scheme == "https" {
            Link(title, destination: url)
        } else {
            Text("\(title) unavailable")
                .foregroundStyle(.secondary)
        }
    }
}
