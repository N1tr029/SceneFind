import SwiftUI

extension Color {
    static let sceneBackground = Color(red: 0.025, green: 0.027, blue: 0.032)
    static let sceneSurface = Color(red: 0.075, green: 0.080, blue: 0.090)
    static let sceneSurfaceRaised = Color(red: 0.105, green: 0.110, blue: 0.122)
    static let sceneCyan = Color(red: 0.12, green: 0.78, blue: 0.92)
    static let sceneGreen = Color(red: 0.26, green: 0.88, blue: 0.55)
    static let sceneCoral = Color(red: 1.0, green: 0.38, blue: 0.32)
    static let sceneGold = Color(red: 0.98, green: 0.75, blue: 0.25)
}

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
        ZStack {
            Color.sceneBackground
            LinearGradient(
                colors: [
                    Color.sceneCyan.opacity(0.055),
                    .clear,
                    Color.sceneCoral.opacity(0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct SceneCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding()
            .background(Color.sceneSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            }
    }
}

struct SignalScanner: View {
    var symbol = "sparkle.magnifyingglass"
    var progress: Double = 0.5
    var accent: Color = .sceneCyan

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let phase = reduceMotion ? 0.5 : time.truncatingRemainder(dividingBy: 4) / 4

                drawGrid(context: &context, size: size)
                drawWave(context: &context, size: size, time: reduceMotion ? 0 : time)
                drawScan(context: &context, size: size, phase: phase)
            }
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(accent)
                    SignalBars(accent: accent)
                        .frame(width: 52, height: 16)
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(accent.opacity(0.32), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 168)
        .background(Color.sceneSurface)
        .overlay(alignment: .bottomLeading) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(accent)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1), height: 3)
                    .animation(.smooth(duration: 0.6), value: progress)
            }
            .frame(height: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        stride(from: 0.0, through: size.width, by: 24).forEach { x in
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        stride(from: 0.0, through: size.height, by: 24).forEach { y in
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.035)), lineWidth: 0.5)
    }

    private func drawWave(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        var wave = Path()
        for x in stride(from: 0.0, through: size.width, by: 3) {
            let normalized = x / max(size.width, 1)
            let envelope = sin(normalized * .pi)
            let y = size.height / 2
                + sin(normalized * 18 + time * 3.2) * 15 * envelope
                + sin(normalized * 41 - time * 1.7) * 5
            if x == 0 { wave.move(to: CGPoint(x: x, y: y)) }
            else { wave.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(wave, with: .color(accent.opacity(0.72)), lineWidth: 1.5)
    }

    private func drawScan(context: inout GraphicsContext, size: CGSize, phase: Double) {
        let x = size.width * phase
        let rect = CGRect(x: x - 14, y: 0, width: 28, height: size.height)
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [.clear, accent.opacity(0.18), .clear]),
                startPoint: CGPoint(x: rect.minX, y: 0),
                endPoint: CGPoint(x: rect.maxX, y: 0)
            )
        )
        context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(accent.opacity(0.6)))
    }
}

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
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.white.opacity(0.06), in: Capsule())
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
