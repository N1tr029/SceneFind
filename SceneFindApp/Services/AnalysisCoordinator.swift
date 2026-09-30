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

    /// One attempt at one request.
    ///
    /// Cancelling a `Task` does not stop it there and then — it resumes later,
    /// on this actor, after the retry that cancelled it has already started a
    /// replacement. Keyed by request alone, that late resume cleared the *new*
    /// attempt's task handle and run state: the finished result then had
    /// nowhere to land, `AnalyzeView` never saw `.finished`, and the user was
    /// left on a spinner for an analysis that had completed and been charged.
    /// The generation is what lets a superseded attempt recognise that these
    /// entries are no longer its own.
    private struct RunKey: Hashable {
        let requestID: UUID
        let generation: Int
    }

    private var generations: [UUID: Int] = [:]
    private var tasks: [RunKey: Task<Void, Never>] = [:]
    private var assertions: [RunKey: UIBackgroundTaskIdentifier] = [:]
    private let model: SceneFindModel
    private let subscription: SubscriptionManager

    init(model: SceneFindModel, subscription: SubscriptionManager) {
        self.model = model
        self.subscription = subscription
    }

    func run(for requestID: UUID) -> Run? { runs[requestID] }

    /// Starts analysis unless this request is already running or already done.
    /// Safe to call from `onAppear` — re-entering the screen reattaches to the
    /// existing run instead of starting a second one.
    func startIfNeeded(requestID: UUID) {
        guard currentTask(for: requestID) == nil else { return }
        if case .finished = runs[requestID]?.state { return }
        start(requestID: requestID)
    }

    func retry(requestID: UUID) {
        cancelCurrent(requestID: requestID)
        start(requestID: requestID)
    }

    func cancel(requestID: UUID) {
        cancelCurrent(requestID: requestID)
        runs[requestID] = nil
    }

    private func currentTask(for requestID: UUID) -> Task<Void, Never>? {
        guard let key = currentKey(for: requestID) else { return nil }
        return tasks[key]
    }

    private func currentKey(for requestID: UUID) -> RunKey? {
        guard let generation = generations[requestID] else { return nil }
        return RunKey(requestID: requestID, generation: generation)
    }

    private func isCurrent(_ key: RunKey) -> Bool {
        generations[key.requestID] == key.generation
    }

    private func cancelCurrent(requestID: UUID) {
        guard let key = currentKey(for: requestID) else { return }
        tasks.removeValue(forKey: key)?.cancel()
    }

    private func start(requestID: UUID) {
        let generation = (generations[requestID] ?? 0) + 1
        generations[requestID] = generation
        let key = RunKey(requestID: requestID, generation: generation)
        runs[requestID] = Run(events: [], startedAt: Date(), state: .running)

        tasks[key] = Task { [weak self] in
            // Ask iOS to keep us alive if the user leaves mid-analysis; without
            // this the app is suspended and the in-flight requests stall.
            //
            // The expiration handler is not optional in practice: iOS terminates
            // an app that lets an assertion run out without ending it, so this
            // gives back the assertion (and stops the work) at the deadline.
            self?.beginAssertion(for: key)
            defer { self?.endAssertion(for: key) }
            await self?.perform(key: key)
        }
    }

    // MARK: - Background assertions
    //
    // Held in one place, keyed by attempt, because both the normal finish and
    // the expiration handler want to release it. `endBackgroundTask` must be
    // called exactly once per identifier — calling it twice is a programmer
    // error that UIKit treats as fatal — so clearing the entry here is what
    // makes the second caller a no-op. Keying by attempt rather than by request
    // is what stops a superseded run's `defer` from handing back the assertion
    // its replacement is relying on.

    private func beginAssertion(for key: RunKey) {
        guard assertions[key] == nil else { return }
        let assertion = UIApplication.shared.beginBackgroundTask(
            withName: "SceneFind clip analysis"
        ) { [weak self] in
            self?.expireRun(key: key)
        }
        guard assertion != .invalid else { return }
        assertions[key] = assertion
    }

    private func endAssertion(for key: RunKey) {
        guard let assertion = assertions.removeValue(forKey: key) else { return }
        UIApplication.shared.endBackgroundTask(assertion)
    }

    /// iOS reclaimed our background time before the analysis finished.
    private func expireRun(key: RunKey) {
        tasks.removeValue(forKey: key)?.cancel()
        if isCurrent(key), runs[key.requestID]?.isRunning == true {
            runs[key.requestID]?.state = .failed(
                title: "Analysis paused",
                message: "iOS stopped SceneFind before the clip finished analyzing. "
                    + "Reopen the app and tap Try again."
            )
        }
        endAssertion(for: key)
    }

    private func perform(key: RunKey) async {
        let requestID = key.requestID
        let service = model.identificationService
        do {
            let request = try model.store.loadRequest(id: requestID)
            let result: ClipAnalysisResult
            if let reporting = service as? ProgressReportingClipIdentificationService {
                result = try await reporting.identify(request: request) { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.append(event, to: key)
                    }
                }
            } else {
                result = try await service.identify(request: request)
            }
            try Task.checkCancellation()
            // Recorded even if a retry has taken over: the analysis ran and was
            // charged, so the result belongs in the library either way. Only the
            // on-screen run state is left to whichever attempt is current.
            model.record(result)
            await subscription.refreshEntitlement()
            if isCurrent(key) { finish(requestID: requestID, result: result) }
        } catch is CancellationError {
            // Only clear a run this attempt still owns, and only while it is
            // still running: `expireRun` cancels *after* posting its "Analysis
            // paused" message, which must survive.
            if isCurrent(key), runs[requestID]?.isRunning == true {
                runs[requestID] = nil
            }
        } catch {
            if isCurrent(key) {
                runs[requestID]?.state = .failed(
                    title: (error as? SceneFindError)?.failureTitle ?? "Analysis failed",
                    message: error.localizedDescription
                )
            }
            // A failed run releases its held credit on the server, so the
            // allowance on screen is now stale. Refreshing in a separate task
            // keeps a quick "Try again" from racing this one's cleanup.
            let subscription = subscription
            Task { await subscription.refreshEntitlement() }
        }
        tasks[key] = nil
    }

    private func append(_ event: AnalysisProgressEvent, to key: RunKey) {
        guard isCurrent(key), runs[key.requestID]?.isRunning == true else { return }
        runs[key.requestID]?.events.append(event)
    }

    private func finish(requestID: UUID, result: ClipAnalysisResult) {
        runs[requestID]?.state = .finished(resultID: result.id)
    }
}
