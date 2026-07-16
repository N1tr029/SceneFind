import PhotosUI
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @State private var selectedVideo: PhotosPickerItem?
    @State private var pastedURL = ""
    @State private var showPasteField = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            CinematicBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    importActions
                    shareHint
                    demoMode
                    recentSection
                    savedPreview
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Verified catalog + Gemini video research", systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            Text("Find where any clip is from")
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("Share, paste, or import a clip to identify the show, episode, scene time, and where to watch next.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var importActions: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $selectedVideo, matching: .videos) {
                Label("Choose a video", systemImage: "video.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                withAnimation { showPasteField.toggle() }
            } label: {
                Label("Paste a link", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            if showPasteField {
                SceneCard {
                    VStack(spacing: 12) {
                        TextField("https://youtube.com/shorts/...", text: $pastedURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                        Button("Analyze link") { analyzePastedURL() }
                            .buttonStyle(.borderedProminent)
                            .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var shareHint: some View {
        SceneCard {
            Label("You can also share clips directly from TikTok, YouTube, Safari, or Photos.", systemImage: "square.and.arrow.up")
                .font(.callout)
        }
    }

    private var demoMode: some View {
        SceneCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Demo Mode")
                    .font(.headline)
                ForEach(DemoCase.allCases) { demo in
                    Button {
                        runDemo(demo)
                    } label: {
                        HStack {
                            Image(systemName: demo.icon)
                                .frame(width: 28)
                            VStack(alignment: .leading) {
                                Text(demo.title)
                                Text(demo.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Run demo \(demo.title)")
                    if demo != DemoCase.allCases.last { Divider() }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent searches")
                .font(.title3.bold())
            if model.recentResults.isEmpty {
                ContentUnavailableView("No recent searches", systemImage: "clock", description: Text("Run a demo or import a clip to start."))
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

    private var savedPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved scenes")
                .font(.title3.bold())
            if model.savedResults.isEmpty {
                ContentUnavailableView("No saved scenes", systemImage: "bookmark", description: Text("Save a result to keep it here."))
            } else {
                ForEach(model.savedResults.prefix(3)) { result in
                    ResultRow(result: result)
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

    private func runDemo(_ demo: DemoCase) {
        saveAndNavigate(demo.request)
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
                Image(systemName: "film")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
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

enum DemoCase: String, CaseIterable, Identifiable {
    case strongDialogue
    case weakVisual
    case youtubeURL
    case tiktokURL
    case importedVideo
    case noMatch
    case ambiguous

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strongDialogue: "Strong dialogue match"
        case .weakVisual: "Weak visual-only match"
        case .youtubeURL: "Verified Modern Family match"
        case .tiktokURL: "TikTok URL match"
        case .importedVideo: "Imported video match"
        case .noMatch: "No match"
        case .ambiguous: "Ambiguous candidates"
        }
    }

    var subtitle: String {
        switch self {
        case .strongDialogue: "Exact subtitle hit"
        case .weakVisual: "Quiet clip, metadata helps"
        case .youtubeURL: "The Butler's Escape at 10:06"
        case .tiktokURL: "Workplace comedy keywords"
        case .importedVideo: "Simulated Photos handoff"
        case .noMatch: "Intentionally low confidence"
        case .ambiguous: "Several plausible scenes"
        }
    }

    var icon: String {
        switch self {
        case .strongDialogue: "quote.bubble"
        case .weakVisual: "eye"
        case .youtubeURL: "play.rectangle"
        case .tiktokURL: "music.note"
        case .importedVideo: "photo.on.rectangle"
        case .noMatch: "questionmark.circle"
        case .ambiguous: "list.bullet.rectangle"
        }
    }

    var request: SharedClipRequest {
        switch self {
        case .strongDialogue:
            SharedClipRequest(sourceType: .plainText, sourcePlatform: .safari, sharedText: "We have one sunrise left before the orbit closes.", pageTitle: title)
        case .weakVisual:
            SharedClipRequest(sourceType: .demo, sourcePlatform: .files, sharedText: "quiet clip", pageTitle: "velvet observatory visual")
        case .youtubeURL:
            SharedClipRequest(
                sourceType: .url,
                sourcePlatform: .youtube,
                originalURL: URL(string: "https://www.youtube.com/shorts/QD4bDD7L66M"),
                pageTitle: "how many times has she done this??? #Shorts #ModernFamily #MitchellPritchett #CamTucker"
            )
        case .tiktokURL:
            SharedClipRequest(sourceType: .url, sourcePlatform: .tiktok, originalURL: URL(string: "https://vm.tiktok.com/paper-office-scranton"), pageTitle: "office paper joke")
        case .importedVideo:
            SharedClipRequest(sourceType: .video, sourcePlatform: .photos, localFileName: "garden-glass-flower-demo.mov", pageTitle: "Garden clip")
        case .noMatch:
            SharedClipRequest(sourceType: .plainText, sourcePlatform: .unknown, sharedText: "no-match cobalt toaster staircase sentence", pageTitle: "Unknown clip")
        case .ambiguous:
            SharedClipRequest(sourceType: .plainText, sourcePlatform: .reddit, sharedText: "The signal broke before the truth came through.", pageTitle: "signal static radio scene")
        }
    }
}
