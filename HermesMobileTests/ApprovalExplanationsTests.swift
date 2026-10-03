import XCTest
@testable import HermesMobile

/// The plain-words explanation on approval cards: one request per approval on screen,
/// cached for the approval's life, cancelled when it is answered, expires, is cleared or
/// its chat or server changes, and a quiet failure on an error or the gateway's timeout.
@MainActor final class ApprovalExplanationsTests: XCTestCase {
    /// Records each request and lets the test answer it.
    @MainActor private final class ScriptedExplainer {
        var inputs: [String] = []
        var continuations: [CheckedContinuation<String, Error>] = []
        var onRequest: (() -> Void)?
        var onCancel: (() -> Void)?
        /// Runs on the main actor after the caller's code that follows the returned request
        /// (the write or the discard), because it is queued behind it.
        var afterReturn: (() -> Void)?

        func explain(_ input: String) async throws -> String {
            inputs.append(input)
            onRequest?()
            defer { Task { @MainActor in self.afterReturn?() } }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuations.append($0) }
            } onCancel: {
                Task { @MainActor in self.onCancel?() }
            }
        }

        func answer(_ index: Int, with result: Result<String, Error>) {
            continuations[index].resume(with: result)
        }
    }

    /// Answers request `index` late and waits until the caller has handled the reply.
    private func answerLate(_ index: Int, _ explainer: ScriptedExplainer) async {
        let handled = expectation(description: "late reply handled")
        explainer.afterReturn = { handled.fulfill() }
        explainer.answer(index, with: .success("Late."))
        await fulfillment(of: [handled], timeout: 2)
        explainer.afterReturn = nil
    }

    private let scope = "chat|one"
    private func key(_ id: String, scope: String? = nil) -> ApprovalExplanations.Key {
        .init(scope: scope ?? self.scope, approvalID: id)
    }

    private final class Tally<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func makeExplanations(_ explainer: ScriptedExplainer, releases: Tally<Int>? = nil)
        -> ApprovalExplanations {
        ApprovalExplanations(explain: { try await explainer.explain($0) }, release: { releases?.value += 1 })
    }

    /// Waits until `explanations` publishes `expected` for `key`.
    private func waitForState(_ expected: ApprovalExplanations.State?, of key: ApprovalExplanations.Key,
                              in explanations: ApprovalExplanations, file: StaticString = #filePath, line: UInt = #line) async {
        let reached = expectation(description: "state \(String(describing: expected))")
        func observe() {
            withObservationTracking { _ = explanations.states[key] } onChange: {
                Task { @MainActor in
                    if explanations.states[key] == expected { reached.fulfill() } else { observe() }
                }
            }
        }
        if explanations.states[key] == expected { reached.fulfill() } else { observe() }
        await fulfillment(of: [reached], timeout: 2)
    }

    private func waitForRequests(_ count: Int, _ explainer: ScriptedExplainer) async {
        guard explainer.inputs.count < count else { return }
        let sent = expectation(description: "\(count) requests")
        explainer.onRequest = { if explainer.inputs.count == count { sent.fulfill() } }
        await fulfillment(of: [sent], timeout: 2)
        explainer.onRequest = nil
    }

    func testInputNamesTheFlagTheCommandAndTheWorkingDirectory() {
        XCTAssertEqual(
            ApprovalExplanations.input(description: " recursive delete ", command: "rm -rf build", workingDirectory: "/repo"),
            "Why it was flagged: recursive delete\nCommand: rm -rf build\nWorking directory: /repo"
        )
        XCTAssertEqual(ApprovalExplanations.input(description: nil, command: "ls", workingDirectory: " "), "Command: ls")
        XCTAssertNil(ApprovalExplanations.input(description: "script", command: "  ", workingDirectory: "/repo"),
                     "Nothing to explain without a command, so no area is drawn")
    }

    func testTheCardDrawsTheSpinnerBeforeAnyRequestAndTheTextWhenItArrives() async throws {
        let explainer = ScriptedExplainer()
        let explanations = makeExplanations(explainer)
        let input = "Command: rm -rf build"
        XCTAssertEqual(explanations.state(for: key("a"), input: input), .loading, "The card never waits for the request")
        XCTAssertNil(explanations.state(for: key("a"), input: nil))

        explanations.show(key("a"), input: input)
        await waitForRequests(1, explainer)
        XCTAssertEqual(explainer.inputs, [input])
        explainer.answer(0, with: .success("  Deletes the build folder.\n"))
        await waitForState(.ready("Deletes the build folder."), of: key("a"), in: explanations)
    }

    func testReopeningBeforeApprovalSnapshotKeepsCompletedSummary() async throws {
        let explainer = ScriptedExplainer(), explanations = makeExplanations(explainer)
        explanations.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)
        explainer.answer(0, with: .success("A."))
        await waitForState(.ready("A."), of: key("a"), in: explanations)
        explanations.leave(scope: scope)
        // Both freshly constructed destinations have no authoritative pending snapshot yet.
        explanations.retain(nil, inScope: scope, pending: nil)
        XCTAssertEqual(explanations.states[key("a")], .ready("A."))
        explanations.retain(key("a"), inScope: scope, pending: [key("a")])
        XCTAssertEqual(explanations.states[key("a")], .ready("A."))
        XCTAssertEqual(explainer.inputs.count, 1)
        // An actual server-confirmed empty snapshot does end the approval lifetime.
        explanations.retain(nil, inScope: scope, pending: [])
        XCTAssertNil(explanations.states[key("a")])
    }

    func testOneRequestPerApprovalAndTheResultIsCachedForItsLife() async throws {
        // Authoritative sets are explicit; absence of a snapshot never ends a lifetime.
        let explainer = ScriptedExplainer()
        let explanations = makeExplanations(explainer)
        explanations.show(key("a"), input: "Command: a")
        explanations.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)
        explainer.answer(0, with: .success("A."))
        await waitForState(.ready("A."), of: key("a"), in: explanations)

        // Re-shown (the chat re-rendered, or the user came back): no second request.
        explanations.retain(key("a"), inScope: scope, pending: [key("a")])
        explanations.show(key("a"), input: "Command: a")
        explanations.leave(scope: scope)
        explanations.show(key("a"), input: "Command: a")
        XCTAssertEqual(explainer.inputs.count, 1)
        XCTAssertEqual(explanations.states[key("a")], .ready("A."))
    }

    func testAnErrorShowsTheQuietFailureAndIsNotRetried() async throws {
        let explainer = ScriptedExplainer()
        let explanations = makeExplanations(explainer)
        explanations.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)
        explainer.answer(0, with: .failure(BotFailure.rejected(5030)))
        await waitForState(.failed, of: key("a"), in: explanations)
        explanations.show(key("a"), input: "Command: a")
        XCTAssertEqual(explainer.inputs.count, 1, "No automatic retry")
    }

    /// The gateway fails an unanswered `llm.oneshot` with `.transport` at its deadline
    /// (`BotClientTests.testApprovalExplanationTimeoutFailsOnlyThatRequest`); that reads
    /// as the same quiet failure, and an empty reply does too.
    func testTheGatewayTimeoutAndAnEmptyReplyShowTheQuietFailure() async throws {
        let explainer = ScriptedExplainer()
        let explanations = makeExplanations(explainer)
        explanations.show(key("a"), input: "Command: a")
        explanations.show(key("b"), input: "Command: b")
        await waitForRequests(2, explainer)
        explainer.answer(0, with: .failure(BotFailure.transport))
        explainer.answer(1, with: .success("  "))
        await waitForState(.failed, of: key("a"), in: explanations)
        await waitForState(.failed, of: key("b"), in: explanations)
        XCTAssertEqual(ApprovalExplanations.deadline, .seconds(20))
    }

    func testAnsweringBeforeTheReplyCancelsTheRequestAndWritesNothing() async throws {
        let explainer = ScriptedExplainer()
        let releases = Tally(0)
        let explanations = makeExplanations(explainer, releases: releases)
        explanations.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)
        let cancelled = expectation(description: "request task cancelled")
        explainer.onCancel = { cancelled.fulfill() }

        // Answered or expired: the chat has no approval on screen any more.
        explanations.retain(nil, inScope: scope, pending: [])
        XCTAssertNil(explanations.states[key("a")])
        XCTAssertEqual(explanations.inFlightCount, 0)
        XCTAssertEqual(releases.value, 1, "The socket is released once nothing is in flight")
        await fulfillment(of: [cancelled], timeout: 2)
        await answerLate(0, explainer)
        XCTAssertNil(explanations.states[key("a")], "A late reply is never written")
    }

    func testOnlyTheApprovalOnScreenIsExplainedAndANewOneNeverGetsTheOldResult() async throws {
        let explainer = ScriptedExplainer()
        let explanations = makeExplanations(explainer)
        explanations.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)

        // "Pending approvals: 2": the first is answered and the second comes to the front.
        explanations.retain(key("b"), inScope: scope, pending: [key("b")])
        explanations.show(key("b"), input: "Command: b")
        await waitForRequests(2, explainer)
        explainer.answer(0, with: .success("About a."))
        explainer.answer(1, with: .success("About b."))
        await waitForState(.ready("About b."), of: key("b"), in: explanations)
        XCTAssertNil(explanations.states[key("a")])
        XCTAssertEqual(explainer.inputs, ["Command: a", "Command: b"])
    }

    func testQuestionCoveringAPendingApprovalKeepsItsCompletedSummary() async throws {
        let explainer = ScriptedExplainer(), explanations = makeExplanations(explainer)
        explanations.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)
        explainer.answer(0, with: .success("About a."))
        await waitForState(.ready("About a."), of: key("a"), in: explanations)
        explanations.retain(nil, inScope: scope, pending: [key("a")])
        explanations.retain(key("a"), inScope: scope, pending: [key("a")])
        explanations.show(key("a"), input: "Command: a")
        XCTAssertEqual(explanations.states[key("a")], .ready("About a."))
        XCTAssertEqual(explainer.inputs.count, 1)
        explanations.retain(nil, inScope: scope, pending: [])
        XCTAssertNil(explanations.states[key("a")], "Only resolution ends approval lifetime")
    }

    func testQuestionCoveringAnUnfinishedApprovalCancelsWithoutRetry() async throws {
        let explainer = ScriptedExplainer(), explanations = makeExplanations(explainer)
        explanations.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)
        explanations.retain(nil, inScope: scope, pending: [key("a")])
        await answerLate(0, explainer)
        explanations.retain(nil, inScope: scope, pending: nil)
        XCTAssertEqual(explanations.states[key("a")], .failed)
        explanations.retain(key("a"), inScope: scope, pending: [key("a")])
        explanations.show(key("a"), input: "Command: a")
        XCTAssertEqual(explanations.states[key("a")], .failed)
        XCTAssertEqual(explanations.inFlightCount, 0)
        XCTAssertEqual(explainer.inputs.count, 1)
    }

    func testDeadlineCancelsTheWholeExplanationAndNeverRetries() async throws {
        let explainer = ScriptedExplainer()
        let armed = expectation(description: "deadline armed")
        var expire: CheckedContinuation<Void, Error>?
        let explanations = ApprovalExplanations(explain: { try await explainer.explain($0) }, waitForDeadline: {
            try await withCheckedThrowingContinuation { expire = $0; armed.fulfill() }
        })
        explanations.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)
        await fulfillment(of: [armed], timeout: 2)
        expire?.resume()
        await waitForState(.failed, of: key("a"), in: explanations)
        await answerLate(0, explainer)
        explanations.show(key("a"), input: "Command: a")
        XCTAssertEqual(explainer.inputs.count, 1)
        XCTAssertEqual(explanations.inFlightCount, 0)
        XCTAssertEqual(explanations.states[key("a")], .failed)
    }

    func testEqualApprovalIdsInTwoChatsAreSeparate() async throws {
        let explainer = ScriptedExplainer()
        let explanations = makeExplanations(explainer)
        let other = key("a", scope: "chat|two")
        explanations.show(key("a"), input: "Command: one")
        explanations.show(other, input: "Command: two")
        await waitForRequests(2, explainer)
        explainer.answer(1, with: .success("Two."))
        await waitForState(.ready("Two."), of: other, in: explanations)
        XCTAssertEqual(explanations.states[key("a")], .loading)

        // The first chat answers its approval; the second chat's result stays.
        explanations.retain(nil, inScope: scope, pending: [])
        XCTAssertEqual(explanations.states[other], .ready("Two."))
        await answerLate(0, explainer)
    }

    func testLeavingTheChatCancelsItsRequestAndNeverRetriesWhenBack() async throws {
        let explainer = ScriptedExplainer()
        let explanations = makeExplanations(explainer)
        explanations.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)
        explanations.leave(scope: scope)
        XCTAssertEqual(explanations.states[key("a")], .failed)
        await answerLate(0, explainer)
        XCTAssertEqual(explanations.states[key("a")], .failed)

        explanations.show(key("a"), input: "Command: a")
        XCTAssertEqual(explanations.inFlightCount, 0)
        XCTAssertEqual(explainer.inputs.count, 1)
        XCTAssertEqual(explanations.states[key("a")], .failed)
    }

    // MARK: - Per-server registry

    private func makeDefaults() -> UserDefaults {
        let name = "ApprovalExplanationsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func connection(_ name: String = "Hermes") -> BotConnection {
        BotConnection(id: UUID(), name: name, address: URL(string: "https://hermes.example")!, username: "user", password: "fixture")
    }

    private func makeRegistry(_ explainer: ScriptedExplainer, made: Tally<[URL]>? = nil) -> ApprovalExplanationRegistry {
        ApprovalExplanationRegistry(makeExplain: { _, server in
            made?.value.append(server)
            return ({ try await explainer.explain($0) }, {})
        })
    }

    func testNoHermesConnectionOrTheSettingOffMeansNoAreaAndNoRequest() throws {
        let server = URL(string: "https://webui.example")!
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let defaults = makeDefaults()
        let made = Tally<[URL]>([])
        let registry = makeRegistry(ScriptedExplainer(), made: made)

        registry.refresh(server: server, store: store, defaults: defaults)
        XCTAssertNil(registry.explanations(for: server), "No Hermes connection: the card is as before")

        try store.save(connection(), server: server)
        XCTAssertTrue(ApprovalExplanationSetting.isEnabled(server: server, defaults: defaults), "On by default")
        ApprovalExplanationSetting.setEnabled(false, server: server, defaults: defaults)
        registry.refresh(server: server, store: store, defaults: defaults)
        XCTAssertNil(registry.explanations(for: server), "Setting off: the card is as before")
        XCTAssertEqual(made.value, [], "No client is made, so nothing is ever sent")
    }

    func testCredentialAndHeaderEditsReplaceTheExplanationTransport() throws {
        let server = URL(string: "https://webui.example")!
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let defaults = makeDefaults(), made = Tally<[URL]>([])
        let registry = makeRegistry(ScriptedExplainer(), made: made)
        var saved = connection()
        try store.save(saved, server: server)
        registry.refresh(server: server, store: store, defaults: defaults)
        saved.headers = [CustomHeader(name: "X-Test", value: "fixture")]
        try store.save(saved, server: server)
        registry.refresh(server: server, store: store, defaults: defaults)
        XCTAssertEqual(made.value.count, 2, "Changed headers must not retain a retired client")
        saved.password = "updated-fixture"
        try store.save(saved, server: server)
        registry.refresh(server: server, store: store, defaults: defaults)
        XCTAssertEqual(made.value.count, 3, "Changed credentials must not retain a retired client")
    }

    func testSettingOffAndOnDoesNotRetryAPendingApproval() async throws {
        let server = URL(string: "https://webui.example")!
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let defaults = makeDefaults(), explainer = ScriptedExplainer()
        let registry = makeRegistry(explainer)
        try store.save(connection(), server: server)
        registry.refresh(server: server, store: store, defaults: defaults)
        let summaries = try XCTUnwrap(registry.explanations(for: server))
        summaries.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)
        ApprovalExplanationSetting.setEnabled(false, server: server, defaults: defaults)
        registry.refresh(server: server, store: store, defaults: defaults)
        XCTAssertNil(registry.explanations(for: server))
        await answerLate(0, explainer)
        ApprovalExplanationSetting.setEnabled(true, server: server, defaults: defaults)
        registry.refresh(server: server, store: store, defaults: defaults)
        XCTAssertTrue(registry.explanations(for: server) === summaries)
        summaries.show(key("a"), input: "Command: a")
        XCTAssertEqual(explainer.inputs.count, 1)
        XCTAssertEqual(summaries.states[key("a")], .failed)
    }

    func testTheSettingIsPerServer() throws {
        let one = URL(string: "https://one.example")!, two = URL(string: "https://two.example")!
        let defaults = makeDefaults()
        ApprovalExplanationSetting.setEnabled(false, server: one, defaults: defaults)
        XCTAssertFalse(ApprovalExplanationSetting.isEnabled(server: one, defaults: defaults))
        XCTAssertTrue(ApprovalExplanationSetting.isEnabled(server: two, defaults: defaults))
    }

    func testAServerOrConnectionChangeCancelsEverythingInFlight() async throws {
        let server = URL(string: "https://webui.example")!
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let defaults = makeDefaults()
        let explainer = ScriptedExplainer()
        let registry = makeRegistry(explainer)
        try store.save(connection("First"), server: server)
        registry.refresh(server: server, store: store, defaults: defaults)
        let first = try XCTUnwrap(registry.explanations(for: server))
        registry.refresh(server: server, store: store, defaults: defaults)
        XCTAssertTrue(registry.explanations(for: server) === first, "An unchanged connection keeps the cache")

        first.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)
        try store.save(connection("Replaced"), server: server)
        registry.refresh(server: server, store: store, defaults: defaults)
        XCTAssertTrue(registry.explanations(for: server) === first, "Transport changes retain approval lifetime state")
        XCTAssertEqual(first.inFlightCount, 0)
        XCTAssertEqual(first.states[key("a")], .failed)
        await answerLate(0, explainer)
        XCTAssertEqual(first.states[key("a")], .failed, "A reply for the old connection is never written")

        ApprovalExplanationSetting.setEnabled(false, server: server, defaults: defaults)
        registry.refresh(server: server, store: store, defaults: defaults)
        XCTAssertNil(registry.explanations(for: server))
    }

    func testSwitchingActiveServersCancelsTheOldServerAndLogoutClearsTheNewOne() async throws {
        let one = URL(string: "https://one.example")!, two = URL(string: "https://two.example")!
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let defaults = makeDefaults(), explainer = ScriptedExplainer()
        let registry = makeRegistry(explainer)
        try store.save(connection("One"), server: one)
        try store.save(connection("Two"), server: two)
        registry.refresh(server: one, store: store, defaults: defaults)
        let old = try XCTUnwrap(registry.explanations(for: one))
        old.show(key("a"), input: "Command: a")
        await waitForRequests(1, explainer)
        registry.activate(server: two)
        XCTAssertNil(registry.explanations(for: one))
        XCTAssertEqual(old.inFlightCount, 0)
        await answerLate(0, explainer)
        XCTAssertEqual(old.states[key("a")], .failed)
        registry.activate(server: one)
        registry.refresh(server: one, store: store, defaults: defaults)
        XCTAssertTrue(registry.explanations(for: one) === old)
        old.show(key("a"), input: "Command: a")
        XCTAssertEqual(explainer.inputs.count, 1, "Returning to a server cannot retry a pending approval")
        registry.activate(server: two)
        registry.refresh(server: two, store: store, defaults: defaults)
        let current = try XCTUnwrap(registry.explanations(for: two))
        current.show(key("b"), input: "Command: b")
        await waitForRequests(2, explainer)
        registry.activate(server: nil)
        XCTAssertEqual(current.inFlightCount, 0)
        XCTAssertNil(registry.explanations(for: two))
        await answerLate(1, explainer)
        XCTAssertNil(current.states[key("b")])
    }

    /// The live path sends exactly one `llm.oneshot` and reads the reply's `text`.
    func testExplanationReadsTheReplyTextAndRefusesAnotherShape() async throws {
        let transport = OneshotTransport()
        transport.reply = .object(["text": .string("Deletes the folder.")])
        let text = try await ApprovalExplanationRegistry.explanation("Command: rm -rf x", over: transport)
        XCTAssertEqual(text, "Deletes the folder.")
        XCTAssertEqual(transport.calls, [.approvalExplanation(input: "Command: rm -rf x")])

        transport.reply = .object(["title": .string("Not this")])
        do { _ = try await ApprovalExplanationRegistry.explanation("Command: ls", over: transport); XCTFail("Refused") }
        catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        XCTAssertThrowsError(try HermesCall.approvalExplanation(input: " \n").params(), "A blank input is never sent")
    }
}

@MainActor private final class OneshotTransport: BotTransport {
    var reply: BotJSON = .null
    var calls: [HermesCall] = []
    var replayEpoch: String? { nil }
    var serverVersion: String? { nil }
    var serverInstallID: String? { nil }
    var unavailableMethods: Set<String> { [] }
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    func connect() async throws {}
    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        calls.append(call)
        return reply
    }
    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String { "" }
    func artifactData(path: String, context: BotArtifactContext) async throws -> Data { Data() }
    func deleteProfile(_ name: String) async throws {}
    func close() {}
}
