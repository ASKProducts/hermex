import SwiftUI
import XCTest
import UserNotifications
@testable import HermesMobile

/// #50: one app-level owner of the voice call; the full screen and the floating bubble are
/// views of it. Each test uses its own controller (never `.shared`) and a fake backend.
@MainActor final class VoiceCallTests: XCTestCase {
    private let server = URL(string: "https://call.invalid")!
    private let otherServer = URL(string: "https://other.invalid")!

    private func connection() throws -> BotConnection {
        BotConnection(id: UUID(), name: "t", address: try BotConnection.address("http://127.0.0.1:9"),
                      username: "u", password: "p")
    }

    /// A call whose model runs a Normal `VoiceSession` on `backend` (no audio, no network).
    private func startCall(_ controller: VoiceCallController, backend: FakeVoiceBackend, chat: String? = "chat-1")
        async throws -> (VoiceCall, VoiceSession) {
        let presentation = VoiceCallPresentation(server: server, requestedMode: .normal, resumeSessionKey: chat)
        let model = VoiceScreenModel(server: server, connection: try connection(), resumeSessionKey: chat,
                                     requestedMode: .normal)
        let session = VoiceSession(backend: backend, player: FakePlayer(), resumeSessionKey: chat, reconnectDelay: { _ in })
        let started = expectation(description: "engine started")
        XCTAssertTrue(controller.start(presentation, model: model, begin: { model in
            model.attach(session)
            await session.start()
            started.fulfill()
        }))
        await fulfillment(of: [started], timeout: 2)
        return (try XCTUnwrap(controller.call), session)
    }

    func testBotsHomeChromeDisablesVoiceWhenOffline() throws {
        let avatar = SessionsHeader.Avatar(initials: "QA", color: .blue, foreground: .white,
            servers: .init(servers: [], activeServerID: nil), openSettings: {}, switchToServer: { _ in }, addServer: {}, manageServers: {})
        let home = HermesHome(title: "QA", avatar: avatar, tab: .constant(.bots), server: server, voiceChat: .constant(nil))
        for offline in [true, false] {
            let chrome = BotsInboxChrome(home: home, isOffline: offline, search: {}, openSetup: {}, filter: { EmptyView() }, newChat: { EmptyView() })
            XCTAssertEqual(try XCTUnwrap(chrome.homeChrome).isVoiceDisabled, offline)
        }
    }

