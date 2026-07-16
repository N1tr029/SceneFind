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
            case .bundledDefault: "Using bundled prototype key"
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
        NavigationStack {
            Form {
                Section("Gemini Prototype") {
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()

                    TextField("Model", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Label(keyStatus.label, systemImage: keyStatus.symbol)
                            .foregroundStyle(keyStatus.color)
                        Spacer()
                        Button {
                            saveGeminiSettings()
                        } label: {
                            Label("Save", systemImage: "key.fill")
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if keyStatus == .keychain || keyStatus == .debugLocalStorage {
                        Button("Remove API key", role: .destructive) {
                            GeminiConfiguration.apiKey = nil
                            apiKey = ""
                            keyStatus = GeminiConfiguration.storageLocation == .bundledDefault ? .bundledDefault : .notConfigured
                        }
                    }

                    Text("The bundled prototype key is used by default. A replacement saved here takes priority and is stored in Keychain. New YouTube and TikTok links use Gemini audio and video understanding.")
                        .font(.footnote)
                }

                Section("Privacy") {
                    Toggle("Show analysis details", isOn: $model.showAnalysisDetails)
                    Text("Known links are matched locally. New links send their URL, shared caption, and public page metadata to Gemini. Public YouTube and TikTok clips are also provided as video input. SceneFind does not access your social account.")
                        .font(.footnote)
                }

                Section("Share Extension") {
                    Text("Open the iOS share sheet from TikTok, YouTube, Safari, or Photos. Choose SceneFind and tap Find in SceneFind. The app opens directly to analysis when iOS permits it.")
                        .font(.footnote)
                    Text("If SceneFind is hidden, use Edit Actions in the share sheet and enable it.")
                        .font(.footnote)
                }

                Section("Data") {
                    Button("Clear recent history") { model.recentResults = [] }
                    Button("Clear saved scenes", role: .destructive) { model.clearSaved() }
                }

                Section("About") {
                    LabeledContent("Engine", value: "Verified catalog + Gemini video")
                    LabeledContent("App Group", value: AppGroupConfiguration.identifier)
                    LabeledContent("Version", value: "1.0")
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
