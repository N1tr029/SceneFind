import SwiftUI

struct CinematicBackground: View {
    var body: some View {
        LinearGradient(colors: [.black, Color(red: 0.09, green: 0.11, blue: 0.16), Color(red: 0.12, green: 0.07, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

struct PosterPlaceholder: View {
    let title: String
    let confidence: Double

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [posterColor.opacity(0.95), .black.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "film.stack")
                .font(.system(size: 74, weight: .thin))
                .foregroundStyle(.white.opacity(0.24))
            Text(title)
                .font(.title2.weight(.bold))
                .padding()
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(0.68, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("Poster placeholder for \(title)")
    }

    private var posterColor: Color {
        if confidence >= 0.85 { return Color(red: 0.18, green: 0.43, blue: 0.34) }
        if confidence >= 0.60 { return Color(red: 0.44, green: 0.35, blue: 0.18) }
        return Color(red: 0.38, green: 0.18, blue: 0.20)
    }
}

struct SceneCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

