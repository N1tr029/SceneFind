import PhotosUI
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @State private var selectedVideo: PhotosPickerItem?
    @State private var pastedURL = ""
    @State private var errorMessage: String?
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        ZStack {
            CinematicBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    identifyPanel
                    servicesSummary
                    recentSection
                }
                .padding()
            }
        }
        .navigationTitle("SceneFind")
        .task(id: selectedVideo) { await importSelectedVideo() }
        .alert("SceneFind", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var identifyPanel: some View {
        SceneCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Identify a clip", systemImage: "sparkle.magnifyingglass")
                    .font(.title2.bold())

                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("TikTok, YouTube, or web link", text: $pastedURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($isURLFieldFocused)
                        .submitLabel(.go)
                        .onSubmit(analyzePastedURL)
                    if !pastedURL.isEmpty {
                        Button {
                            pastedURL = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear link")
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

                Button(action: analyzePastedURL) {
                    Label("Find scene", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                PhotosPicker(selection: $selectedVideo, matching: .videos) {
                    Label("Choose from Photos", systemImage: "video.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var servicesSummary: some View {
        Button {
            router.navigate(to: .services)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.tv.fill")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("My services")
                        .font(.headline)
                    Text(serviceSummaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 64)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var serviceSummaryText: String {
        let count = model.subscribedServiceCount
        return count == 0 ? "Set the services you can watch" : "\(count) service\(count == 1 ? "" : "s") with access"
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent searches")
                .font(.title3.bold())
            if model.recentResults.isEmpty {
                ContentUnavailableView("No recent clips", systemImage: "clock", description: Text("Your latest matches will appear here."))
            } else {
                ForEach(model.recentResults) { result in
                    Button { router.navigate(to: .result(result.id)) } label: {
                        ResultRow(result: result)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func analyzePastedURL() {
        let trimmed = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            errorMessage = SceneFindError.invalidURL.localizedDescription
            return
        }
        let request = SharedClipRequest(sourceType: .url, sourcePlatform: SharedPlatform.detect(url: url), originalURL: url, pageTitle: "Shared link")
        saveAndNavigate(request)
    }

    private func importSelectedVideo() async {
        guard let selectedVideo else { return }
        do {
            guard let data = try await selectedVideo.loadTransferable(type: Data.self) else { throw SceneFindError.sharedFileMissing }
            try model.store.prepare()
            let fileName = "imported-\(UUID().uuidString).mov"
            let destination = model.store.filesURL.appendingPathComponent(fileName)
            try data.write(to: destination, options: [.atomic])
            let thumbnail = try? model.store.generateThumbnail(for: destination)
            let request = SharedClipRequest(sourceType: .video, sourcePlatform: .photos, localFileName: fileName, pageTitle: selectedVideo.itemIdentifier, thumbnailFileName: thumbnail ?? nil)
            saveAndNavigate(request)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveAndNavigate(_ request: SharedClipRequest) {
        do {
            try model.store.saveRequest(request)
            _ = model.store.consumePendingRequestID()
            router.navigate(to: .analyze(request.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ResultRow: View {
    let result: ClipAnalysisResult

    var body: some View {
        SceneCard {
            HStack(spacing: 12) {
                ResultThumbnail(url: result.topCandidate.heroImageURL)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.topCandidate.mediaTitle)
                        .font(.headline)
                    Text("\(result.topCandidate.episodeLine) • \(Int(result.topCandidate.confidence * 100))% • \(result.analysisDetails.sourcePlatform.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

private struct ResultThumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: 64, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var fallback: some View {
        ZStack {
            Color(uiColor: .tertiarySystemBackground)
            Image(systemName: "film")
                .foregroundStyle(.secondary)
        }
    }
}
