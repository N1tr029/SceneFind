import SwiftUI

struct AnalyzeView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @Environment(\.dismiss) private var dismiss
    let requestID: UUID

    @State private var request: SharedClipRequest?
    @State private var currentStep = 0
    @State private var isAnalyzing = false
    @State private var analysisStartedAt = Date()
    @State private var errorTitle = "Analysis failed"
    @State private var errorMessage: String?

    private let steps = [
        "Reading shared link",
        "Checking known scenes",
        "Inspecting video and audio",
        "Identifying show and episode",
        "Locating the moment",
        "Preparing watch options"
    ]

    var body: some View {
        ZStack {
            CinematicBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let request {
                        summary(request)
                    }

                    SceneCard {
                        VStack(alignment: .leading, spacing: 16) {
                            if isAnalyzing {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .tint(.green)
                                    Text("Analyzing clip")
                                        .font(.headline)
                                    Spacer()
                                    TimelineView(.periodic(from: analysisStartedAt, by: 1)) { context in
                                        Text(elapsedLabel(at: context.date))
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            ForEach(steps.indices, id: \.self) { index in
                                HStack {
                                    stepIndicator(for: index)
                                    Text(steps[index])
                                        .foregroundStyle(index <= currentStep ? .primary : .secondary)
                                    Spacer()
                                }
                                .accessibilityLabel("\(steps[index]) \(index < currentStep ? "complete" : index == currentStep ? "in progress" : "pending")")
                            }
                            if isAnalyzing {
                                ProgressView(value: min(Double(currentStep + 1) / Double(steps.count), 0.9))
                                    .tint(.blue)
                                    .accessibilityLabel("Analysis progress")
                            }
                        }
                    }

                    if let errorMessage {
                        ContentUnavailableView(errorTitle, systemImage: "film.badge.exclamationmark", description: Text(errorMessage))
                    }
                }
                .padding()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if errorMessage != nil {
                    Button {
                        Task { await runAnalysis() }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Label(isAnalyzing ? "Cancel" : "Close", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle(isAnalyzing ? "Analyzing" : "Analysis")
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
        guard !isAnalyzing else { return }
        isAnalyzing = true
        analysisStartedAt = Date()
        currentStep = 0
        errorMessage = nil

        let progressTask = Task { @MainActor in
            let delays: [UInt64] = [1, 2, 4, 7, 10]
            for (offset, seconds) in delays.enumerated() {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard isAnalyzing else { return }
                currentStep = offset + 1
            }
        }
        defer { progressTask.cancel() }

        do {
            let loaded = try model.store.loadRequest(id: requestID)
            request = loaded
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

    @ViewBuilder
    private func stepIndicator(for index: Int) -> some View {
        if index < currentStep {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        } else if index == currentStep, isAnalyzing {
            ProgressView()
                .controlSize(.small)
                .tint(.green)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        } else if index == currentStep, errorMessage != nil {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func elapsedLabel(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(analysisStartedAt)))
        return "\(seconds)s"
    }
}
