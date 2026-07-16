import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: SceneFindModel
    @State private var apiKey = ""
    @State private var modelName = "gemini-3.5-flash"
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
            case .bundledDefault: "Ready"
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

            Section("Recognition") {
                HStack {
                    Label(keyStatus.label, systemImage: keyStatus.symbol)
                        .foregroundStyle(keyStatus.color)
                    Spacer()
                    Text("Gemini")
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("API settings") {
                    VStack(alignment: .leading, spacing: 12) {
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()

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
                            Button("Use default API key", role: .destructive) {
                                GeminiConfiguration.apiKey = nil
                                apiKey = ""
                                keyStatus = GeminiConfiguration.storageLocation == .bundledDefault ? .bundledDefault : .notConfigured
                            }
                        }
                    }
                }
            }

            Section("Results") {
                Toggle("Show match evidence", isOn: $model.showAnalysisDetails)
            }

            Section("Privacy") {
                LabeledContent("Social accounts", value: "Not accessed")
                LabeledContent("Streaming accounts", value: "Not accessed")
                Text("Public clip data is sent to Gemini for identification. Service access selections stay on this device.")
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
                apiKey = ""
                keyStatus = .bundledDefault
            case .none:
                apiKey = ""
                keyStatus = .notConfigured
            }
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
        .navigationTitle("My Services")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func serviceRow(_ service: StreamingServiceDefinition) -> some View {
        HStack(spacing: 12) {
            Image(systemName: service.symbolName)
                .foregroundStyle(Color(serviceHex: service.brandColorHex))
                .font(.title3)
                .frame(width: 32, height: 32)

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
