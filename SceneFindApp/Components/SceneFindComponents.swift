import SwiftUI

// MARK: - Palette

extension Color {
    static let sceneBackground = Color(red: 0.035, green: 0.037, blue: 0.045)
    static let sceneSurface = Color(red: 0.085, green: 0.090, blue: 0.104)
    static let sceneSurfaceRaised = Color(red: 0.120, green: 0.126, blue: 0.142)
    static let sceneCyan = Color(red: 0.12, green: 0.78, blue: 0.92)
    static let sceneGreen = Color(red: 0.26, green: 0.88, blue: 0.55)
    static let sceneCoral = Color(red: 1.0, green: 0.38, blue: 0.32)
    static let sceneGold = Color(red: 0.98, green: 0.75, blue: 0.25)
}

// MARK: - Shape language
//
// One radius for content, capsules for controls. Everything concentric; no
// hairline strokes. Apple's Liquid Glass guidance is that glass belongs on the
// control layer floating above content, not on the content itself, so cards
// stay on a quiet solid surface and only inputs, buttons and bars go glass.

enum SceneShape {
    static let cardRadius: CGFloat = 22
    static let insetRadius: CGFloat = 14
    static let tileRadius: CGFloat = 10

    static var card: RoundedRectangle { RoundedRectangle(cornerRadius: cardRadius, style: .continuous) }
    static var inset: RoundedRectangle { RoundedRectangle(cornerRadius: insetRadius, style: .continuous) }
    static var tile: RoundedRectangle { RoundedRectangle(cornerRadius: tileRadius, style: .continuous) }
}

// MARK: - Liquid Glass, gated for the iOS 17 deployment target

extension View {
    /// A glass control surface. Real `glassEffect` on iOS 26, a material below
    /// it — and either way, a plain surface when the user has asked for reduced
    /// transparency, which Apple treats as a hard requirement.
    @ViewBuilder
    func sceneGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(SceneGlassModifier(shape: shape, tint: tint, interactive: false))
    }

    /// Glass for tappable controls: picks up the press/scale response on 26.
    @ViewBuilder
    func sceneGlassInteractive<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(SceneGlassModifier(shape: shape, tint: tint, interactive: true))
    }
}

private struct SceneGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background((tint ?? Color.sceneSurfaceRaised), in: shape)
        } else if #available(iOS 26, *) {
            let base: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            content.glassEffect(interactive ? base.interactive() : base, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.18))
                    }
                }
        }
    }
}

/// Groups sibling glass controls so they share one lens and morph together,
/// which is what makes a row of glass buttons read as one object rather than
/// three separate blobs. No-op below iOS 26.
struct SceneGlassContainer<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Artwork

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

// MARK: - Background

/// A quiet dark field with one soft cool highlight. Glass needs something
/// behind it to refract, and a flat black background makes every glass
/// control look like a grey rectangle.
struct CinematicBackground: View {
    var body: some View {
        ZStack {
            Color.sceneBackground
            RadialGradient(
                colors: [Color.sceneCyan.opacity(0.14), .clear],
                center: .init(x: 0.15, y: 0.0),
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [Color.sceneCoral.opacity(0.07), .clear],
                center: .init(x: 1.0, y: 0.95),
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Content card

/// Content sits on a solid, slightly raised surface with a generous continuous
/// radius and no outline. Depth comes from the surface, not from a stroke.
struct SceneCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Color.sceneSurface, in: SceneShape.card)
    }
}

// MARK: - Small pieces

struct SignalBars: View {
    var accent: Color = .sceneGreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 20)) { timeline in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<7, id: \.self) { index in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let value = reduceMotion ? 0.55 : (sin(time * 4 + Double(index) * 0.9) + 1) / 2
                    Capsule()
                        .fill(accent)
                        .frame(width: 3, height: 4 + value * 12)
                }
            }
        }
    }
}

struct MatchScoreRing: View {
    let score: Double
    var diameter: CGFloat = 52

    @State private var displayedScore = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.10), lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(max(displayedScore, 0), 1))
                .stroke(scoreColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(score * 100))")
                .font(.caption.bold().monospacedDigit())
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            withAnimation(.spring(duration: 0.8, bounce: 0.2)) {
                displayedScore = score
            }
        }
        .accessibilityLabel("\(Int(score * 100)) percent confidence")
    }

    private var scoreColor: Color {
        score >= 0.85 ? .sceneGreen : score >= 0.60 ? .sceneGold : .sceneCoral
    }
}

struct MetadataPill: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .sceneGlass(in: Capsule())
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

/// A leading icon in a soft tinted tile — the one decorative element that
/// survives, because it carries meaning (which service, which source).
struct IconTile: View {
    let symbol: String
    var tint: Color = .sceneCyan
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: SceneShape.tile)
    }
}
