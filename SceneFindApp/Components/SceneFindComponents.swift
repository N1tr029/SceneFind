import SwiftUI

@MainActor
private final class ShowCoverStore {
    static let shared = ShowCoverStore()

    private let artworkService = PublicTitleArtworkService()
    private var cachedURLs: [String: URL] = [:]
    private var missingKeys: Set<String> = []
    private var requests: [String: Task<URL?, Never>] = [:]

    func coverURL(for candidate: SceneCandidate) async -> URL? {
        let key = "\(candidate.mediaType.rawValue):\(candidate.mediaTitle.lowercased())"
        if let cachedURL = cachedURLs[key] { return cachedURL }
        if missingKeys.contains(key) { return usableFallback(candidate.heroImageURL) }
        if let request = requests[key] { return await request.value }

        let request = Task { [artworkService] in
            await artworkService.artworkURL(
                for: candidate.mediaTitle,
                mediaType: candidate.mediaType,
                seasonNumber: nil,
                episodeNumber: nil
            )
        }
        requests[key] = request
        let catalogURL = await request.value
        requests[key] = nil

        if let catalogURL {
            cachedURLs[key] = catalogURL
            return catalogURL
        }
        missingKeys.insert(key)
        return usableFallback(candidate.heroImageURL)
    }

    private func usableFallback(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let host = url.host?.lowercased() ?? ""
        guard !host.contains("metadata.provider"), !host.contains("wrong.example") else { return nil }
        return url
    }
}

struct ShowCoverArtwork: View {
    let candidate: SceneCandidate
    var contentMode: ContentMode = .fill

    @State private var coverURL: URL?

    var body: some View {
        Group {
            if let coverURL {
                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    case .failure:
                        fallback
                    default:
                        ProgressView()
                    }
                }
            } else {
                fallback
            }
        }
        .task(id: cacheKey) {
            coverURL = await ShowCoverStore.shared.coverURL(for: candidate)
        }
        .accessibilityLabel("Cover for \(candidate.mediaTitle)")
    }

    private var cacheKey: String {
        "\(candidate.mediaType.rawValue):\(candidate.mediaTitle.lowercased())"
    }

    private var fallback: some View {
        ZStack {
            Color(uiColor: .tertiarySystemBackground)
            Image(systemName: fallbackSymbol)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    private var fallbackSymbol: String {
        switch candidate.mediaType {
        case .movie: "film"
        case .television: "tv"
        case .other: "play.rectangle"
        }
    }
}

struct CinematicBackground: View {
    var body: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
    }
}

struct SceneCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding()
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ConfidenceBadge: View {
    let candidate: SceneCandidate

    var body: some View {
        Label("\(candidate.confidenceLabel) \(Int(candidate.confidence * 100))%", systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.20), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Match confidence \(candidate.confidenceLabel), \(Int(candidate.confidence * 100)) percent")
    }

    private var symbol: String {
        candidate.confidence >= 0.85 ? "checkmark.seal.fill" : candidate.confidence >= 0.60 ? "waveform.badge.magnifyingglass" : "exclamationmark.triangle"
    }

    private var color: Color {
        candidate.confidence >= 0.85 ? .green : candidate.confidence >= 0.60 ? .yellow : .orange
    }
}

extension Double {
    var timestampString: String {
        let value = Int(self)
        return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
    }
}
