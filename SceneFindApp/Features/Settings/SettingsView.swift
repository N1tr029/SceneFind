import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: SceneFindModel
    @EnvironmentObject private var subscription: SubscriptionManager
    @State private var apiKey = ""
    @State private var modelName = GeminiConfiguration.defaultModel
    @State private var keyStatus: KeyStatus = .notConfigured
    @State private var isAPIKeyVisible = false
    @State private var groqAPIKey = ""
    @State private var groqKeyStatus: KeyStatus = .notConfigured
    @State private var isGroqAPIKeyVisible = false
    @State private var searchAPIKey = ""
    @State private var searchKeyStatus: KeyStatus = .notConfigured
    @State private var isSearchAPIKeyVisible = false

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

            #if DEBUG
            Section("Recognition") {
                DisclosureGroup("API settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Group {
                                if isAPIKeyVisible {
                                    TextField("Gemini API key", text: $apiKey)
                                } else {
                                    SecureField("Gemini API key", text: $apiKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()

                            Button {
                                isAPIKeyVisible.toggle()
                            } label: {
                                Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isAPIKeyVisible ? "Hide API key" : "Show API key")
                        }

                        Text(keyStatus == .bundledDefault
                             ? "This is the prototype default. Saving replaces it only on this iPhone."
                             : "This iPhone is using your saved replacement key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("Model", text: $modelName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            saveGeminiSettings()
                        } label: {
                            Label("Save API settings", systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if keyStatus == .keychain || keyStatus == .debugLocalStorage {
                            Button("Restore bundled default", role: .destructive) {
                                GeminiConfiguration.clearCustomAPIKey()
                                apiKey = GeminiConfiguration.apiKey ?? ""
                                keyStatus = GeminiConfiguration.storageLocation == .bundledDefault ? .bundledDefault : .notConfigured
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Label("Groq episode verification", systemImage: "checkmark.seal.fill")
                                .font(.subheadline.weight(.semibold))
                            Text("Uses Groq's free plan when available and falls back to Gemini automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Group {
                                if isGroqAPIKeyVisible {
                                    TextField("Groq API key", text: $groqAPIKey)
                                } else {
                                    SecureField("Groq API key", text: $groqAPIKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()

                            Button {
                                isGroqAPIKeyVisible.toggle()
                            } label: {
                                Image(systemName: isGroqAPIKeyVisible ? "eye.slash" : "eye")
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isGroqAPIKeyVisible ? "Hide Groq API key" : "Show Groq API key")
                        }

                        Label(groqKeyStatus.label, systemImage: groqKeyStatus.symbol)
                            .font(.caption)
                            .foregroundStyle(groqKeyStatus.color)

                        Button {
                            saveGroqSettings()
                        } label: {
                            Label("Save Groq key", systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if groqKeyStatus == .keychain || groqKeyStatus == .debugLocalStorage {
                            Button("Restore bundled Groq default", role: .destructive) {
                                GroqConfiguration.clearAPIKey()
                                loadGroqSettings()
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Label("Watch-link search", systemImage: "magnifyingglass.circle.fill")
                                .font(.subheadline.weight(.semibold))
                            Text("""
                                Streaming services hide episode pages behind ids that cannot be \
                                guessed, so SceneFind finds them by search and then confirms each \
                                page before offering it. Without a key it tries a keyless search \
                                that works only intermittently, then falls back to opening the \
                                service's own search page.
                                """)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Group {
                                if isSearchAPIKeyVisible {
                                    TextField("Brave Search API key", text: $searchAPIKey)
                                } else {
                                    SecureField("Brave Search API key", text: $searchAPIKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()

                            Button {
                                isSearchAPIKeyVisible.toggle()
                            } label: {
                                Image(systemName: isSearchAPIKeyVisible ? "eye.slash" : "eye")
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isSearchAPIKeyVisible ? "Hide search API key" : "Show search API key")
                        }

                        Label(searchKeyStatus.label, systemImage: searchKeyStatus.symbol)
                            .font(.caption)
                            .foregroundStyle(searchKeyStatus.color)

                        Button {
                            WebSearchConfiguration.saveAPIKey(searchAPIKey)
                            searchAPIKey = ""
                            loadSearchSettings()
                        } label: {
                            Label("Save search key", systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(searchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if searchKeyStatus == .keychain || searchKeyStatus == .debugLocalStorage {
                            Button("Remove search key", role: .destructive) {
                                WebSearchConfiguration.clearAPIKey()
                                loadSearchSettings()
                            }
                        }
                    }
                }
            }
            #endif

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
            loadSearchSettings()
            modelName = GeminiConfiguration.model
            switch GeminiConfiguration.storageLocation {
            case .keychain:
                apiKey = GeminiConfiguration.apiKey ?? ""
                keyStatus = .keychain
            case .debugLocalStorage:
                apiKey = GeminiConfiguration.apiKey ?? ""
                keyStatus = .debugLocalStorage
            case .bundledDefault:
                apiKey = GeminiConfiguration.apiKey ?? ""
                keyStatus = .bundledDefault
            case .none:
                apiKey = ""
                keyStatus = .notConfigured
            }
            loadGroqSettings()
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

    private func saveGeminiSettings() {
        let result = GeminiConfiguration.saveAPIKey(apiKey)
        GeminiConfiguration.model = modelName
        switch result {
        case .keychain: keyStatus = .keychain
        case .debugLocalStorage: keyStatus = .debugLocalStorage
        case .failed(let status): keyStatus = .failed(status)
        }
    }

    private func loadGroqSettings() {
        groqAPIKey = GroqConfiguration.apiKey ?? ""
        switch GroqConfiguration.storageLocation {
        case .keychain: groqKeyStatus = .keychain
        case .debugLocalStorage: groqKeyStatus = .debugLocalStorage
        case .bundledDefault: groqKeyStatus = .bundledDefault
        case .none: groqKeyStatus = .notConfigured
        }
    }

    private func loadSearchSettings() {
        // Never echo the stored key back into the field; the status line is
        // enough to show one is set.
        searchAPIKey = ""
        searchKeyStatus = WebSearchConfiguration.isConfigured ? .keychain : .notConfigured
    }

    private func saveGroqSettings() {
        let result = GroqConfiguration.saveAPIKey(groqAPIKey)
        switch result {
        case .keychain: groqKeyStatus = .keychain
        case .debugLocalStorage: groqKeyStatus = .debugLocalStorage
        case .failed(let status): groqKeyStatus = .failed(status)
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
