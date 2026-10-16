import XCTest
@testable import HermesMobile

/// #110: a voice call keeps its Hermes socket through `.background`, and recovers from a
/// socket that really drops mid-call by reconnecting and re-attaching its chat.
@MainActor final class VoiceCallLinkTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")
    private var sockets: [BotScriptedSocket] = []

    override func tearDown() {
        HermesHostFixture.reset()
        sockets = []
        super.tearDown()
    }

    // MARK: Background (the shared gateway)

    /// A running call is a consumer that holds the socket through `.background`: the app
    /// going to the background closes nothing while the call is attached, the screens still
    /// suspend themselves, the call keeps using the same socket, and the socket closes when
    /// the call leaves.
    func testBackgroundWithACallAttachedLeavesTheSocketOpen() async throws {
        let http = connection()
        let call = BotClient(http: http, holdsSocketInBackground: true), chat = BotClient(http: http)
        try await call.connect()
        try await chat.connect()
        var lost = 0
        call.onDisconnect = { _ in lost += 1 }
        let socket = try XCTUnwrap(sockets.first)

        http.gateway.closeForBackground()
        XCTAssertFalse(socket.isClosed, "A running call holds the socket in the background")
        XCTAssertTrue(call.isConnected)
        chat.close()  // The chat screen suspends on `.background`, as #967 intended.
        XCTAssertFalse(socket.isClosed)
        XCTAssertEqual(lost, 0)

        _ = try await call.call(.profilesList(includeSessions: false))
        XCTAssertEqual(sockets.count, 1, "The call's next request goes on the same socket")
        XCTAssertEqual(HermesHostFixture.count("/api/auth/ws-ticket"), 1)

        call.close()
        XCTAssertTrue(socket.isClosed, "The socket closes when the last consumer leaves")
    }

    /// Without a call, the background close is as #967 made it: once, silently, and a call
    /// that already ended holds nothing.
    func testBackgroundAfterTheCallEndedClosesTheSocketOnceAndSilently() async throws {
        let http = connection()
        let call = BotClient(http: http, holdsSocketInBackground: true), chat = BotClient(http: http)
        try await call.connect()
        try await chat.connect()
        var lost = 0
        chat.onDisconnect = { _ in lost += 1 }
        call.close()
        let socket = try XCTUnwrap(sockets.first)
        XCTAssertFalse(socket.isClosed, "The chat still holds it while foreground")

        http.gateway.closeForBackground()
        XCTAssertTrue(socket.isClosed)
        XCTAssertEqual(lost, 0, "The background close is silent")
        http.gateway.closeForBackground()
        chat.close()
        XCTAssertEqual(lost, 0)
        XCTAssertEqual(sockets.count, 1)
    }

    // MARK: A real drop mid-call

    /// GPT-Live: the socket drops mid-call; a request made during the gap waits, the call
    /// reconnects with the gateway's backoff, resumes its own chat (`session.resume` on its
    /// key) and replays what the gap missed, then the request goes exactly once.
    func testLiveCallReconnectsResumesItsChatAndDeliversTheGapRequestOnce() async throws {
        let backend = FakeVoiceBackend(), transport = FakeLiveTransport(), gate = DelayGate()
        let conversation = VoiceLiveConversation(backend: backend, makeTransport: { transport },
                                                 reconnectDelay: { try await gate.wait($0) })
        defer { withExtendedLifetime(conversation) {} }
        backend.callHook = { method, _ in
            switch method {
            case "session.resume": return .object(["session_id": .string("rt-1")])
            case "session.events.since": return .object(["events": .array([])])
            default: return nil
            }
        }
        await conversation.start()
        transport.events.handle(#"{"type":"session.started","session":{"id":"s"}}"#)
        XCTAssertEqual(conversation.sessionKey, "key-1")

        backend.onDisconnect?(BotFailure.transport)
        XCTAssertEqual(conversation.link.state, .reconnecting)
        XCTAssertFalse(conversation.isEnded, "A dropped socket does not end the call")
        guard !conversation.isEnded else { return }
        XCTAssertTrue(transport.frames.contains { $0["content"].text == VoiceLiveConversation.reconnectingNote })

        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"What's the weather","start_ms":0,"end_ms":900}"#)
        transport.events.handle(#"{"type":"session.delegation.created","delegation":{"id":"del_gap"}}"#)
        await gate.waitForSleeper()
        XCTAssertEqual(submits(backend), 0, "Nothing is sent while the socket is down")
        XCTAssertEqual(gate.requested, [.seconds(1)], "The first retry waits the gateway's first backoff step")

        gate.release()
        await waitUntil { self.submits(backend) == 1 }
        XCTAssertEqual(conversation.link.state, .connected)
        let resumed = backend.calls.filter { $0.0 == "session.resume" }
        XCTAssertEqual(resumed.count, 1)
        XCTAssertEqual(resumed.first?.1["session_id"]?.text, "key-1", "It re-attaches its own chat")
        XCTAssertEqual(backend.calls.filter { $0.0 == "session.events.since" }.count, 1)
        let methods = backend.calls.map(\.0)
        XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "session.resume")),
                          try XCTUnwrap(methods.firstIndex(of: "prompt.submit")))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(submits(backend), 1, "The gap's request goes exactly once")
        XCTAssertFalse(conversation.isEnded)
    }

    /// GPT-Live: when reconnecting can't succeed within the bounded attempts, the call ends
    /// with the reason shown, and the gap's request is never sent.
    func testLiveCallThatCannotReconnectEndsWithTheReason() async throws {
        let backend = FakeVoiceBackend(), transport = FakeLiveTransport()
        let conversation = VoiceLiveConversation(backend: backend, makeTransport: { transport }, reconnectDelay: { _ in })
        defer { withExtendedLifetime(conversation) {} }
        backend.callHook = { method, _ in
            if method == "session.resume" { throw BotFailure.transport }
            return nil
        }
        await conversation.start()
        transport.events.handle(#"{"type":"session.started","session":{"id":"s"}}"#)
        backend.onDisconnect?(BotFailure.transport)
        await waitUntil { conversation.isEnded }
        XCTAssertEqual(conversation.phase, .ended(String(localized: "Lost the connection to Hermes.")))
        XCTAssertEqual(backend.calls.filter { $0.0 == "session.resume" }.count, VoiceHermesLink.maxAttempts)
        XCTAssertEqual(submits(backend), 0)
    }

    /// Cascade (same client): a drop mid-call reconnects and resumes the chat, and words
    /// said during the gap go once it is back, exactly once.
    func testCascadeCallReconnectsResumesItsChatAndDeliversTheGapWordsOnce() async throws {
        let backend = FakeVoiceBackend(), gate = DelayGate()
        let session = VoiceSession(backend: backend, player: FakePlayer(), reconnectDelay: { try await gate.wait($0) })
        backend.callHook = { method, _ in
            switch method {
            case "session.resume": return .object(["session_id": .string("rt-1")])
            case "session.events.since": return .object(["events": .array([])])
            default: return nil
            }
        }
        await session.start()
        session.speechEnded()
        await session.utterance(text: "what time is it")
        backend.emit("message.complete", ["text": .string("Noon.")])
        XCTAssertEqual(submits(backend), 1)

        backend.onDisconnect?(BotFailure.transport)
        XCTAssertFalse(session.isEnded)
        guard !session.isEnded else { return XCTFail("A dropped socket ended the call") }
        session.speechEnded()
        let gapWords = Task { await session.utterance(text: "and the date") }
        await gate.waitForSleeper()
        XCTAssertEqual(submits(backend), 1, "Nothing is sent while the socket is down")

        gate.release()
        await gapWords.value
        XCTAssertEqual(submits(backend), 2, "The gap's words go once, after the chat is back")
        let resumed = backend.calls.filter { $0.0 == "session.resume" }
        XCTAssertEqual(resumed.map { $0.1["session_id"]?.text }, ["key-1"])
        XCTAssertEqual(session.link.state, .connected)
        XCTAssertFalse(session.isEnded)
    }

    /// The re-attach replays only what the gap missed: events after the last `seq` the call
    /// saw on its runtime, through the call's own event handler.
    func testReattachReplaysOnlyTheEventsTheGapMissed() async throws {
        let backend = FakeVoiceBackend()
        let link = VoiceHermesLink(backend: backend, delay: { _ in })
        func event(_ seq: Int) -> BotJSON {
            .object(["session_id": .string("rt-1"), "seq": .number(Double(seq)), "type": .string("message.delta")])
        }
        link.saw(event(3), runtime: "rt-1")
        link.saw(.object(["session_id": .string("other"), "seq": .number(9)]), runtime: "rt-1")
        var sinceAsked: Int?
        backend.callHook = { method, params in
            switch method {
            case "session.resume": return .object(["session_id": .string("rt-1")])
            case "session.events.since":
                sinceAsked = params["last_seen"]?.integer ?? params["since"]?.integer
                return .object(["events": .array([event(4), event(5)])])
            default: return nil
            }
        }
        let (live, missed) = try await link.resume(key: "key-1", profile: nil, runtime: "rt-1")
        XCTAssertEqual(live, "rt-1")
        XCTAssertEqual(sinceAsked, 3)
        XCTAssertEqual(missed.map { $0["seq"].integer }, [4, 5])

        backend.callHook = { method, _ in method == "session.resume" ? .object(["session_id": .string("rt-2")]) : nil }
        let (fresh, none) = try await link.resume(key: "key-1", profile: nil, runtime: "rt-1")
        XCTAssertEqual(fresh, "rt-2")
        XCTAssertEqual(none.count, 0, "A new runtime has no events of this call to replay")
        XCTAssertFalse(backend.calls.suffix(1).contains { $0.0 == "session.events.since" })
    }

    // MARK: Helpers

    private func submits(_ backend: FakeVoiceBackend) -> Int {
        backend.calls.filter { $0.0 == "prompt.submit" }.count
    }

    private func connection() -> HermesConnection {
        HermesConnection(connection: record, configuration: HermesHostFixture.configuration { _ in nil },
                         gateway: .init(rpcDeadline: .seconds(30)) { [weak self] _ in
                             let socket = BotScriptedSocket()
                             self?.sockets.append(socket)
                             return socket
                         })
    }
}

/// The reconnect backoff's wait, held until the test releases it: no clock, no sleeps.
@MainActor final class DelayGate {
    private(set) var requested: [Duration] = []
    private var sleeper: CheckedContinuation<Void, Never>?
    private var watcher: CheckedContinuation<Void, Never>?

    func wait(_ duration: Duration) async throws {
        requested.append(duration)
        await withCheckedContinuation { continuation in
            sleeper = continuation
            watcher?.resume(); watcher = nil
        }
    }

    func waitForSleeper() async {
        guard sleeper == nil else { return }
        await withCheckedContinuation { watcher = $0 }
    }

    func release() { sleeper?.resume(); sleeper = nil }
}
