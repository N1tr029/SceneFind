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
                LazyVStack(alignment: .leading, spacing: 22) {
                    HomeHeader()
                    ClipInputPanel(
                        pastedURL: $pastedURL,
                        selectedVideo: $selectedVideo,
                        isURLFieldFocused: $isURLFieldFocused,
                        analyze: analyzePastedURL
                    )
                    ServiceAccessButton(
                        count: model.subscribedServiceCount,
                        action: openServices
                    )
                    if let result = model.recentResults.first {
                        LastMatchSection(result: result) {
                            router.navigate(to: .result(result.id))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: selectedVideo) { await importSelectedVideo() }
        .alert("SceneFind", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func openServices() {
        router.navigate(to: .services)
    }

    private func analyzePastedURL() {
        let trimmed = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            errorMessage = SceneFindError.invalidURL.localizedDescription
            return
        }
        isURLFieldFocused = false
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: SharedPlatform.detect(url: url),
            originalURL: url,
            pageTitle: "Shared link"
        )
        saveAndNavigate(request)
    }

    private func importSelectedVideo() async {
        guard let selectedVideo else { return }
        do {
            guard let data = try await selectedVideo.loadTransferable(type: Data.self) else {
                throw SceneFindError.sharedFileMissing
            }
            try model.store.prepare()
            let fileName = "imported-\(UUID().uuidString).mov"
            let destination = model.store.filesURL.appendingPathComponent(fileName)
            try data.write(to: destination, options: [.atomic])
            let thumbnail = try? model.store.generateThumbnail(for: destination)
            let request = SharedClipRequest(
                sourceType: .video,
                sourcePlatform: .photos,
                localFileName: fileName,
                pageTitle: selectedVideo.itemIdentifier,
                thumbnailFileName: thumbnail ?? nil
            )
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

private struct HomeHeader: View {
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SceneFind")
                    .font(.system(size: 34, weight: .bold))
                Text("CLIP TO SCENE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.sceneCyan)
            }
            Spacer()
            HStack(spacing: 8) {
                SignalBars()
                    .frame(width: 44, height: 18)
                Text("READY")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.sceneGreen)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.sceneGreen.opacity(0.10), in: Capsule())
        }
    }
}

private struct ClipInputPanel: View {
    @Binding var pastedURL: String
    @Binding var selectedVideo: PhotosPickerItem?
    @FocusState.Binding var isURLFieldFocused: Bool
    let analyze: () -> Void

    private var canAnalyze: Bool {
        !pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SceneCard {
            VStack(alignment: .leading, spacing: 16) {
                SignalScanner(
                    symbol: canAnalyze ? "link.badge.plus" : "viewfinder",
                    progress: canAnalyze ? 0.72 : 0.12,
                    accent: canAnalyze ? .sceneGreen : .sceneCyan
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Find the original moment")
                        .font(.title3.bold())
                    Text("Paste a clip link or import a video.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(canAnalyze ? Color.sceneGreen : .secondary)
                    TextField("TikTok, YouTube, or web link", text: $pastedURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($isURLFieldFocused)
                        .submitLabel(.go)
                        .onSubmit(analyze)
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
                    Button(action: analyze) {
                        Image(systemName: "arrow.right")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.sceneCyan)
                    .disabled(!canAnalyze)
                    .accessibilityLabel("Find scene")
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .frame(minHeight: 48)
                .background(Color.sceneSurfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(canAnalyze ? Color.sceneGreen.opacity(0.35) : .white.opacity(0.06), lineWidth: 1)
                }

                HStack {
                    PhotosPicker(selection: $selectedVideo, matching: .videos) {
                        Label("Import video", systemImage: "video.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Spacer()

                    HStack(spacing: 12) {
                        Image(systemName: "music.note")
                        Image(systemName: "play.rectangle.fill")
                        Image(systemName: "safari.fill")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: canAnalyze)
    }
}

private struct ServiceAccessButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "play.tv.fill")
                    .font(.title3)
                    .foregroundStyle(Color.sceneCoral)
                    .frame(width: 38, height: 38)
                    .background(Color.sceneCoral.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("My services")
                        .font(.headline)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.sceneSurface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        count == 0 ? "Choose where you watch" : "\(count) selected service\(count == 1 ? "" : "s")"
    }
}

private struct LastMatchSection: View {
    let result: ClipAnalysisResult
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last match")
                    .font(.headline)
                Spacer()
                Text(result.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: action) {
                HStack(spacing: 14) {
                    ShowCoverArtwork(candidate: result.topCandidate)
                        .frame(width: 78, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.topCandidate.mediaTitle)
                            .font(.title3.bold())
                            .lineLimit(2)
                        Text(result.topCandidate.episodeTitle ?? result.topCandidate.episodeLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            MetadataPill(
                                text: result.topCandidate.episodeLine,
                                symbol: "play.square.stack"
                            )
                        }
                    }
                    Spacer(minLength: 4)
                    MatchScoreRing(score: result.topCandidate.confidence)
                }
                .padding(12)
                .background(Color.sceneSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.07), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
