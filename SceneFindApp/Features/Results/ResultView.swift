import SwiftUI
import UIKit

struct ResultView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @State private var selectedProvider: WatchProvider?

    let resultID: UUID

    private var result: ClipAnalysisResult? {
        router.resultsByID[resultID] ?? model.savedResults.first { $0.id == resultID }
    }

    var body: some View {
        ZStack {
            CinematicBackground()
            if let result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HeroArtwork(candidate: result.topCandidate)
                        titleBlock(result.topCandidate)
                        whereToWatch(result.topCandidate)
                        if model.showAnalysisDetails {
                            analysisDetails(result)
                        }
                        actions(result)

                        if !result.alternativeCandidates.isEmpty {
                            Button {
                                router.navigate(to: .alternatives(result.id))
                            } label: {
                                Label("Choose another candidate", systemImage: "list.bullet.rectangle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView(
                    "Result not found",
                    systemImage: "magnifyingglass",
                    description: Text("The saved result may have been deleted.")
                )
            }
        }
        .navigationTitle("Scene match")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedProvider) { provider in
            if let candidate = result?.topCandidate {
                WatchOptionsSheet(provider: provider, candidate: candidate)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func titleBlock(_ candidate: SceneCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ConfidenceBadge(candidate: candidate)
            Text(candidate.episodeTitle ?? candidate.mediaTitle)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)

            if candidate.mediaType == .television {
                Text("\(candidate.mediaTitle) · \(candidate.episodeLine)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(candidate.mediaTitle) · \(candidate.releaseYear)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            if let timestamp = candidate.sceneTimestampSeconds {
                Label("Scene begins at \(timestamp.timestampString)", systemImage: "timer")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func whereToWatch(_ candidate: SceneCandidate) -> some View {
        let providers = providers(for: candidate)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Where to Watch")
                    .font(.title2.bold())
                Spacer()
                Image(systemName: "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            if providers.isEmpty {
                ContentUnavailableView(
                    "No providers found",
                    systemImage: "play.tv",
                    description: Text("Streaming availability is not available for this match.")
                )
            } else {
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                    ProviderRow(provider: provider) {
                        selectedProvider = provider
                    }
                    if index < providers.count - 1 {
                        Divider()
                    }
                }

                Text("Availability and pricing can vary by region and subscription.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
            }
        }
    }

    private func analysisDetails(_ result: ClipAnalysisResult) -> some View {
        SceneCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Why this match")
                    .font(.headline)
                detailRow("Detected dialogue", result.detectedDialogue)
                detailRow("Matching subtitle", result.topCandidate.matchedSubtitleText ?? "No subtitle line matched")
                detailRow("Source", "\(result.analysisDetails.sourcePlatform.label) · \(result.analysisDetails.sourceType.label)")
                Divider()
                detailRow(
                    "Match signals",
                    "Subtitle \(Int(result.topCandidate.subtitleScore * 100))%, visual \(Int(result.topCandidate.visualScore * 100))%, metadata \(Int(result.topCandidate.metadataScore * 100))%"
                )
            }
        }
    }

    private func actions(_ result: ClipAnalysisResult) -> some View {
        VStack(spacing: 12) {
            Button {
                model.save(result)
            } label: {
                Label("Save scene", systemImage: "bookmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HStack {
                Button {
                    UIPasteboard.general.string = copyText(result)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    router.navigate(to: .analyze(result.requestID))
                } label: {
                    Label("Wrong match", systemImage: "hand.thumbsdown")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                router.path = []
            } label: {
                Label("Analyze another clip", systemImage: "plus.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func providers(for candidate: SceneCandidate) -> [WatchProvider] {
        if let providers = candidate.watchProviders, !providers.isEmpty {
            return providers
        }
        guard let url = candidate.streamingURL else { return [] }
        return [
            WatchProvider(
                id: candidate.streamingService ?? "streaming",
                name: candidate.streamingService ?? "Streaming",
                offer: "Availability varies",
                episodeURL: url,
                sceneURL: nil,
                symbolName: "play.tv.fill",
                brandColorHex: "3B82F6"
            )
        ]
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyText(_ result: ClipAnalysisResult) -> String {
        let candidate = result.topCandidate
        return "\(candidate.mediaTitle) \(candidate.episodeLine) \(candidate.episodeTitle ?? "") at \(candidate.sceneTimestampSeconds?.timestampString ?? "unknown time") - \(candidate.confidenceLabel)"
    }
}

private struct HeroArtwork: View {
    let candidate: SceneCandidate

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color.black.opacity(0.35))

            if let url = candidate.heroImageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        fallback
                    default:
                        ProgressView()
                    }
                }
            } else {
                fallback
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )

            Text(candidate.mediaTitle)
                .font(.title2.bold())
                .padding()
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("Artwork for \(candidate.mediaTitle)")
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.22, green: 0.17, blue: 0.08), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "film.stack")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.white.opacity(0.28))
        }
    }
}

private struct ProviderRow: View {
    let provider: WatchProvider
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.symbolName)
                .font(.title3)
                .foregroundStyle(Color(hex: provider.brandColorHex))
                .frame(width: 42, height: 42)
                .background(.thinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name)
                    .font(.headline)
                Text(provider.offer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(action: action) {
                Label("Watch", systemImage: "play.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Watch on \(provider.name)")
        }
        .padding(.vertical, 12)
    }
}

private struct WatchOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let provider: WatchProvider
    let candidate: SceneCandidate

    private var afterClipTimestamp: Double? {
        candidate.clipEndTimestampSeconds ?? candidate.sceneTimestampSeconds
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.episodeTitle ?? candidate.mediaTitle)
                        .font(.title2.bold())
                    Text("Watch on \(provider.name)")
                        .foregroundStyle(.secondary)
                }

                Button {
                    open(.beginning)
                } label: {
                    optionLabel(
                        title: "Start from the beginning",
                        subtitle: "Open the full episode at 00:00",
                        symbol: "backward.end.fill"
                    )
                }
                .buttonStyle(.borderedProminent)

                Button {
                    open(.afterClip)
                } label: {
                    optionLabel(
                        title: "Continue after this clip",
                        subtitle: afterClipSubtitle,
                        symbol: "forward.end.fill"
                    )
                }
                .buttonStyle(.bordered)

                if !provider.supportsSceneDeepLink, let timestamp = afterClipTimestamp {
                    Label(
                        "\(provider.name) does not expose timestamp links. SceneFind will open the episode and copy \(timestamp.timestampString) so you can seek there.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("How do you want to watch?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var afterClipSubtitle: String {
        guard let timestamp = afterClipTimestamp else { return "Open the matched episode" }
        return "Resume at approximately \(timestamp.timestampString)"
    }

    private func optionLabel(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func open(_ choice: WatchStartChoice) {
        let destination: URL
        switch choice {
        case .beginning:
            destination = provider.episodeURL
        case .afterClip:
            destination = provider.sceneURL ?? provider.episodeURL
            if provider.sceneURL == nil, let timestamp = afterClipTimestamp {
                UIPasteboard.general.string = timestamp.timestampString
            }
        }
        openURL(destination)
        dismiss()
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0xFFFFFF
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
