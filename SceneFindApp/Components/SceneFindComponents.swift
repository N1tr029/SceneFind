import SwiftUI

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
