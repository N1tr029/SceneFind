import SwiftUI

struct AnalyzeView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @Environment(\.dismiss) private var dismiss
    let requestID: UUID

    @State private var request: SharedClipRequest?
    @State private var currentStep = 0
    @State private var isAnalyzing = true
    @State private var errorTitle = "Analysis failed"
    @State private var errorMessage: String?

    private let steps = [
        "Reading shared content",
        "Extracting clip information",
        "Finding public captions",
        "Searching dialogue matches",
        "Checking episode guides",
        "Ranking likely scenes"
    ]

    var body: some View {
        ZStack {
            CinematicBackground()
            VStack(alignment: .leading, spacing: 24) {
                if let request {
                    summary(request)
                }

                SceneCard {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(steps.indices, id: \.self) { index in
                            HStack {
                                Image(systemName: index < currentStep ? "checkmark.circle.fill" : index == currentStep ? "circle.dotted" : "circle")
                                    .foregroundStyle(index <= currentStep ? Color.green : Color.secondary)
                                    .accessibilityHidden(true)
                                Text(steps[index])
                                    .foregroundStyle(index <= currentStep ? .primary : .secondary)
                                Spacer()
                            }
                            .accessibilityLabel("\(steps[index]) \(index < currentStep ? "complete" : index == currentStep ? "in progress" : "pending")")
                        }
                        ProgressView(value: Double(currentStep), total: Double(max(steps.count - 1, 1)))
                            .accessibilityLabel("Analysis progress")
                    }
                }

                if let errorMessage {
                    ContentUnavailableView(errorTitle, systemImage: "film.badge.exclamationmark", description: Text(errorMessage))
                }

                Spacer()

                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding()
        }
        .navigationTitle("Analyzing")
        .navigationBarTitleDisplayMode(.inline)
        .task { await runAnalysis() }
    }

    private func summary(_ request: SharedClipRequest) -> some View {
        SceneCard {
            HStack(spacing: 14) {
                Image(systemName: request.sourceType == .video ? "video" : "link")
                    .font(.title)
                    .frame(width: 58, height: 58)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.pageTitle ?? "Shared clip")
                        .font(.headline)
                    Text("\(request.sourcePlatform.label) • \(request.sourceType.label)")
                        .foregroundStyle(.secondary)
                    if let url = request.originalURL {
                        Text(url.absoluteString)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }

    @MainActor
    private func runAnalysis() async {
        guard isAnalyzing else { return }
        do {
            let loaded = try model.store.loadRequest(id: requestID)
            request = loaded

            for index in steps.indices {
                currentStep = index
                try await Task.sleep(nanoseconds: UInt64.random(in: 300_000_000...800_000_000))
            }

            let result = try await model.identificationService.identify(request: loaded)
            model.save(result)
            router.resultsByID[result.id] = result
            isAnalyzing = false
            router.path.removeAll { $0 == .analyze(requestID) }
            router.navigate(to: .result(result.id))
        } catch {
            isAnalyzing = false
            errorTitle = (error as? SceneFindError)?.failureTitle ?? "Analysis failed"
            errorMessage = error.localizedDescription
        }
    }
}
