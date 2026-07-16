import SwiftUI

struct AlternativesView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    let resultID: UUID

    private var result: ClipAnalysisResult? {
        router.resultsByID[resultID] ?? model.result(id: resultID)
    }

    var body: some View {
        ZStack {
            CinematicBackground()
            if let result {
                List {
                    ForEach(result.alternativeCandidates) { candidate in
                        Button {
                            let updated = ClipAnalysisResult(
                                id: UUID(),
                                requestID: result.requestID,
                                createdAt: Date(),
                                detectedDialogue: result.detectedDialogue,
                                topCandidate: candidate,
                                alternativeCandidates: [result.topCandidate] + result.alternativeCandidates.filter { $0.id != candidate.id },
                                analysisDetails: result.analysisDetails
                            )
                            router.resultsByID[updated.id] = updated
                            model.record(updated)
                            router.navigate(to: .result(updated.id))
                        } label: {
                            CandidateCell(candidate: candidate)
                        }
                        .foregroundStyle(.primary)
                        .listRowBackground(Color.sceneSurface)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView("No alternatives", systemImage: "list.bullet.rectangle")
            }
        }
        .navigationTitle("Candidates")
    }
}

struct CandidateCell: View {
    let candidate: SceneCandidate

    var body: some View {
        HStack(spacing: 12) {
            ShowCoverArtwork(candidate: candidate)
                .frame(width: 58, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Text(candidate.mediaTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(candidate.episodeTitle ?? candidate.episodeLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    MetadataPill(text: candidate.episodeLine, symbol: "play.square.stack")
                    if let timestamp = candidate.sceneTimestampSeconds {
                        MetadataPill(text: timestamp.timestampString, symbol: "scope", tint: .sceneCyan)
                    }
                }
            }
            Spacer(minLength: 4)
            MatchScoreRing(score: candidate.confidence, diameter: 46)
        }
        .padding(.vertical, 8)
        .accessibilityLabel("Candidate \(candidate.mediaTitle), \(candidate.confidenceLabel)")
    }
}
