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

                if planRows.isEmpty {
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
                            ForEach(planRows) { row in
                                planButton(row)
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

                    Text("Plans renew automatically unless cancelled at least 24 hours before the end of the current billing period. Payment is charged to your Apple Account. Yearly plans are billed once a year and release their allowance each calendar month. Allowances never roll over.")
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
                Text(allowanceTitle)
                    .font(.headline)
                Text(allowanceDetail)
                    .font(.subheadline)
                    .foregroundStyle(Color.sceneGreen)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.sceneSurface, in: SceneShape.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current allowance: \(allowanceTitle), \(allowanceDetail)")
    }

    // The screenshot preview has no backend, so it would otherwise show the
    // offline state on a screen meant to show the plans.
    private var allowanceTitle: String {
        #if DEBUG
        if MarketingPreview.isEnabled { return "Free trial · Active" }
        #endif
        return subscription.accessLabel
    }

    private var allowanceDetail: String {
        #if DEBUG
        if MarketingPreview.isEnabled { return "2 of 2 remaining" }
        #endif
        return subscription.allowanceLabel
    }

    /// One row per plan. Rows come from StoreKit, except in the screenshot
    /// preview, where StoreKit has nothing to return.
    private var planRows: [PlanRow] {
        #if DEBUG
        if MarketingPreview.isEnabled { return PlanRow.previewRows }
        #endif
        return subscription.products.map { product in
            PlanRow(
                id: product.id,
                name: product.displayName,
                price: product.displayPrice,
                cadence: SubscriptionProductIDs.yearly.contains(product.id) ? "per year" : "per month",
                details: planDetails(product.id),
                product: product
            )
        }
    }

    private func planButton(_ row: PlanRow) -> some View {
        Button {
            guard let product = row.product else { return }
            Task { await subscription.purchase(product) }
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(row.details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.price)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(row.cadence)
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
        .accessibilityHint("Purchases \(row.name) through the App Store")
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
            "10 successful identifications a month"
        case SubscriptionProductIDs.pro:
            "50 successful identifications a month"
        case SubscriptionProductIDs.starterYearly:
            "10 a month, billed once a year. Two months free."
        case SubscriptionProductIDs.proYearly:
            "50 a month, billed once a year. Two months free."
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

/// A plan as the paywall draws it.
private struct PlanRow: Identifiable {
    let id: String
    let name: String
    let price: String
    let cadence: String
    let details: String
    var product: Product?
}

#if DEBUG
extension PlanRow {
    /// Mirrors the live App Store products for the review screenshot.
    static let previewRows: [PlanRow] = [
        PlanRow(id: SubscriptionProductIDs.pro, name: "SceneFind Pro", price: "$19.99",
                cadence: "per month", details: "50 successful identifications a month"),
        PlanRow(id: SubscriptionProductIDs.proYearly, name: "Pro Yearly", price: "$199.99",
                cadence: "per year", details: "50 a month, billed once a year. Two months free."),
        PlanRow(id: SubscriptionProductIDs.starter, name: "SceneFind Starter", price: "$4.99",
                cadence: "per month", details: "10 successful identifications a month"),
        PlanRow(id: SubscriptionProductIDs.starterYearly, name: "Starter Yearly", price: "$49.99",
                cadence: "per year", details: "10 a month, billed once a year. Two months free."),
    ]
}
#endif
