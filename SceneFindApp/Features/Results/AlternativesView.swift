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
                    }
                }
                .scrollContentBackground(.hidden)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(candidate.mediaTitle)
                    .font(.headline)
                Spacer()
                Text("\(Int(candidate.confidence * 100))%")
                    .font(.subheadline.weight(.semibold))
            }
            Text("\(candidate.episodeLine) \(candidate.episodeTitle ?? "")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let text = candidate.matchedSubtitleText {
                Text(text)
                    .font(.callout)
            }
            if let timestamp = candidate.sceneTimestampSeconds {
                Label(timestamp.timestampString, systemImage: "timer")
                    .font(.caption)
            }
        }
        .padding(.vertical, 8)
        .accessibilityLabel("Candidate \(candidate.mediaTitle), \(candidate.confidenceLabel)")
    }
}
