import SwiftUI

struct AnalyzeView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @EnvironmentObject private var subscription: SubscriptionManager
    @EnvironmentObject private var usage: DailyUsageLimiter
    @Environment(\.dismiss) private var dismiss

    let requestID: UUID

    @State private var request: SharedClipRequest?
    @State private var events: [AnalysisProgressEvent] = []
    @State private var isAnalyzing = false
    @State private var analysisStartedAt = Date()
    @State private var errorTitle = "Analysis failed"
    @State private var errorMessage: String?
    @State private var runToken = UUID()

    private var currentEvent: AnalysisProgressEvent {
        events.last ?? AnalysisProgressEvent(
            kind: .requestRead,
            title: "Reading shared clip",
            detail: "Preparing the link for analysis"
        )
    }

    var body: some View {
        ZStack {
            CinematicBackground()
            ScrollView {
                VStack(spacing: 22) {
                    AnalysisVisual(
                        event: currentEvent,
                        startedAt: analysisStartedAt,
                        isAnalyzing: isAnalyzing
                    )

                    AnalysisEventTimeline(events: events, isAnalyzing: isAnalyzing)

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
        .task(id: runToken) { await runAnalysis() }
        .animation(.smooth(duration: 0.35), value: events)
    }

    private func retry() {
        runToken = UUID()
    }

    @MainActor
    private func runAnalysis() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        analysisStartedAt = Date()
        events = []
        errorMessage = nil

        guard usage.canStartAnalysis(hasPremium: subscription.hasPremiumAccess) else {
            isAnalyzing = false
            router.navigate(to: .paywall)
            return
        }

        do {
            let loaded = try model.store.loadRequest(id: requestID)
            request = loaded
            let result: ClipAnalysisResult
            if let service = model.identificationService as? ProgressReportingClipIdentificationService {
                result = try await service.identify(request: loaded) { event in
                    Task { @MainActor in
                        guard isAnalyzing else { return }
                        events.append(event)
                    }
                }
            } else {
                result = try await model.identificationService.identify(request: loaded)
            }
            try Task.checkCancellation()
            model.record(result)
            usage.recordSuccessfulIdentification(hasPremium: subscription.hasPremiumAccess)
            router.resultsByID[result.id] = result
            isAnalyzing = false
            router.finishAnalysis(requestID: requestID, resultID: result.id)
        } catch is CancellationError {
            isAnalyzing = false
        } catch {
            isAnalyzing = false
            errorTitle = (error as? SceneFindError)?.failureTitle ?? "Analysis failed"
            errorMessage = error.localizedDescription
        }
    }
}

private struct AnalysisVisual: View {
    let event: AnalysisProgressEvent
    let startedAt: Date
    let isAnalyzing: Bool

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 5)
                if isAnalyzing {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.sceneCyan)
                }
                Image(systemName: event.kind.symbolName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isAnalyzing ? Color.sceneCyan : Color.sceneGreen)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 8) {
                Text(event.title)
                    .font(.title3.bold())
                    .contentTransition(.opacity)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 4)

            if isAnalyzing {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsedLabel(at: context.date))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color.sceneSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke((isAnalyzing ? Color.sceneCyan : Color.sceneGreen).opacity(0.2), lineWidth: 1)
        }
    }

    private func elapsedLabel(at date: Date) -> String {
        "\(max(0, Int(date.timeIntervalSince(startedAt))))s"
    }
}

private struct AnalysisEventTimeline: View {
    let events: [AnalysisProgressEvent]
    let isAnalyzing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Image(systemName: index == events.count - 1 && isAnalyzing
                              ? event.kind.symbolName : "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(index == events.count - 1 && isAnalyzing ? Color.sceneCyan : Color.sceneGreen)
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        if index < events.count - 1 {
                            Rectangle()
                                .fill(Color.sceneGreen.opacity(0.35))
                                .frame(width: 2, height: 28)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title)
                            .font(.subheadline.weight(.semibold))
                        if let detail = event.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(String(format: "%.1fs", event.elapsedSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .background(Color.sceneSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        }
    }
}

private extension AnalysisProgressKind {
    var symbolName: String {
        switch self {
        case .requestRead: "link"
        case .metadataRetrieved: "doc.text.magnifyingglass"
        case .mediaRetrieved: "video.fill"
        case .mediaAnalysisStarted: "waveform"
        case .dialogueDetected: "captions.bubble.fill"
        case .showIdentified: "tv.fill"
        case .episodeCandidatesFound: "list.bullet.rectangle"
        case .episodeVerified: "checkmark.seal.fill"
        case .episodeUnverified: "questionmark.diamond.fill"
        case .providersChecked: "play.tv.fill"
        case .artworkRetrieved: "photo.fill"
        case .completed: "checkmark.circle.fill"
        }
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
