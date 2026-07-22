import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: SceneFindModel
    @EnvironmentObject private var subscription: SubscriptionManager
    @EnvironmentObject private var usage: DailyUsageLimiter
    @State private var apiKey = ""
    @State private var modelName = "gemini-3.5-flash"
    @State private var keyStatus: KeyStatus = .notConfigured
    @State private var isAPIKeyVisible = false
    @State private var groqAPIKey = ""
    @State private var groqKeyStatus: KeyStatus = .notConfigured
    @State private var isGroqAPIKeyVisible = false

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
            Section {
                EngineStatusHeader(
                    label: keyStatus.label,
                    symbol: keyStatus.symbol,
                    tint: keyStatus.color
                )
            }

            Section("Plan") {
                NavigationLink {
                    PaywallView()
                } label: {
                    LabeledContent {
                        Text(subscription.accessState.label)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("SceneFind Premium", systemImage: "sparkles")
                    }
                }
                if !subscription.hasPremiumAccess {
                    LabeledContent(
                        "Free uses remaining",
                        value: "\(usage.remainingFreeUses) of \(DailyUsageLimiter.freeSuccessLimit)"
                    )
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
                Text("Public clip data is sent to Gemini for identification. Transcripts and episode evidence may be sent to Groq for verification. Service access selections stay on this device.")
                    .font(.footnote)
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
        .onAppear {
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
