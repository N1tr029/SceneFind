import Foundation
import SwiftUI
import UIKit

/// Owns in-flight clip analyses for the whole app.
///
/// Analysis used to live in `AnalyzeView.task(id:)`, which ties the work to the
/// view's lifetime: switching tabs, backgrounding the app, or navigating away
/// cancelled the run and the user came back to nothing. The work belongs to the
/// app, not to a screen, so it lives here — the view only observes.
///
/// Each run also holds a `UIApplication` background task assertion, which is
/// what keeps the network requests alive for the ~30s iOS grants after the app
/// leaves the foreground.
@MainActor
final class AnalysisCoordinator: ObservableObject {
    enum State: Equatable {
        case running
        case finished(resultID: UUID)
        case failed(title: String, message: String)
    }

    struct Run: Equatable {
        var events: [AnalysisProgressEvent]
        var startedAt: Date
        var state: State

        var isRunning: Bool { state == .running }
    }

    @Published private(set) var runs: [UUID: Run] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let model: SceneFindModel
    private let usage: DailyUsageLimiter
    private let subscription: SubscriptionManager

    init(model: SceneFindModel, usage: DailyUsageLimiter, subscription: SubscriptionManager) {
        self.model = model
        self.usage = usage
        self.subscription = subscription
    }

    func run(for requestID: UUID) -> Run? { runs[requestID] }

    /// Starts analysis unless this request is already running or already done.
    /// Safe to call from `onAppear` — re-entering the screen reattaches to the
    /// existing run instead of starting a second one.
    func startIfNeeded(requestID: UUID) {
        guard tasks[requestID] == nil else { return }
        if case .finished = runs[requestID]?.state { return }
        start(requestID: requestID)
    }

    func retry(requestID: UUID) {
        tasks[requestID]?.cancel()
        tasks[requestID] = nil
        start(requestID: requestID)
    }

    func cancel(requestID: UUID) {
        tasks[requestID]?.cancel()
        tasks[requestID] = nil
        runs[requestID] = nil
    }

    private func start(requestID: UUID) {
        guard usage.canStartAnalysis(hasPremium: subscription.hasPremiumAccess) else {
            runs[requestID] = Run(
                events: [],
                startedAt: Date(),
                state: .failed(
                    title: "Daily limit reached",
                    message: "You have used today's free identifications."
                )
            )
            return
        }

        runs[requestID] = Run(events: [], startedAt: Date(), state: .running)

        tasks[requestID] = Task { [weak self] in
            // Ask iOS to keep us alive if the user leaves mid-analysis; without
            // this the app is suspended and the in-flight requests stall.
            //
            // The expiration handler is not optional in practice: iOS terminates
            // an app that lets an assertion run out without ending it, so this
            // gives back the assertion (and stops the work) at the deadline.
            var assertion = UIBackgroundTaskIdentifier.invalid
            assertion = UIApplication.shared.beginBackgroundTask(
                withName: "SceneFind clip analysis"
            ) { [weak self] in
                self?.expireRun(requestID: requestID, assertion: assertion)
            }
            defer {
                if assertion != .invalid {
                    UIApplication.shared.endBackgroundTask(assertion)
                }
            }
            await self?.perform(requestID: requestID)
        }
    }

    /// iOS reclaimed our background time before the analysis finished.
    private func expireRun(requestID: UUID, assertion: UIBackgroundTaskIdentifier) {
        tasks[requestID]?.cancel()
        tasks[requestID] = nil
        if runs[requestID]?.isRunning == true {
            runs[requestID]?.state = .failed(
                title: "Analysis paused",
                message: "iOS stopped SceneFind before the clip finished analyzing. "
                    + "Reopen the app and tap Try again."
            )
        }
        if assertion != .invalid {
            UIApplication.shared.endBackgroundTask(assertion)
        }
    }

    private func perform(requestID: UUID) async {
        let service = model.identificationService
        do {
            let request = try model.store.loadRequest(id: requestID)
            let result: ClipAnalysisResult
            if let reporting = service as? ProgressReportingClipIdentificationService {
                result = try await reporting.identify(request: request) { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.append(event, to: requestID)
                    }
                }
            } else {
                result = try await service.identify(request: request)
            }
            try Task.checkCancellation()
            model.record(result)
            usage.recordSuccessfulIdentification(hasPremium: subscription.hasPremiumAccess)
            finish(requestID: requestID, result: result)
        } catch is CancellationError {
            runs[requestID] = nil
        } catch {
            runs[requestID]?.state = .failed(
                title: (error as? SceneFindError)?.failureTitle ?? "Analysis failed",
                message: error.localizedDescription
            )
        }
        tasks[requestID] = nil
    }

    private func append(_ event: AnalysisProgressEvent, to requestID: UUID) {
        guard runs[requestID]?.isRunning == true else { return }
        runs[requestID]?.events.append(event)
    }

    private func finish(requestID: UUID, result: ClipAnalysisResult) {
        runs[requestID]?.state = .finished(resultID: result.id)
        NotificationCenter.default.post(
            name: .analysisDidFinish,
            object: nil,
            userInfo: ["requestID": requestID, "resultID": result.id]
        )
    }
}

extension Notification.Name {
    static let analysisDidFinish = Notification.Name("SceneFindAnalysisDidFinish")
}
