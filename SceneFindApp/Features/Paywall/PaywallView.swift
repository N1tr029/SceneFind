import StoreKit
import SwiftUI

struct PaywallView: View {
    @EnvironmentObject private var subscription: SubscriptionManager
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Choose your allowance")
                        .font(.largeTitle.weight(.bold))
                    Text("Every plan uses the same evidence-first identification and episode verification.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                currentAllowance

                if subscription.products.isEmpty {
                    ContentUnavailableView(
                        "Plans unavailable",
                        systemImage: "wifi.slash",
                        description: Text("Connect to the App Store and try again.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    SceneGlassContainer(spacing: 12) {
                        VStack(spacing: 12) {
                            ForEach(subscription.products, id: \.id) { product in
                                productButton(product)
                            }
                        }
                    }
                }

                SceneGlassContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        secondaryButton("Restore Purchases") {
                            Task { await subscription.restorePurchases() }
                        }
                        secondaryButton("Manage Subscriptions") {
                            if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                                openURL(url)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
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
                }
                .padding(.horizontal, 4)

                if let error = subscription.lastErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.sceneCoral)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(CinematicBackground())
        .navigationTitle("Plans")
        .navigationBarTitleDisplayMode(.inline)
        .task { await subscription.refresh() }
    }

    private var currentAllowance: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "sparkles", tint: .sceneCyan)
            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.accessLabel)
                    .font(.headline)
                Text(subscription.allowanceLabel)
                    .font(.subheadline)
                    .foregroundStyle(Color.sceneGreen)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.sceneSurface, in: SceneShape.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current allowance: \(subscription.accessLabel), \(subscription.allowanceLabel)")
    }

    private func productButton(_ product: Product) -> some View {
        Button {
            Task { await subscription.purchase(product) }
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(planDetails(product.id))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(product.id == SubscriptionProductIDs.lifetime ? "one time" : "per month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .sceneGlassInteractive(in: SceneShape.card)
        .disabled(subscription.purchaseInProgress)
        .accessibilityHint("Purchases \(product.displayName) through the App Store")
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.sceneCyan)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .sceneGlassInteractive(in: Capsule())
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