    func testVoiceEndCarriesHostProfileWithoutAListedRow() async throws {
        let controller = VoiceCallController()
        let backend = FakeVoiceBackend()
        backend.callHook = { method, _ in
            guard method == "session.create" else { return nil }
            return .object(["session_id": .string("rt-1"), "stored_session_id": .string("key-1"),
                "info": .object(["profile_name": .string("voice-owner")])])
        }
        let (_, session) = try await startCall(controller, backend: backend, chat: nil)
        await session.utterance(text: "Profile probe")
        _ = await controller.end(opensChat: false)
        let ended = try XCTUnwrap(controller.lastEnded)
        XCTAssertEqual(ended.profile, "voice-owner")
        XCTAssertEqual(ended.hermesTarget, .session(profile: "voice-owner", key: "key-1"),
                       "no selected-list Profile or loaded row participates in End's identity")
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.close" })
        let suite = "voice-owner-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = BotConnection(id: UUID(), name: "QA", address: server, username: "fixture", password: "fixture-only")
        let wire = HermesSessionListWire()
        wire.profiles = ["other", "voice-owner"]
        let list = SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults),
            hermes: HermesSessionListSource(connection: connection, profile: "other", makeWire: { _ in wire }, preferences: defaults))
        await list.openHermes()
        await list.selectHermesProfile("other")
        XCTAssertEqual(list.hermesProfile, "other")
        XCTAssertTrue(list.sessions.isEmpty)
        let chat = HermesSessionChat(server: server, connection: connection, target: try XCTUnwrap(ended.hermesTarget))
        XCTAssertEqual(chat.target, .session(profile: "voice-owner", key: "key-1"))
    }

    // MARK: #111 where a failed call's reason shows

    /// A call whose engine can't reach Hermes ends by itself with "Couldn't connect to Hermes.".
    /// The controller releases such a call at once (#50: `onEndedByItself` → `release`), so the
    /// full screen closes and the reason is on screen in the ended banner, hosted here at 402 pt.
    /// (The notices line on the full screen carries the same sentence while that screen is up.)
    func testFailedStartShowsTheReasonInTheBanner() async throws {
        let controller = VoiceCallController()
        let backend = FakeVoiceBackend()
        backend.failConnect = true
        let presentation = VoiceCallPresentation(server: server, requestedMode: .normal, resumeSessionKey: "chat-1")
        let model = VoiceScreenModel(server: server, connection: try connection(), resumeSessionKey: "chat-1",
                                     requestedMode: .normal)
        let session = VoiceSession(backend: backend, player: FakePlayer(), resumeSessionKey: "chat-1")
        let started = expectation(description: "engine started")
        XCTAssertTrue(controller.start(presentation, model: model, begin: { model in
            model.attach(session)
            await session.start()
            started.fulfill()
        }))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(session.phase, .ended("Couldn't connect to Hermes."))
        XCTAssertNil(controller.call, "a call that ended by itself is released")
        XCTAssertEqual(controller.endedBanner, "Voice call ended: Couldn't connect to Hermes.")

        let window = try hostAt402(controller)
        let labels = await accessibilityLabels(window)
        try XCTSkipIf(labels.isEmpty, "This toolchain does not expose SwiftUI's accessibility tree")
        XCTAssertTrue(labels.contains { $0.contains("Couldn't connect to Hermes.") }, "\(labels)")
        keepPicture(of: window, named: "ended-reason-banner-402")
        window.isHidden = true
    }

    /// While the full screen is up on an ended call, the reason is a line in the notices above the
    /// dock (`voice-ended-reason`) and the orb's VoiceOver label is "Ended". The release that
    /// normally closes the screen at once is left out here (`onEndedByItself` cleared) so the
    /// screen stays up to be read.
    func testEndedReasonIsANoticeOnTheFullScreen() async throws {
        let controller = VoiceCallController()
        let backend = FakeVoiceBackend()
        backend.failConnect = true
        let presentation = VoiceCallPresentation(server: server, requestedMode: .normal, resumeSessionKey: "chat-1")
        let model = VoiceScreenModel(server: server, connection: try connection(), resumeSessionKey: "chat-1",
                                     requestedMode: .normal)
        let session = VoiceSession(backend: backend, player: FakePlayer(), resumeSessionKey: "chat-1")
        let started = expectation(description: "engine started")
        XCTAssertTrue(controller.start(presentation, model: model, begin: { model in
            model.onEndedByItself = nil
            model.attach(session)
            await session.start()
            started.fulfill()
        }))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(controller.call)
        let window = try hostAt402(controller)
        let nodes = await accessibilityNodes(window)
        let labels = nodes.compactMap(\.accessibilityLabel)
        try XCTSkipIf(labels.isEmpty, "This toolchain does not expose SwiftUI's accessibility tree")
        XCTAssertTrue(labels.contains("Couldn't connect to Hermes."), "the notice line: \(labels)")
        XCTAssertTrue(labels.contains("Ended"), "the orb's label: \(labels)")
        keepPicture(of: window, named: "ended-reason-notice-402")
        window.isHidden = true
    }


    func testRunningTranscriptStartsBelowTheNativeHeader() async throws {
        let controller = VoiceCallController()
        let (call, session) = try await startCall(controller, backend: FakeVoiceBackend(), chat: nil)
        let question = "Safe area regression question"
        let transcript = try XCTUnwrap(call.model).transcript
        transcript.loadHistory([ChatMessage(role: "user", content: question, timestamp: 1, messageId: "safe-question")], hasOlder: false)
        await session.utterance(text: "A running request")
        let window = try hostAt402(controller)
        defer { window.isHidden = true; window.rootViewController = nil }
        let nodes = await accessibilityNodes(window)
        let row = try XCTUnwrap(nodes.first { $0.accessibilityLabel?.contains(question) == true })
        let settings = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Call settings" })
        XCTAssertGreaterThanOrEqual(row.accessibilityFrame.minY, settings.accessibilityFrame.maxY,
                                    "The first question must clear the native header and status bar")
        _ = await controller.end(opensChat: false)
    }


    private func hostAt402(_ controller: VoiceCallController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: AnyView(Color.white.voiceCallHost(controller)))
        window.makeKeyAndVisible()
        return window
    }

    private func accessibilityNodes(_ window: UIWindow) async -> [NSObject] {
        await settle(window)
        var pending: [NSObject] = [window]
        var seen: Set<ObjectIdentifier> = []
        var nodes: [NSObject] = []
        while let node = pending.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            nodes.append(node)
            pending += (node as? UIView)?.subviews ?? []
            pending += (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                pending += (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
            }
        }
        return nodes
    }

    private func accessibilityLabels(_ window: UIWindow) async -> [String] {
        await accessibilityNodes(window).compactMap(\.accessibilityLabel)
    }

    /// Review evidence: the hosted window drawn into the result bundle (test code only).
    private func keepPicture(of window: UIWindow, named name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Ownership

    /// Minimize → the screen goes away → the engine still runs → reopening shows the same
    /// engine instance. The screen no longer ends the call when it disappears.
    func testCallOutlivesTheScreenAndReopensTheSameEngine() async throws {
        let controller = VoiceCallController()
        let backend = FakeVoiceBackend()
        let (call, session) = try await startCall(controller, backend: backend)
        XCTAssertTrue(controller.isExpanded, "a new call opens its full screen")
        XCTAssertEqual(session.phase, .listening)

        // The call layer on screen with the full screen up, then minimized (#93: the screen leaves
        // the one root layer; nothing is torn down by a cover).
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        var host: UIHostingController<AnyView>? = UIHostingController(rootView: AnyView(Color.clear.voiceCallHost(controller)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host?.view.layoutIfNeeded()
        controller.minimize()
        XCTAssertFalse(controller.isExpanded)
        window.rootViewController = UIViewController()
        host = nil
        for _ in 0..<3 { await Task.yield() }

        XCTAssertFalse(session.isEnded, "closing the screen must not end the call")
        XCTAssertFalse(backend.closed)
        XCTAssertFalse(backend.marks.contains("chat-1:false"), "the chat is still marked as a live voice chat: \(backend.marks)")
        // A resumed chat's live session is "rt-resumed" (the fake's resume reply).
        backend.onEvent?(.object(["type": .string("message.start"), "session_id": .string("rt-resumed"), "payload": .object([:])]))
        XCTAssertEqual(session.hermesStatus.state, .thinking, "the engine keeps following Hermes while minimized")

        XCTAssertTrue(controller.opensCall(sessionID: "chat-1", server: server))
        XCTAssertTrue(controller.isExpanded)
        XCTAssertTrue(controller.call === call)
        XCTAssertTrue(controller.call?.model?.engineSession === session, "reopen draws the same engine instance")
    }

    /// #97: GPT-Live's end-of-call turn ("Voice call ended…" → "Noted.") finishes on the dashboard
    /// after End released the call and the chat reloaded on `lastEnded`. `lastSettled` follows
    /// that turn: it changes only when the turn's `message.complete` arrives, so the chat
    /// reloads once more and shows the reply without being reopened.




    /// #97, the call ending on its own (dropped connection): `release` ends the engine and only
    /// then follows its chat work, in one task. An engine whose `end()` suspends before its
    /// end-of-call work starts must not get `lastSettled` before that work completes.
    func testCallEndingOnItsOwnSettlesOnlyAfterTheEndOfCallTurnCompletes() async throws {
        let controller = VoiceCallController()
        let engine = SettlingFakeEngine()
        let presentation = VoiceCallPresentation(server: server, requestedMode: .live, resumeSessionKey: "chat-1")
        let model = VoiceScreenModel(server: server, connection: try connection(), resumeSessionKey: "chat-1",
                                     requestedMode: .live)
        let started = expectation(description: "engine attached")
        XCTAssertTrue(controller.start(presentation, model: model, begin: { model in
            model.attach(engine)
            started.fulfill()
        }))
        await fulfillment(of: [started], timeout: 2)

        model.onEndedByItself?("Connection lost.")
        XCTAssertEqual(controller.lastEnded?.byUser, false, "lastEnded is set at once")
        await waitUntil { engine.workStarted }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(controller.lastSettled, "the end-of-call turn has not completed")

        engine.completeWork()
        await waitUntil { controller.lastSettled != nil }
        XCTAssertEqual(controller.lastSettled, controller.lastEnded)
    }

    /// End ends the voice session once and releases the call once; a second End is a no-op.
    func testEndReleasesTheCallOnce() async throws {
        let controller = VoiceCallController()
        let backend = FakeVoiceBackend()
        let (_, session) = try await startCall(controller, backend: backend)
        let chat = await controller.end()
        XCTAssertEqual(chat, "chat-1", "#59: End returns the call's chat so the list opens it")
        XCTAssertNil(controller.call)
        XCTAssertFalse(controller.isExpanded)
        XCTAssertTrue(session.isEnded)
        let ended = try XCTUnwrap(controller.lastEnded)
        XCTAssertTrue(ended.byUser)
        XCTAssertEqual(ended.chatKey, "chat-1")
        let closesAfterFirst = backend.closed
        let callsAfterFirst = backend.calls.count

        let second = await controller.end()
        XCTAssertNil(second)
        XCTAssertEqual(controller.lastEnded, ended, "a second End releases nothing")
        XCTAssertEqual(backend.calls.count, callsAfterFirst)
        XCTAssertEqual(backend.closed, closesAfterFirst)
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.close" || $0.0 == "session.interrupt" },
                       "#59: End never cancels the chat's work")
    }

    /// #70: End keeps the voice screen up in its ending state while the engine's `end()` runs;
    /// the chat opens only after `end()` completed, and the call is released (the screen
    /// closes) only after the chat is open.
    func testEndShowsEndingUntilEndCompletesThenOpensTheChat() async throws {
        let controller = VoiceCallController()
        let session = EndingGateEngine()
        let presentation = VoiceCallPresentation(server: server, requestedMode: .normal, resumeSessionKey: "chat-1")
        let model = VoiceScreenModel(server: server, connection: try connection(), resumeSessionKey: "chat-1")
        let started = expectation(description: "attached")
        XCTAssertTrue(controller.start(presentation, model: model) { model in
            model.attach(session)
            started.fulfill()
        })
        await fulfillment(of: [started], timeout: 2)
        let call = try XCTUnwrap(controller.call)
        var order: [String] = []
        var releaseMark: CheckedContinuation<Void, Never>?
        let markHeld = expectation(description: "end() is inside the engine's teardown")
        session.endGate = {
            await withCheckedContinuation { releaseMark = $0; markHeld.fulfill() }
        }
        controller.chatOpener = { ended in
            order.append("open \(ended.chatKey ?? "nil") ended=\(session.isEnded)")
            XCTAssertTrue(controller.isEnding, "still the ending screen while the chat opens")
            XCTAssertTrue(controller.isExpanded)
            XCTAssertNotNil(controller.call)
        }
        let ending = Task { await controller.end() }
        await fulfillment(of: [markHeld], timeout: 2)
        // end() has not finished: the screen is up, showing Ending…, nothing opened.
        XCTAssertTrue(controller.isEnding)
        XCTAssertTrue(controller.isExpanded)
        XCTAssertNotNil(controller.call)
        XCTAssertTrue(order.isEmpty, "the chat must not open before end() completes")
        controller.minimize()
        XCTAssertTrue(controller.isExpanded, "no minimizing an ending call")
        let second = await controller.end()
        XCTAssertNil(second, "a second End while ending does nothing")

        releaseMark?.resume()
        let chat = await ending.value
        XCTAssertEqual(chat, "chat-1")
        XCTAssertEqual(order, ["open chat-1 ended=true"], "opened once, after end() finished")
        XCTAssertFalse(controller.isEnding)
        XCTAssertTrue(call.isEnding, "the closing screen keeps reading Ending… while it slides away")
        XCTAssertFalse(controller.isExpanded)
        XCTAssertNil(controller.call)
        XCTAssertEqual(controller.lastEnded?.chatKey, "chat-1")
    }

    /// End (#70): the voice screen closes only after the opened chat reports it can show its
    /// messages; until then the call is held, expanded and "Ending…". Another chat's report
    /// doesn't count.
    func testCoverClosesOnlyAfterTheChatReportsItsMessages() async throws {
        let controller = VoiceCallController()
        let (call, _) = try await startCall(controller, backend: FakeVoiceBackend())
        var selected: [String] = []
        let chatSelected = expectation(description: "End selected the chat")
        controller.chatOpener = { ended in
            guard let key = ended.chatKey else { return }
            await controller.openChatAndAwaitReady(key) {
                selected.append(key)
                chatSelected.fulfill()
            }
        }
        let ending = Task { await controller.end() }
        await fulfillment(of: [chatSelected], timeout: 2)
        XCTAssertEqual(selected, ["chat-1"])
        controller.chatScreenReady(sessionID: "chat-other")
        await Task.yield()
        XCTAssertTrue(controller.isExpanded, "the cover stays while the chat has no messages to show")
        XCTAssertTrue(controller.call === call)
        XCTAssertTrue(controller.isEnding)

        controller.chatScreenReady(sessionID: "chat-1")
        let chat = await ending.value
        XCTAssertEqual(chat, "chat-1")
        XCTAssertFalse(controller.isExpanded, "closes once the chat can show its messages")
        XCTAssertNil(controller.call)
    }

    /// A chat that already drew its messages (cache) by the time it is selected closes at once.
    func testCoverClosesAtOnceWhenTheChatIsAlreadyReady() async throws {
        let controller = VoiceCallController()
        _ = try await startCall(controller, backend: FakeVoiceBackend())
        controller.chatOpener = { ended in
            guard let key = ended.chatKey else { return }
            await controller.openChatAndAwaitReady(key) {
                controller.chatScreenReady(sessionID: key)   // the screen drew cached messages
            }
        }
        let chat = await controller.end()
        XCTAssertEqual(chat, "chat-1")
        XCTAssertNil(controller.call)
    }

    /// A server switch ends the call without opening its (old server's) chat.
    func testServerSwitchEndDoesNotOpenTheChat() async throws {
        let controller = VoiceCallController()
        _ = try await startCall(controller, backend: FakeVoiceBackend())
        var opened = 0
        controller.chatOpener = { _ in opened += 1 }
        _ = await controller.end(opensChat: false)
        XCTAssertEqual(opened, 0)
        XCTAssertNil(controller.call)
    }

    /// One call at a time: a second start is refused while one runs and allowed after End.
    func testSecondStartIsRefusedWhileACallRuns() async throws {
        let controller = VoiceCallController()
        let (call, _) = try await startCall(controller, backend: FakeVoiceBackend())
        XCTAssertTrue(controller.isRunning)
        let refused = controller.start(VoiceCallPresentation(server: server, requestedMode: .live), model: nil, begin: { _ in
            XCTFail("a refused call must not start an engine")
        })
        XCTAssertFalse(refused)
        XCTAssertTrue(controller.call === call)

        await controller.end()
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(controller.start(VoiceCallPresentation(server: server, requestedMode: .normal), model: nil, begin: { _ in }))
    }

    /// While the call runs, its chat routes to the voice screen; other chats and the same
    /// chat id on another server navigate normally; after End nothing is routed.
    func testTheCallsChatRoutesToTheVoiceScreen() async throws {
        let controller = VoiceCallController()
        _ = try await startCall(controller, backend: FakeVoiceBackend())
        controller.minimize()
        XCTAssertFalse(controller.opensCall(sessionID: "chat-2", server: server))
        XCTAssertFalse(controller.opensCall(sessionID: "chat-1", server: otherServer))
        XCTAssertFalse(controller.opensCall(sessionID: nil, server: server))
        XCTAssertFalse(controller.isExpanded, "a non-matching open leaves the call minimized")
        XCTAssertTrue(controller.opensCall(sessionID: "chat-1", server: server))
        XCTAssertTrue(controller.isExpanded)
        await controller.end()
        XCTAssertFalse(controller.opensCall(sessionID: "chat-1", server: server))
    }

    /// A new call's chat is the one its first request creates: it routes once the engine knows it.
    func testANewCallsChatRoutesOnceCreated() async throws {
        let controller = VoiceCallController()
        let backend = FakeVoiceBackend()
        let (_, session) = try await startCall(controller, backend: backend, chat: nil)
        XCTAssertFalse(controller.opensCall(sessionID: "key-1", server: server))
        session.speechEnded()
        await session.utterance(text: "what time is it")
        XCTAssertEqual(session.sessionKey, "key-1")
        XCTAssertTrue(controller.opensCall(sessionID: "key-1", server: server))
    }

    // MARK: Ending on its own, attention

    /// A connection that drops and can't be restored (#110: the chat is gone) releases the
    /// call and shows the ended reason; End isn't needed.
    func testCallEndingOnItsOwnReleasesItWithItsReason() async throws {
        let controller = VoiceCallController()
        let backend = FakeVoiceBackend()
        let (call, _) = try await startCall(controller, backend: backend)
        let model = try XCTUnwrap(call.model)
        let released = expectation(description: "released")
        let report = model.onEndedByItself
        model.onEndedByItself = { reason in report?(reason); released.fulfill() }
        backend.resumeFailure = .stale
        backend.onDisconnect?(URLError(.networkConnectionLost))
        await fulfillment(of: [released], timeout: 2)
        XCTAssertNil(controller.call)
        XCTAssertEqual(controller.endedBanner, "Voice call ended: Lost the connection to Hermes.")
        XCTAssertEqual(controller.lastEnded?.byUser, false)
        controller.dismissBanner()
        XCTAssertNil(controller.endedBanner)
    }

    /// The bubble's orange: an approval waits on the user, and clears when it is answered.
    func testApprovalTurnsTheCallToNeedsAttentionUntilAnswered() async throws {
        let controller = VoiceCallController()
        let backend = FakeVoiceBackend()
        let (call, session) = try await startCall(controller, backend: backend)
        let model = try XCTUnwrap(call.model)
        session.speechEnded()
        await session.utterance(text: "clean the build dir")
        XCTAssertFalse(model.needsAttention)
        backend.onEvent?(.object(["jsonrpc": .string("2.0"), "id": .string("srv-1"), "method": .string("approval"), "params": .object([
            "session_id": .string("rt-resumed"), "request_id": .string("ap-1"), "command": .string("rm -rf build"),
            "choices": .array([.string("once"), .string("deny")])])]))
        XCTAssertNotNil(session.pendingApproval)
        await waitForAttention(model, true)
        XCTAssertTrue(model.needsAttention)
        session.speechEnded()
        await session.utterance(text: "yes")
        XCTAssertNil(session.pendingApproval)
        await waitForAttention(model, false)
        XCTAssertFalse(model.needsAttention)
    }

    /// Observation delivers the engine change on the next main-actor turn.
    private func waitForAttention(_ model: VoiceScreenModel, _ value: Bool) async {
        let changed = expectation(description: "attention \(value)")
        func check() {
            if model.needsAttention == value { changed.fulfill(); return }
            withObservationTracking { _ = model.needsAttention } onChange: {
                Task { @MainActor in check() }
            }
        }
        check()
        await fulfillment(of: [changed], timeout: 2)
    }

    /// A server switch ends a call on the old server; the same server keeps it.
    func testServerSwitchEndsTheCall() async throws {
        let controller = VoiceCallController()
        let (_, session) = try await startCall(controller, backend: FakeVoiceBackend())
        controller.activeServerChanged(to: server)
        XCTAssertTrue(controller.isRunning)
        let ended = expectation(description: "ended")
        let observe = Task { @MainActor in
            while controller.isRunning { await Task.yield() }
            ended.fulfill()
        }
        controller.activeServerChanged(to: otherServer)
        await fulfillment(of: [ended], timeout: 2)
        observe.cancel()
        XCTAssertTrue(session.isEnded)
    }

    // MARK: Other audio

    /// "Listen" on a message is greyed out while a call runs and back after it ends.
    func testListenIsDisabledDuringACallAndEnabledAfter() async throws {
        let controller = VoiceCallController()
        XCTAssertTrue(listenItem(controller).isEnabled)
        _ = try await startCall(controller, backend: FakeVoiceBackend())
        XCTAssertFalse(listenItem(controller).isEnabled)
        XCTAssertTrue(listenItem(controller, listening: true).isEnabled, "a reply already playing can still be stopped")
        await controller.end()
        XCTAssertTrue(listenItem(controller).isEnabled)
    }

    /// The composer's dictation mic is greyed out while a call runs and back after it ends.
    func testDictationIsDisabledDuringACallAndEnabledAfter() async throws {
        let controller = VoiceCallController()
        func micDisabled() -> Bool {
            MessageComposerView.isVoiceInputDisabled(isListening: false, isBusy: false, voiceCallRunning: controller.isRunning)
        }
        XCTAssertFalse(micDisabled())
        _ = try await startCall(controller, backend: FakeVoiceBackend())
        XCTAssertTrue(micDisabled())
        XCTAssertFalse(MessageComposerView.isVoiceInputDisabled(isListening: true, isBusy: false, voiceCallRunning: true),
                       "dictation already running can be stopped")
        await controller.end()
        XCTAssertFalse(micDisabled())
    }

    private func listenItem(_ controller: VoiceCallController, listening: Bool = false) -> ChatMessageActionItem {
        let reply = ChatMessage(role: "assistant", content: "Hi", timestamp: nil, messageId: "a")
        let context = MessageActionContext(message: reply, visibleIndex: 0, messagesOffset: 0)!
        let menu = ChatMessageActionMenu(
            context: context, listeningMessageID: listening ? context.messageID : nil, isViewingCachedData: false,
            hasActiveStream: false, isRegeneratingMessage: false, isEditingMessage: false, isForkingMessage: false,
            onToggleListening: { _ in }, onRegenerate: { _ in }, onEdit: { _ in }, onFork: { _ in }, onCopy: { _ in },
            voiceCalls: controller)
        return menu.items.first { $0.kind == .listen }!
    }

    // MARK: Bubble clearance

    /// The bottom controls of the screen on screen win; a screen leaving clears only its own.
    func testBottomControlsFollowTheScreenOnScreen() {
        let controller = VoiceCallController()
        let list = UUID(), chat = UUID()
        controller.reportBottomControls(owner: list, top: 760)
        controller.reportBottomControls(owner: chat, top: 690)
        controller.clearBottomControls(owner: list)
        XCTAssertEqual(controller.composerTop, 690, "the list leaving after the chat appeared keeps the chat's")
        controller.clearBottomControls(owner: chat)
        XCTAssertNil(controller.composerTop)
    }

    // MARK: Push presence (#83)

    /// A minimized call's replies don't banner; its approvals do, and after End its replies do.


    // MARK: "New voice chat" (#79)

    /// With a call running, "New voice chat in Ariex" opens it; it never starts a second one.
    func testNewVoiceChatOpensTheRunningCallInsteadOfASecond() async throws {
        let controller = VoiceCallController()
        let (call, _) = try await startCall(controller, backend: FakeVoiceBackend())
        controller.minimize()
        controller.openOrStart(VoiceCallPresentation(server: server, requestedMode: .live))
        XCTAssertTrue(controller.call === call, "the same call")
        XCTAssertTrue(controller.isExpanded, "its voice screen is open")
        XCTAssertEqual(controller.call?.presentation.requestedMode, .normal)
        await controller.end()
    }

    /// With no call running it starts one like the waveform button; with no Bot connection
    /// that call has no model, which the voice screen shows as voice unavailable.
    func testNewVoiceChatStartsACallWhenNoneRuns() async throws {
        let controller = VoiceCallController()
        let unconfigured = URL(string: "https://no-bot-connection-\(UUID().uuidString).invalid")!
        controller.openOrStart(VoiceCallPresentation(server: unconfigured, requestedMode: .normal))
        let call = try XCTUnwrap(controller.call)
        XCTAssertNil(call.model, "no Bot connection: the voice-unavailable screen")
        XCTAssertTrue(controller.isExpanded)
        await controller.end()
    }

    // MARK: Bubble placement

    /// Released anywhere with no speed, the bubble rests on the nearest side at the release
    /// height, kept on screen (#96 adds the coast: `VoiceOrbTests`).
    func testBubbleSnapsToTheNearestSide() {
        let bounds = CGSize(width: 390, height: 700)
        func released(at point: CGPoint) -> VoiceCallBubblePlacement {
            var placement = VoiceCallBubblePlacement()
            let start = placement.position(in: bounds)
            placement.drag = CGSize(width: point.x - start.x, height: point.y - start.y)
            return placement.released(in: bounds)
        }
        let left = released(at: CGPoint(x: 120, y: 300))
        XCTAssertEqual(left.side, .leading)
        XCTAssertEqual(left.center(in: bounds).y, 300, accuracy: 0.001)
        let right = released(at: CGPoint(x: 260, y: 900))
        XCTAssertEqual(right.side, .trailing)
        XCTAssertEqual(right.center(in: bounds).y, bounds.height - VoiceCallBubblePlacement.inset)
        let aboveBox = VoiceCallBubblePlacement().center(in: bounds, clearance: 120)
        XCTAssertEqual(aboveBox.y, bounds.height - 120 - VoiceCallBubblePlacement.inset,
                       "rests just above the message box")
        let start = VoiceCallBubblePlacement()
        XCTAssertEqual(start.side, .trailing, "bottom right by default")
        XCTAssertEqual(start.center(in: bounds).x, bounds.width - VoiceCallBubblePlacement.inset)
    }

    /// #84: the bubble's drawn position and its resting place are one value, so the release
    /// animates from the release point: at the moment of release the drawn position is where
    /// the finger let go, and the settled value has no drag left in it.
    func testReleaseAnimatesFromTheReleasePoint() {
        let bounds = CGSize(width: 390, height: 700)
        let clearance: CGFloat = 80
        var placement = VoiceCallBubblePlacement()
        let dragStart = placement.position(in: bounds, clearance: clearance)
        placement.drag = CGSize(width: -200, height: -250)
        let releasePoint = CGPoint(x: dragStart.x - 200, y: dragStart.y - 250)
        XCTAssertEqual(placement.position(in: bounds, clearance: clearance), releasePoint,
                       "the animation's from-value is the release point, not the drag start")
        let settled = placement.released(in: bounds, clearance: clearance)
        XCTAssertEqual(settled.drag, .zero)
        XCTAssertEqual(settled.side, .leading)
        XCTAssertEqual(settled.position(in: bounds, clearance: clearance).y, releasePoint.y,
                       "it settles at the release height")
        XCTAssertNotEqual(settled.position(in: bounds, clearance: clearance), dragStart)
    }
}

/// #97: an engine whose `end()` suspends before it starts its end-of-call work, and whose work
/// completes only when the test says so.
@MainActor private final class SettlingFakeEngine: VoiceEngine {
    let mode: VoiceMode = .live
    private(set) var phase: VoiceSession.Phase = .listening
    var transcript = VoiceTranscriptModel()
    let caption = ""
    let notice: String? = nil
    let sessionKey: String? = "chat-1"
    var isEnded: Bool { if case .ended = phase { return true } else { return false } }
    let speechSlow = false
    let pendingApproval: BotApprovalRequest? = nil
    let hermesStatus = VoiceHermesStatus()
    let debugLine = ""
    let tickInterval: Duration = .seconds(1)
    private(set) var workStarted = false
    private var work: Task<Void, Never>?
    private var workDone: CheckedContinuation<Void, Never>?

    func tapToInterrupt() {}
    func tick() {}

    func end() async {
        phase = .ended(nil)
        // Like GPT-Live's end: the work is set up after the engine has suspended at least once.
        for _ in 0..<3 { await Task.yield() }
        work = Task { await withCheckedContinuation { self.workDone = $0 } }
        workStarted = true
    }

    func awaitChatWorkSettled() async { await work?.value }

    func completeWork() {
        workDone?.resume()
        workDone = nil
    }
}

@MainActor private final class EndingGateEngine: VoiceEngine {
    let mode: VoiceMode = .normal
    var phase: VoiceSession.Phase = .listening
    var transcript = VoiceTranscriptModel()
    let caption = ""
    let notice: String? = nil
    let sessionKey: String? = "chat-1"
    var isEnded: Bool { if case .ended = phase { return true }; return false }
    let speechSlow = false
    let pendingApproval: BotApprovalRequest? = nil
    let hermesStatus = VoiceHermesStatus()
    let debugLine = ""
    let tickInterval: Duration = .seconds(1)
    var endGate: (() async -> Void)?
    func tapToInterrupt() {}
    func tick() {}
    func end() async { phase = .ended(nil); await endGate?() }
    func awaitChatWorkSettled() async {}
}
