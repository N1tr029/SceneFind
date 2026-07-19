import SwiftUI
import UIKit

struct ResultView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @State private var selectedProvider: WatchProvider?

    let resultID: UUID

    private var result: ClipAnalysisResult? {
        router.resultsByID[resultID] ?? model.result(id: resultID)
    }

    var body: some View {
        ZStack {
            CinematicBackground()
            if let result {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HeroArtwork(candidate: result.topCandidate)
                        VStack(alignment: .leading, spacing: 22) {
                            ClipTimelineCard(result: result)
                            whereToWatch(result.topCandidate)
                            if model.showAnalysisDetails {
                                analysisDetails(result)
                            }
                            actions(result)

                            if !result.alternativeCandidates.isEmpty {
                                Button {
                                    router.navigate(to: .alternatives(result.id))
                                } label: {
                                    Label("View other matches", systemImage: "square.stack.3d.up")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding()
                    }
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

    private func whereToWatch(_ candidate: SceneCandidate) -> some View {
        let providers = providers(for: candidate)
        let yourProviders = providers.filter { model.accessState(for: $0) == .subscribed }
        let otherProviders = providers.filter { model.accessState(for: $0) != .subscribed }
        return SceneCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Watch", systemImage: "play.fill")
                        .font(.title3.bold())
                    Spacer()
                    Button {
                        router.navigate(to: .services)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Manage streaming services")
                }
                .padding(.bottom, 8)

                if providers.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "link.badge.plus")
                            .font(.title2)
                            .foregroundStyle(Color.sceneGold)
                        Text("No verified episode link yet")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                } else {
                    if !yourProviders.isEmpty {
                        Text("YOUR SERVICES")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.sceneGreen)
                            .padding(.vertical, 8)
                        ForEach(Array(yourProviders.enumerated()), id: \.element.id) { index, provider in
                            ProviderRow(provider: provider, access: .subscribed) {
                                selectedProvider = provider
                            }
                            if index < yourProviders.count - 1 { Divider() }
                        }
                    }

                    if !otherProviders.isEmpty {
                        if !yourProviders.isEmpty { Divider().padding(.vertical, 6) }
                        Text(yourProviders.isEmpty ? "AVAILABLE" : "MORE OPTIONS")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                        ForEach(Array(otherProviders.enumerated()), id: \.element.id) { index, provider in
                            ProviderRow(provider: provider, access: model.accessState(for: provider)) {
                                selectedProvider = provider
                            }
                            if index < otherProviders.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func analysisDetails(_ result: ClipAnalysisResult) -> some View {
        SceneCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    MatchSignalBars(candidate: result.topCandidate)
                    Divider()
                    detailRow("Heard", result.detectedDialogue)
                    detailRow("Matched", result.topCandidate.matchedSubtitleText ?? "No subtitle line matched")
                    if result.analysisDetails.directMediaAnalyzed == true {
                        let observations = result.analysisDetails.visualEvidence ?? []
                        detailRow("Saw", observations.isEmpty
                            ? "No visual observations returned"
                            : observations.joined(separator: "\n"))
                    }
                    if let verification = result.analysisDetails.episodeVerificationEvidence {
                        detailRow("Episode check", verification)
                    }
                    detailRow("Source", "\(result.analysisDetails.sourcePlatform.label) · \(result.analysisDetails.sourceType.label)")
                }
                .padding(.top, 14)
            } label: {
                Label("Why this match", systemImage: "waveform.badge.magnifyingglass")
                    .font(.headline)
            }
            .tint(Color.sceneCyan)
        }
    }

    private func actions(_ result: ClipAnalysisResult) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    if model.isSaved(result) {
                        model.removeSaved(id: result.id)
                    } else {
                        model.save(result)
                    }
                } label: {
                    Label(
                        model.isSaved(result) ? "Saved" : "Save",
                        systemImage: model.isSaved(result) ? "bookmark.fill" : "bookmark"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isSaved(result) ? Color.sceneGreen : Color.sceneCyan)

                Button {
                    UIPasteboard.general.string = copyText(result)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Copy match")

                Button {
                    router.navigate(to: .analyze(result.requestID))
                } label: {
                    Image(systemName: "hand.thumbsdown")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Report wrong match")
            }

            Button {
                router.returnHome()
            } label: {
                Label("Scan another clip", systemImage: "plus.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func providers(for candidate: SceneCandidate) -> [WatchProvider] {
        let supplied: [WatchProvider]
        if let providers = candidate.watchProviders, !providers.isEmpty {
            supplied = providers
        } else if let url = candidate.streamingURL {
            supplied = [WatchProvider(
                id: candidate.streamingService ?? "streaming",
                name: candidate.streamingService ?? "Streaming",
                offer: "Availability varies",
                episodeURL: url,
                sceneURL: nil,
                symbolName: "play.tv.fill",
                brandColorHex: "3B82F6"
            )]
        } else {
            supplied = []
        }
        return StreamingProviderCatalog.providers(for: candidate, supplied: supplied)
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
        ZStack {
            ShowCoverArtwork(candidate: candidate, contentMode: .fill)
                .scaleEffect(1.18)
                .blur(radius: 22)
                .opacity(0.78)

            LinearGradient(
                colors: [.black.opacity(0.16), .black.opacity(0.52), Color.sceneBackground],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 16) {
                ShowCoverArtwork(candidate: candidate, contentMode: .fit)
                    .frame(width: 108, height: 162)
                    .background(.black.opacity(0.32))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)

                VStack(alignment: .leading, spacing: 8) {
                    Text(candidate.episodeTitle ?? candidate.mediaTitle)
                        .font(.title2.bold())
                        .lineLimit(3)
                    Text(mediaLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if let timestamp = candidate.sceneTimestampSeconds {
                            MetadataPill(
                                text: timestamp.timestampString,
                                symbol: "scope",
                                tint: .sceneCyan
                            )
                        }
                        MatchScoreRing(score: candidate.confidence, diameter: 48)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 286)
        .clipped()
        .accessibilityLabel("Artwork for \(candidate.mediaTitle)")
    }

    private var mediaLine: String {
        switch candidate.mediaType {
        case .television: "\(candidate.mediaTitle) · \(candidate.episodeLine)"
        case .movie: "Movie · \(candidate.releaseYear)"
        case .other: "Online media · \(candidate.releaseYear)"
        }
    }
}

private struct ClipTimelineCard: View {
    let result: ClipAnalysisResult

    var body: some View {
        SceneCard {
            VStack(spacing: 14) {
                HStack {
                    Label("Clip location", systemImage: "timeline.selection")
                        .font(.headline)
                    Spacer()
                    MetadataPill(
                        text: result.analysisDetails.sourcePlatform.label,
                        symbol: "arrowshape.turn.up.right"
                    )
                }

                HStack(alignment: .center, spacing: 12) {
                    timeValue(label: "START", value: result.topCandidate.sceneTimestampSeconds)
                    ZStack {
                        Capsule().fill(.white.opacity(0.08)).frame(height: 4)
                        Capsule().fill(Color.sceneCyan).frame(height: 4)
                            .padding(.horizontal, 8)
                    }
                    timeValue(
                        label: "END",
                        value: result.topCandidate.clipEndTimestampSeconds ?? result.topCandidate.sceneTimestampSeconds
                    )
                }
            }
        }
    }

    private func timeValue(label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value?.timestampString ?? "--:--:--")
                .font(.subheadline.bold().monospacedDigit())
        }
    }
}

private struct MatchSignalBars: View {
    let candidate: SceneCandidate

    var body: some View {
        VStack(spacing: 10) {
            scoreRow("Dialogue", value: candidate.subtitleScore, tint: .sceneGreen)
            scoreRow("Visual", value: candidate.visualScore, tint: .sceneCoral)
            scoreRow("Metadata", value: candidate.metadataScore, tint: .sceneCyan)
        }
    }

    private func scoreRow(_ label: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .frame(width: 62, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 5)
            Text("\(Int(value * 100))")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}

private struct ProviderRow: View {
    let provider: WatchProvider
    let access: StreamingAccessState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.symbolName)
                .font(.title3)
                .foregroundStyle(Color(hex: provider.brandColorHex))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name)
                    .font(.headline)
                Text(access == .subscribed ? provider.offer : access.shortLabel)
                    .font(.caption)
                    .foregroundStyle(access == .subscribed ? Color.sceneGreen : .secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(action: action) {
                Image(systemName: "play.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: provider.brandColorHex))
            .accessibilityLabel("Watch on \(provider.name)")
        }
        .padding(.vertical, 12)
    }
}

private struct WatchOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isResolving = false
    @State private var openError: String?

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
                    Task { await open(.beginning) }
                } label: {
                    optionLabel(
                        title: "Start from the beginning",
                        subtitle: "Open the full episode at 00:00",
                        symbol: "backward.end.fill"
                    )
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await open(.afterClip) }
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

                if isResolving {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Finding the exact episode on \(provider.name)...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
            .padding()
            .disabled(isResolving)
            .navigationTitle("How do you want to watch?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .alert("Could not open \(provider.name)", isPresented: Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openError ?? "Try again in a moment.")
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
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @MainActor
    private func open(_ choice: WatchStartChoice) async {
        isResolving = true
        guard let resolved = await StreamingDestinationResolver().destination(
            for: provider,
            candidate: candidate
        ) else {
            isResolving = false
            openError = "SceneFind could not verify an exact episode link for \(provider.name). It will not send you to the wrong show page."
            return
        }

        if choice == .afterClip, let timestamp = afterClipTimestamp {
            UIPasteboard.general.string = timestamp.timestampString
        }

        let destinations = [resolved.primaryURL, resolved.webFallbackURL]
            .compactMap { $0 }
            .reduce(into: [URL]()) { urls, url in
                if !urls.contains(url) { urls.append(url) }
            }
        var accepted = false
        for destination in destinations {
            accepted = await openDestination(destination)
            if accepted { break }
        }
        isResolving = false
        if accepted {
            dismiss()
        } else {
            openError = "SceneFind could not hand this episode to \(provider.name). Check that the app is installed, then try again."
        }
    }

    @MainActor
    private func openDestination(_ url: URL) async -> Bool {
        if url.scheme?.lowercased() == "https" {
            let openedInstalledApp = await withCheckedContinuation { continuation in
                UIApplication.shared.open(
                    url,
                    options: [.universalLinksOnly: true]
                ) { continuation.resume(returning: $0) }
            }
            if openedInstalledApp { return true }
            if url.host?.lowercased() == "dl.hulu.com" { return false }
        }

        return await withCheckedContinuation { continuation in
            openURL(url) { continuation.resume(returning: $0) }
        }
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
