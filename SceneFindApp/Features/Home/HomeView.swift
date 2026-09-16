import PhotosUI
import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @EnvironmentObject private var subscription: SubscriptionManager
    @State private var selectedVideo: PhotosPickerItem?
    @State private var pastedURL = ""
    @State private var errorMessage: String?
    @FocusState private var isURLFieldFocused: Bool

    private var recent: [ClipAnalysisResult] { Array(model.recentResults.prefix(8)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                ClipInput(
                    pastedURL: $pastedURL,
                    selectedVideo: $selectedVideo,
                    isURLFieldFocused: $isURLFieldFocused,
                    analyze: analyzePastedURL
                )
                .padding(.top, 10)

                if !recent.isEmpty {
                    RecentMatches(results: recent) { result in
                        router.navigate(to: .result(result.id))
                    }
                }

                ServicesRow(count: model.subscribedServiceCount) {
                    router.navigate(to: .services)
                }
            }
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        // A background can't take part in layout. As a ZStack sibling, the
        // backdrop's artwork widened the stack once a recent match existed,
        // which pulled every row about 9pt toward the screen edges, so Home
        // lined up differently with and without history.
        .background { HomeBackdrop(candidate: recent.first?.topCandidate) }
        .navigationTitle("SceneFind")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AllowanceChip(state: subscription.accessState) {
                    router.navigate(to: .paywall)
                }
            }
        }
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
            let request = try await VideoImport.pendingRequest(from: selectedVideo, store: model.store)
            router.navigate(to: .analyze(request.id))
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

/// Lines content up with the system large title, which sits on UIKit's layout
/// margin: 16pt on most iPhones, 20pt on the widest. The earlier value of 26
/// was measured while the backdrop was still widening the layout by 9pt, so it
/// only looked right once a recent match existed.
private enum HomeInset {
    static var leading: CGFloat {
        let width = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }
            .first ?? 402
        return width >= 428 ? 20 : 16
    }
}

// MARK: - Backdrop

/// The last match's artwork, blurred, under the top of the screen. It is what
/// the glass input refracts. Without real imagery behind it, glass on a dark
/// field reads as a grey pill.
private struct HomeBackdrop: View {
    let candidate: SceneCandidate?

    var body: some View {
        ZStack(alignment: .top) {
            CinematicBackground()
            if let candidate {
                ShowCoverArtwork(candidate: candidate, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 560)
                    .scaleEffect(1.3)
                    .blur(radius: 52)
                    .opacity(0.6)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.35),
                                .init(color: .clear, location: 0.85)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Allowance

private struct AllowanceChip: View {
    let state: SubscriptionAccessState
    let action: () -> Void

    private var label: String {
        switch state {
        case .loading: "…"
        case .online(let entitlement): "\(entitlement.remaining) of \(entitlement.allowance)"
        case .offline: "Offline"
        }
    }

    private var symbol: String {
        if case .online = state { return "sparkles" }
        return "wifi.slash"
    }

    var body: some View {
        Button(action: action) {
            // A toolbar collapses Label to its icon on iOS 26; the number is the
            // whole point of this control, so lay it out explicitly.
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(label)
            }
            .font(.subheadline.weight(.medium))
        }
        .accessibilityLabel("Allowance: \(label)")
        .accessibilityHint("Opens SceneFind plans")
    }
}

// MARK: - Input

private struct ClipInput: View {
    @Binding var pastedURL: String
    @Binding var selectedVideo: PhotosPickerItem?
    @FocusState.Binding var isURLFieldFocused: Bool
    let analyze: () -> Void

    private var canAnalyze: Bool {
        !pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Warn before the credit is spent, not after the result comes back.
    private var isInstagramLink: Bool {
        let trimmed = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return false }
        return SharedPlatform.detect(url: url) == .instagram
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Which scene is this?")
                    .font(.title.weight(.bold))
                Text(MarketingPreview.isEnabled
                    ? "Paste a public link, or share a clip from another app."
                    : "Paste a link, or share a clip from TikTok, YouTube, or Instagram.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, HomeInset.leading)

            SceneGlassContainer(spacing: 10) {
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .foregroundStyle(canAnalyze ? Color.sceneCyan : .secondary)
                        TextField(
                            MarketingPreview.isEnabled ? "Paste a public clip link" : "TikTok, YouTube, or web link",
                            text: $pastedURL
                        )
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
                    .padding(.horizontal, 18)
                    .frame(height: 54)
                    .sceneGlass(in: Capsule())

                    Button(action: analyze) {
                        Image(systemName: "arrow.up")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(canAnalyze ? Color.sceneBackground : Color.secondary)
                            .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.plain)
                    .sceneGlassInteractive(in: Circle(), tint: canAnalyze ? .sceneCyan : nil)
                    .disabled(!canAnalyze)
                    .accessibilityLabel("Find scene")
                }
            }
            .padding(.horizontal, HomeInset.leading)

            if isInstagramLink {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.sceneGold)
                    Text("Instagram links fail more often than TikTok and can't pin the episode. Save the reel and import it to get the exact scene.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, HomeInset.leading)
                .transition(.opacity)
            }

            PhotosPicker(selection: $selectedVideo, matching: .videos) {
                Label("Import a video", systemImage: "video.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .sceneGlassInteractive(in: Capsule())
            .padding(.horizontal, HomeInset.leading)
        }
        .animation(.smooth(duration: 0.3), value: canAnalyze)
        .animation(.smooth(duration: 0.3), value: isInstagramLink)
    }
}

// MARK: - Recent

private struct RecentMatches: View {
    let results: [ClipAnalysisResult]
    let open: (ClipAnalysisResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, HomeInset.leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(results) { result in
                        Button {
                            open(result)
                        } label: {
                            PosterCard(result: result)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, HomeInset.leading)
            }
            .scrollClipDisabled()
        }
    }
}

private struct PosterCard: View {
    let result: ClipAnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShowCoverArtwork(candidate: result.topCandidate)
                .frame(width: 128, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                .overlay(alignment: .topTrailing) {
                    Text("\(Int(result.topCandidate.confidence * 100))")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .sceneGlass(in: Capsule())
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(result.topCandidate.mediaTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(result.topCandidate.episodeTitle ?? result.topCandidate.episodeLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 128, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Services

private struct ServicesRow: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconTile(symbol: "play.tv.fill", tint: .sceneCoral)
                VStack(alignment: .leading, spacing: 2) {
                    Text("My services")
                        .font(.headline)
                    Text(count == 0 ? "Choose where you watch" : "\(count) selected")
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
        .padding(.horizontal, HomeInset.leading)
    }
}
