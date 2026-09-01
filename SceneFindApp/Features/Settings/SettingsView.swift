import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: SceneFindModel
    @EnvironmentObject private var subscription: SubscriptionManager
    @State private var keyStatus: KeyStatus = .notConfigured

    private enum KeyStatus: Equatable {
        case notConfigured
        case keychain
        case debugLocalStorage
        case bundledDefault
        case failed(OSStatus)

        var label: String {
            switch self {
            case .notConfigured: "Not configured"
            case .keychain: "Stored in Keychain"
            case .debugLocalStorage: "Stored locally for Debug"
            case .bundledDefault: "Bundled prototype key"
            case .failed(let status): "Save failed (\(status))"
            }
        }

        var symbol: String {
            switch self {
            case .notConfigured: "key.slash"
            case .keychain: "checkmark.shield.fill"
            case .debugLocalStorage: "internaldrive.fill"
            case .bundledDefault: "key.fill"
            case .failed: "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .notConfigured: .secondary
            case .keychain, .debugLocalStorage, .bundledDefault: .green
            case .failed: .red
            }
        }
    }

    var body: some View {
        Form {
            #if DEBUG
            Section {
                EngineStatusHeader(
                    label: keyStatus.label,
                    symbol: keyStatus.symbol,
                    tint: keyStatus.color
                )
            }
            #endif

            Section("Plan") {
                NavigationLink {
                    PaywallView()
                } label: {
                    LabeledContent {
                        Text(subscription.accessLabel)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("SceneFind plans", systemImage: "sparkles")
                    }
                }
                LabeledContent("Allowance", value: subscription.allowanceLabel)
                if let entitlement = subscription.entitlement {
                    LabeledContent("Status", value: entitlement.status.label)
                    if let periodEnd = entitlement.periodEnd {
                        LabeledContent(
                            entitlement.plan == .lifetime ? "Monthly reset" : "Billing period ends",
                            value: periodEnd.formatted(date: .abbreviated, time: .omitted)
                        )
                    }
                }
                if case .offline = subscription.accessState {
                    Label(
                        "Connect to verify your allowance before starting an analysis.",
                        systemImage: "wifi.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button("Restore purchases") {
                    Task { await subscription.restorePurchases() }
                }
                .disabled(subscription.purchaseInProgress)
            }

            Section("Streaming") {
                NavigationLink {
                    MyServicesView()
                } label: {
                    LabeledContent {
                        Text(serviceCountLabel)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("My services", systemImage: "play.tv.fill")
                    }
                }
            }


            Section("Results") {
                Toggle("Show match evidence", isOn: $model.showAnalysisDetails)
            }

            Section("Privacy") {
                LabeledContent("Social accounts", value: "Not accessed")
                LabeledContent("Streaming accounts", value: "Not accessed")
                Text("Selected clip evidence is sent through SceneFind's secure service for identification and episode verification. Temporary media is discarded after analysis. Service access selections stay on this device.")
                    .font(.footnote)
            }

            Section("Legal & support") {
                configuredLink("Privacy Policy", systemImage: "hand.raised.fill", key: "SCENEFIND_PRIVACY_URL")
                configuredLink("Terms of Use", systemImage: "doc.text.fill", key: "SCENEFIND_TERMS_URL")
                configuredLink("Support", systemImage: "questionmark.circle.fill", key: "SCENEFIND_SUPPORT_URL")
            }

            Section("Data") {
                Button("Clear saved scenes", role: .destructive) { model.clearSaved() }
                Button("Clear all history", role: .destructive) { model.clearHistory() }
            }

            Section("About") {
                LabeledContent("Version", value: versionLabel)
            }
        }
        .navigationTitle("Settings")
        .scrollContentBackground(.hidden)
        .background(CinematicBackground())
        .tint(Color.sceneCyan)
        .task { await subscription.refresh() }
        .onAppear {
            #if DEBUG
            switch GeminiConfiguration.storageLocation {
            case .keychain: keyStatus = .keychain
            case .debugLocalStorage: keyStatus = .debugLocalStorage
            case .bundledDefault: keyStatus = .bundledDefault
            case .none: keyStatus = .notConfigured
            }
            #endif
        }
    }

    private var serviceCountLabel: String {
        let count = model.subscribedServiceCount
        return count == 0 ? "Not set" : "\(count) selected"
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    @ViewBuilder
    private func configuredLink(_ title: String, systemImage: String, key: String) -> some View {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           !value.contains("$("),
           let url = URL(string: value),
           url.scheme == "https" {
            Link(destination: url) {
                Label(title, systemImage: systemImage)
            }
        } else {
            LabeledContent {
                Text("Not configured")
                    .foregroundStyle(.secondary)
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }




}

struct MyServicesView: View {
    @EnvironmentObject private var model: SceneFindModel

    var body: some View {
        List {
            Section {
                ForEach(StreamingServiceCatalog.all) { service in
                    serviceRow(service)
                }
            } footer: {
                Text("Selections record your access; SceneFind does not sign in to or verify streaming accounts.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CinematicBackground())
        .navigationTitle("My Services")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func serviceRow(_ service: StreamingServiceDefinition) -> some View {
        HStack(spacing: 12) {
            Image(systemName: service.symbolName)
                .foregroundStyle(Color(serviceHex: service.brandColorHex))
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(Color(serviceHex: service.brandColorHex).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            Text(service.name)
                .font(.body.weight(.medium))

            Spacer()

            Picker("Access for \(service.name)", selection: Binding(
                get: { model.accessState(for: service) },
                set: { model.setAccessState($0, for: service) }
            )) {
                ForEach(StreamingAccessState.allCases) { state in
                    Label(state.label, systemImage: state.symbolName)
                        .tag(state)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(accessTint(model.accessState(for: service)))
        }
        .frame(minHeight: 44)
    }

    private func accessTint(_ state: StreamingAccessState) -> Color {
        switch state {
        case .subscribed: .green
        case .notSubscribed: .secondary
        case .unknown: .orange
        }
    }
}

private struct EngineStatusHeader: View {
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("Recognition engine")
                    .font(.headline)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(tint)
            }
            Spacer()
            SignalBars(accent: tint)
                .frame(width: 48, height: 18)
        }
        .padding(.vertical, 6)
    }
}

private extension Color {
    init(serviceHex: String) {
        let value = UInt64(serviceHex, radix: 16) ?? 0xFFFFFF
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
