import PhotosUI
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @EnvironmentObject private var subscription: SubscriptionManager
    @State private var selectedVideo: PhotosPickerItem?
    @State private var pastedURL = ""
    @State private var errorMessage: String?
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        ZStack {
            CinematicBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    UsageAllowanceBanner(state: subscription.accessState) {
                        router.navigate(to: .paywall)
                    }
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
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("SceneFind")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
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

// MARK: - Allowance

private struct UsageAllowanceBanner: View {
    let state: SubscriptionAccessState
    let action: () -> Void

    private var isAvailable: Bool {
        if case .online = state { return true }
        return false
    }

    private var label: String {
        switch state {
        case .loading:
            "Checking your allowance…"
        case .online(let entitlement):
            "\(entitlement.plan.name) · \(entitlement.remaining) of \(entitlement.allowance) remaining"
        case .offline:
            "Allowance unavailable offline"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isAvailable ? "checkmark.seal.fill" : "wifi.slash")
                    .foregroundStyle(isAvailable ? Color.sceneGreen : Color.sceneGold)
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .sceneGlassInteractive(in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens SceneFind plans and allowance details")
    }
}

// MARK: - Input

private struct ClipInputPanel: View {
    @Binding var pastedURL: String
    @Binding var selectedVideo: PhotosPickerItem?
    @FocusState.Binding var isURLFieldFocused: Bool
    let analyze: () -> Void

    @State private var tutorialPage = 0

    private var canAnalyze: Bool {
        !pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SceneCard {
            VStack(alignment: .leading, spacing: 18) {
                ClipTutorialDeck(page: $tutorialPage) {
                    isURLFieldFocused = true
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Find the original moment")
                        .font(.title3.weight(.semibold))
                    Text("Paste a clip link or import a video.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                SceneGlassContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .foregroundStyle(canAnalyze ? Color.sceneCyan : .secondary)
                                .contentTransition(.symbolEffect(.replace))
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
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear link")
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .sceneGlass(in: Capsule())

                        Button(action: analyze) {
                            Image(systemName: "arrow.right")
                                .font(.headline)
                                .foregroundStyle(canAnalyze ? Color.sceneBackground : .secondary)
                                .frame(width: 50, height: 50)
                        }
                        .buttonStyle(.plain)
                        .sceneGlassInteractive(in: Circle(), tint: canAnalyze ? .sceneCyan : nil)
                        .disabled(!canAnalyze)
                        .accessibilityLabel("Find scene")
                    }
                }

                PhotosPicker(selection: $selectedVideo, matching: .videos) {
                    Label("Import a video", systemImage: "video.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .sceneGlassInteractive(in: Capsule())
            }
        }
        .animation(.smooth(duration: 0.3), value: canAnalyze)
    }
}

// MARK: - Tutorial

private struct ClipTutorialDeck: View {
    @Binding var page: Int
    let focusLinkField: () -> Void

    private let steps = TutorialStep.all

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    TutorialSlide(step: step)
                        .tag(index)
                        .padding(.horizontal, 16)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 150)

            HStack {
                HStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { index in
                        Button {
                            move(to: index)
                        } label: {
                            Capsule()
                                .fill(index == page ? steps[page].accent : Color.white.opacity(0.16))
                                .frame(width: index == page ? 20 : 6, height: 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Step \(index + 1)")
                    }
                }
                .animation(.snappy(duration: 0.25), value: page)

                Spacer()

                Button {
                    if page == steps.count - 1 {
                        focusLinkField()
                    } else {
                        move(to: page + 1)
                    }
                } label: {
                    Image(systemName: page == steps.count - 1 ? "arrow.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.sceneBackground)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .sceneGlassInteractive(in: Circle(), tint: steps[page].accent)
                .accessibilityLabel(page == steps.count - 1 ? "Enter a clip link" : "Next step")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(Color.sceneSurfaceRaised, in: SceneShape.inset)
        .animation(.smooth(duration: 0.3), value: page)
        .sensoryFeedback(.selection, trigger: page)
    }

    private func move(to destination: Int) {
        guard steps.indices.contains(destination) else { return }
        withAnimation(.snappy(duration: 0.32)) {
            page = destination
        }
    }
}

private struct TutorialSlide: View {
    let step: TutorialStep

    var body: some View {
        HStack(spacing: 16) {
            TutorialIllustration(kind: step.kind, accent: step.accent)
                .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 5) {
                Text(step.eyebrow)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(step.accent)
                Text(step.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TutorialIllustration: View {
    let kind: TutorialStep.Kind
    let accent: Color

    var body: some View {
        ZStack {
            SceneShape.inset.fill(accent.opacity(0.10))

            switch kind {
            case .share:
                HStack(spacing: 8) {
                    VStack(spacing: 6) {
                        SourceTile(symbol: "music.note", color: .white)
                        SourceTile(symbol: "play.rectangle.fill", color: .sceneCoral)
                    }
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(accent)
                }
            case .add:
                VStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(accent)
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule()
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 16, height: 4)
                        }
                    }
                }
            case .watch:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.sceneGreen)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(accent)
                }
            }
        }
    }
}

private struct SourceTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(Color.sceneBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct TutorialStep: Identifiable {
    enum Kind {
        case share
        case add
        case watch
    }

    let id: Int
    let eyebrow: String
    let title: String
    let detail: String
    let accent: Color
    let kind: Kind

    static let all = [
        TutorialStep(
            id: 0,
            eyebrow: "Step 1",
            title: "Find a clip",
            detail: "Tap Share in TikTok, YouTube, or Instagram.",
            accent: .sceneCyan,
            kind: .share
        ),
        TutorialStep(
            id: 1,
            eyebrow: "Step 2",
            title: "Send it here",
            detail: "Choose SceneFind, paste its link, or import the video.",
            accent: .sceneGold,
            kind: .add
        ),
        TutorialStep(
            id: 2,
            eyebrow: "Step 3",
            title: "Watch the scene",
            detail: "Confirm the match and open the episode on your service.",
            accent: .sceneGreen,
            kind: .watch
        )
    ]
}

// MARK: - Services

private struct ServiceAccessButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconTile(symbol: "play.tv.fill", tint: .sceneCoral)
                VStack(alignment: .leading, spacing: 2) {
                    Text("My services")
                        .font(.headline)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color.sceneSurface, in: SceneShape.card)
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        count == 0 ? "Choose where you watch" : "\(count) selected service\(count == 1 ? "" : "s")"
    }
}

// MARK: - Last match

private struct LastMatchSection: View {
    let result: ClipAnalysisResult
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last match")
                    .font(.headline)
                Spacer()
                Text(result.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            Button(action: action) {
                HStack(spacing: 14) {
                    ShowCoverArtwork(candidate: result.topCandidate)
                        .frame(width: 72, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.topCandidate.mediaTitle)
                            .font(.headline)
                            .lineLimit(2)
                        Text(result.topCandidate.episodeTitle ?? result.topCandidate.episodeLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        MetadataPill(
                            text: result.topCandidate.episodeLine,
                            symbol: "play.square.stack"
                        )
                    }
                    Spacer(minLength: 4)
                    MatchScoreRing(score: result.topCandidate.confidence)
                }
                .padding(14)
                .background(Color.sceneSurface, in: SceneShape.card)
            }
            .buttonStyle(.plain)
        }
    }
}
