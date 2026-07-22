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
                    Text("SceneFind Premium")
                        .font(.largeTitle.bold())
                    Text("Unlimited clip identification with the same evidence-first episode verification.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                ForEach(subscription.products, id: \.id) { product in
                    Button {
                        Task { await subscription.purchase(product) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(product.displayName)
                                    .font(.headline)
                                Text(product.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(product.displayPrice)
                                .font(.headline)
                        }
                        .padding(16)
                        .background(Color.sceneSurface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(subscription.purchaseInProgress)
                }

                if subscription.products.isEmpty {
                    ContentUnavailableView(
                        "Plans unavailable",
                        systemImage: "wifi.slash",
                        description: Text("Connect to the App Store and try again.")
                    )
                }

                Button("Restore Purchases") {
                    Task { await subscription.restorePurchases() }
                }
                .buttonStyle(.bordered)

                Button("Manage Subscription") {
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                        openURL(url)
                    }
                }
                .buttonStyle(.bordered)

                Text("Free includes two successful identifications per day. Failed analyses do not use an identification. Local builds enforce this allowance on device; production enforcement requires the SceneFind backend.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let error = subscription.lastErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.sceneCoral)
                }
            }
            .padding()
        }
        .background(CinematicBackground())
        .navigationTitle("Premium")
        .navigationBarTitleDisplayMode(.inline)
        .task { await subscription.refresh() }
    }
}
