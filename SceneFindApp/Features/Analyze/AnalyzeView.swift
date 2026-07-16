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
        AnalysisStage(label: "Reading the clip", symbol: "link"),
        AnalysisStage(label: "Checking known scenes", symbol: "film.stack"),
        AnalysisStage(label: "Scanning video and audio", symbol: "waveform"),
        AnalysisStage(label: "Finding the episode", symbol: "sparkle.magnifyingglass"),
        AnalysisStage(label: "Locating the moment", symbol: "scope"),
        AnalysisStage(label: "Preparing watch options", symbol: "play.tv")
    ]

    private var progress: Double {
        min(Double(currentStep + 1) / Double(steps.count), isAnalyzing ? 0.92 : 1)
    }

    var body: some View {
        ZStack {
            CinematicBackground()
            ScrollView {
                VStack(spacing: 22) {
                    AnalysisVisual(
                        stage: steps[currentStep],
                        stepNumber: currentStep + 1,
                        totalSteps: steps.count,
                        progress: progress,
                        startedAt: analysisStartedAt,
                        isAnalyzing: isAnalyzing
                    )

                    AnalysisProgressRail(
                        stages: steps,
                        currentStep: currentStep,
                        hasError: errorMessage != nil
                    )

                    if let request {
                        AnalysisSourceSummary(request: request)
                    }

                    if let errorMessage {
                        AnalysisErrorCard(
                            title: errorTitle,
                            message: errorMessage,
                            retry: retry
                        )
                    }
                }
                .padding()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(role: .cancel, action: dismiss.callAsFunction) {
                Label(isAnalyzing ? "Cancel analysis" : "Close", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Analyzing clip")
        .navigationBarTitleDisplayMode(.inline)
        .task { await runAnalysis() }
        .animation(.smooth(duration: 0.45), value: currentStep)
    }

    private func retry() {
        Task { await runAnalysis() }
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
            model.record(result)
            router.resultsByID[result.id] = result
            isAnalyzing = false
            router.finishAnalysis(requestID: requestID, resultID: result.id)
        } catch {
            isAnalyzing = false
            errorTitle = (error as? SceneFindError)?.failureTitle ?? "Analysis failed"
            errorMessage = error.localizedDescription
        }
    }
}

private struct AnalysisStage: Identifiable {
    let id = UUID()
    let label: String
    let symbol: String
}

private struct AnalysisVisual: View {
    let stage: AnalysisStage
    let stepNumber: Int
    let totalSteps: Int
    let progress: Double
    let startedAt: Date
    let isAnalyzing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SignalScanner(
                symbol: stage.symbol,
                progress: progress,
                accent: isAnalyzing ? .sceneCyan : .sceneCoral
            )

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(stage.label)
                        .font(.title2.bold())
                        .contentTransition(.opacity)
                    Text("STEP \(stepNumber) OF \(totalSteps)")
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(Color.sceneCyan)
                        .contentTransition(.numericText())
                }
                Spacer()
                if isAnalyzing {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(elapsedLabel(at: context.date))
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func elapsedLabel(at date: Date) -> String {
        "\(max(0, Int(date.timeIntervalSince(startedAt))))s"
    }
}

private struct AnalysisProgressRail: View {
    let stages: [AnalysisStage]
    let currentStep: Int
    let hasError: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                Image(systemName: symbol(for: index, stage: stage))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: index))
                    .frame(width: 34, height: 34)
                    .background(color(for: index).opacity(index <= currentStep ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(color(for: index).opacity(index == currentStep ? 0.6 : 0.12), lineWidth: 1)
                    }
                    .accessibilityLabel(stage.label)
                if index < stages.count - 1 {
                    Rectangle()
                        .fill(index < currentStep ? Color.sceneGreen : .white.opacity(0.08))
                        .frame(height: 2)
                }
            }
        }
    }

    private func symbol(for index: Int, stage: AnalysisStage) -> String {
        if index < currentStep { return "checkmark" }
        if index == currentStep, hasError { return "exclamationmark" }
        return stage.symbol
    }

    private func color(for index: Int) -> Color {
        if index < currentStep { return .sceneGreen }
        if index == currentStep { return hasError ? .sceneCoral : .sceneCyan }
        return .secondary
    }
}

private struct AnalysisSourceSummary: View {
    let request: SharedClipRequest

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: request.sourceType == .video ? "video.fill" : "link")
                .font(.title3)
                .foregroundStyle(Color.sceneGold)
                .frame(width: 42, height: 42)
                .background(Color.sceneGold.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(request.pageTitle ?? "Shared clip")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(request.sourcePlatform.label) · \(request.sourceType.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.sceneSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct AnalysisErrorCard: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        SceneCard {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(Color.sceneCoral)
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.sceneCoral)
            }
        }
    }
}
