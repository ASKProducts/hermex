import XCTest
import SwiftUI
import Observation
@testable import HermesMobile

@MainActor final class ApprovalSummaryTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connectionID = UUID()

    private func key(chat: String = "chat-a", approval: String = "approval-1") -> ApprovalSummaries.Key {
        .init(scope: .init(server: server, connectionID: connectionID,
                           conversation: .session(profile: "default", key: chat)), request: .approval(approval))
    }

    func testAnOnSwitchLoadsTheSummaryAndAFailureQuietlyEndsIt() async throws {
        let summaries = ApprovalSummaries(), key = key()
        let started = expectation(description: "model request started")
        var reply: CheckedContinuation<String, Error>?
        let presentation = ApprovalSummaryPresentation(key: key, summaries: summaries) {
            try await withCheckedThrowingContinuation { reply = $0; started.fulfill() }
        }
        let view = ApprovalRequestOverlay(content: content, isResponding: false, errorMessage: nil,
                                          onChoice: { _ in }, onSkipAll: {}, summary: presentation)
        let window = try await host(view.defaultAppStorage(appStorage(explains: true)))
        defer { close(window) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(summaries.states[key], .loading)
        let ended = expectation(description: "failed summary ended")
        withObservationTracking { _ = summaries.states[key] } onChange: { ended.fulfill() }
        reply?.resume(throwing: BotFailure.transport)
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(summaries.states[key], .unavailable)
    }

    func testTheSwitchIsOffByDefaultSoTheCardIsUnchangedAndNeverAsksTheModel() async throws {
        let summaries = ApprovalSummaries(), key = key()
        var calls = 0
        let presentation = ApprovalSummaryPresentation(key: key, summaries: summaries) { calls += 1; return "Not shown" }
        let view = ApprovalRequestOverlay(content: content, isResponding: false, errorMessage: nil,
                                          onChoice: { _ in }, onSkipAll: {}, summary: presentation)
        let window = try await host(view.defaultAppStorage(appStorage(explains: nil)))
        defer { close(window) }
        await settle(window)
        assertRawCommand(in: view)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(summaries.states[key])
    }

    func testTheSharedBotCardAsksForTheSameExplanation() async throws {
        let summaries = ApprovalSummaries(), key = key()
        let approval = try XCTUnwrap(BotApprovalRequest(.object([
            "request_id": .string("fixture-approval"), "command": .string("rm ./draft.txt"),
            "description": .string("Deletes a file"), "choices": .array([.string("once"), .string("deny")])
        ])))
        let loaded = expectation(description: "the Bot card asked for its summary")
        let presentation = ApprovalSummaryPresentation(key: key, summaries: summaries) {
            loaded.fulfill(); return "Removes the draft file."
        }
        let view = BotPendingRequestCard(request: .approval(approval), identity: "Fixture bot · Local test host",
            isEnabled: true, canStop: true, isAnswering: false, resolution: nil,
            onApprove: { _ in }, onAnswer: { _ in }, onSkip: {}, onCredential: { _ in }, onStop: {}, onConnection: { _ in },
            summary: presentation)
        let window = try await host(view.defaultAppStorage(appStorage(explains: true)))
        defer { close(window) }
        await fulfillment(of: [loaded], timeout: 2)
    }

    func testACardThatLeavesAndReturnsWhileLoadingKeepsItsOneRequest() async throws {
        let summaries = ApprovalSummaries(), key = key()
        let started = expectation(description: "summary started")
        var calls = 0
        var reply: CheckedContinuation<String, Never>?
        let presentation = ApprovalSummaryPresentation(key: key, summaries: summaries) {
            calls += 1
            return await withCheckedContinuation { reply = $0; started.fulfill() }
        }
        let presence = CardPresence()
        let overlay = ApprovalRequestOverlay(content: content, isResponding: false, errorMessage: nil,
                                             onChoice: { _ in }, onSkipAll: {}, summary: presentation)
        let window = try await host(PresenceHarness(presence: presence, card: overlay)
            .defaultAppStorage(appStorage(explains: true)))
        defer { close(window) }
        await fulfillment(of: [started], timeout: 2)
        // A question outranks the approval, then is answered and the approval returns.
        presence.isShown = false
        await settle(window)
        XCTAssertEqual(summaries.states[key], .loading, "leaving the screen isn't answering")
        presence.isShown = true
        await settle(window)
        let ready = expectation(description: "the returned card's summary arrived")
        withObservationTracking { _ = summaries.states[key] } onChange: { ready.fulfill() }
        reply?.resume(returning: "Removes the draft file.")
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(summaries.states[key], .ready("Removes the draft file."))
        XCTAssertEqual(calls, 1)
    }

    func testTurningTheGlobalSwitchOffCancelsTheVisibleCardsRequest() async throws {
        let summaries = ApprovalSummaries(), key = key()
        let defaults = try appStorage(explains: true)
        let started = expectation(description: "summary started")
        let cancelled = expectation(description: "turning off cancelled the actual load")
        var reply: CheckedContinuation<String, Never>?
        let presentation = ApprovalSummaryPresentation(key: key, summaries: summaries) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { reply = $0; started.fulfill() }
            } onCancel: { cancelled.fulfill() }
        }
        let view = ApprovalRequestOverlay(content: content, isResponding: false, errorMessage: nil,
            onChoice: { _ in }, onSkipAll: {}, summary: presentation).defaultAppStorage(defaults)
        let window = try await host(view)
        defer { close(window) }
        await fulfillment(of: [started], timeout: 2)
        defaults.set(false, forKey: ApprovalSummaries.enabledKey)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(summaries.states[key], .unavailable)
        reply?.resume(returning: "A late explanation")
        await settle(window)
        XCTAssertEqual(summaries.states[key], .unavailable, "a late reply can't come back once the switch is off")
    }

    /// Inspect the Text emitted by the overlay's actual body, not the input model.
    /// No private SwiftUI field names are used.
    private func assertRawCommand(in view: ApprovalRequestOverlay, file: StaticString = #filePath, line: UInt = #line) {
        let command = Text(verbatim: "rm ./draft.txt").font(.system(.footnote, design: .monospaced))
        func containsCommand(_ value: Any) -> Bool {
            if let text = value as? Text { return text == command }
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle != .class else { return false }
            return mirror.children.contains { containsCommand($0.value) }
        }
        XCTAssertTrue(containsCommand(view.body), "The card must contain the exact raw command Text", file: file, line: line)
    }

    private var content: ApprovalOverlayContent {
        .init(description: "Deletes a file", command: "rm ./draft.txt", scopeLine: nil,
              pendingCount: 1, choices: [.once, .deny])
    }

    /// A fresh defaults suite for the switch; `nil` leaves it at its shipped default.
    private func appStorage(explains: Bool?) throws -> UserDefaults {
        let suite = "approval-summary-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        if let explains { defaults.set(explains, forKey: ApprovalSummaries.enabledKey) }
        return defaults
    }

    private func host<V: View>(_ view: V) async throws -> UIWindow {
        let appeared = expectation(description: "real card appeared")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view.onAppear { appeared.fulfill() })
        window.makeKeyAndVisible()
        await fulfillment(of: [appeared], timeout: 5)
        window.layoutIfNeeded()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    func testAnOldReplyCannotTakeOverAReusedApprovalIDAfterItWasRemoved() async {
        let summaries = ApprovalSummaries(), key = key()
        let oldStarted = expectation(description: "old request started")
        var oldReply: CheckedContinuation<String, Never>?
        let old = Task {
            await summaries.show(key) { await withCheckedContinuation { oldReply = $0; oldStarted.fulfill() } }
        }
        await fulfillment(of: [oldStarted], timeout: 2)
        summaries.retain([], in: key.scope)
        let newStarted = expectation(description: "new approval started")
        var newReply: CheckedContinuation<String, Never>?
        let new = Task {
            await summaries.show(key) { await withCheckedContinuation { newReply = $0; newStarted.fulfill() } }
        }
        await fulfillment(of: [newStarted], timeout: 2)
        oldReply?.resume(returning: "Old command")
        await old.value
        XCTAssertEqual(summaries.states[key], .loading, "an ended request cannot settle a new lifetime")
        newReply?.resume(returning: "New command")
        await new.value
        XCTAssertEqual(summaries.states[key], .ready("New command"))
    }

    func testAnsweringCancelsUnfinishedWorkAndRejectsItsLateResult() async {
        let summaries = ApprovalSummaries(), key = key()
        let started = expectation(description: "model request started")
        var reply: CheckedContinuation<String, Never>?
        var cancelled = false
        let show = Task {
            await summaries.show(key) {
                let text = await withCheckedContinuation { reply = $0; started.fulfill() }
                cancelled = Task.isCancelled
                return text
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(summaries.states[key], .loading)
        summaries.cancel(key)
        XCTAssertEqual(summaries.states[key], .unavailable)
        reply?.resume(returning: "Late summary")
        await show.value
        XCTAssertTrue(cancelled, "the actual in-flight load must be cancelled")
        XCTAssertEqual(summaries.states[key], .unavailable)
    }

    func testOnlyAnAuthoritativePendingSetDropsTheResultForThatConversation() async {
        let summaries = ApprovalSummaries(), first = key(), second = key(chat: "chat-b")
        await summaries.show(first) { "First" }
        await summaries.show(second) { "Second" }
        summaries.retain([], in: first.scope)
        XCTAssertNil(summaries.states[first])
        XCTAssertEqual(summaries.states[second], .ready("Second"))
    }

    func testAFailedRequestLeavesNoSummaryAndIsNotRetriedOnReturn() async {
        let summaries = ApprovalSummaries(), key = key()
        await summaries.show(key) { throw BotFailure.transport }
        XCTAssertEqual(summaries.states[key], .unavailable)
        var retried = false
        await summaries.show(key) { retried = true; return "Retry" }
        XCTAssertFalse(retried)
        XCTAssertEqual(summaries.states[key], .unavailable)
    }

    func testACompletedExplanationIsShownWhenTheCardReturnsWithoutAnotherRequest() async {
        let summaries = ApprovalSummaries(), key = key()
        var calls = 0
        await summaries.show(key) { calls += 1; return "Removes the draft file." }
        XCTAssertEqual(summaries.states[key], .ready("Removes the draft file."))
        await summaries.show(key) { calls += 1; return "A second explanation." }
        XCTAssertEqual(summaries.states[key], .ready("Removes the draft file."))
        XCTAssertEqual(calls, 1)
    }
}

@Observable private final class CardPresence { var isShown = true }

/// Mounts and unmounts a card the way a higher-priority request replaces it on screen.
private struct PresenceHarness<Card: View>: View {
    let presence: CardPresence
    let card: Card

    var body: some View {
        ZStack { if presence.isShown { card } }
    }
}
