import XCTest
@testable import HermesMobile

/// Terminal endpoints, SSE decoding, the input queue,
/// reconnect replay and the controller's state machine.
final class TerminalAPITests: APIClientTestCase {
    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(apiTestBodyData(from: request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testStartEncodesBodyAndDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/terminal/start")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try self.jsonBody(request)
            XCTAssertEqual(body["session_id"] as? String, "s1")
            XCTAssertEqual(body["rows"] as? Int, 40)
            XCTAssertEqual(body["cols"] as? Int, 90)
            XCTAssertNil(body["restart"])
            return apiTestJSONResponse(#"{"ok":true,"session_id":"s1","workspace":"/w","running":true,"extra":1}"#, for: request)
        }
        let response = try await client.terminalStart(sessionID: "s1", rows: 40, cols: 90)
        XCTAssertEqual(response.workspace, "/w")
        XCTAssertEqual(response.running, true)
    }

    func testRestartSendsRestartTrue() async throws {
        let client = makeClient { request in
            XCTAssertEqual(try self.jsonBody(request)["restart"] as? Bool, true)
            return apiTestJSONResponse(#"{"ok":true}"#, for: request)
        }
        _ = try await client.terminalStart(sessionID: "s1", rows: 24, cols: 80, restart: true)
    }

    func testInputResizeCloseEncodeBodies() async throws {
        var seen: [String: [String: Any]] = [:]
        let client = makeClient { request in
            seen[request.url!.path] = try self.jsonBody(request)
            XCTAssertEqual(request.httpMethod, "POST")
            return apiTestJSONResponse(#"{"ok":true,"closed":true}"#, for: request)
        }
        _ = try await client.terminalInput(sessionID: "s1", data: "ls\r")
        _ = try await client.terminalResize(sessionID: "s1", rows: 30, cols: 100)
        let closed = try await client.terminalClose(sessionID: "s1")
        XCTAssertEqual(closed.closed, true)
        XCTAssertEqual(seen["/api/terminal/input"]?["data"] as? String, "ls\r")
        XCTAssertEqual(seen["/api/terminal/input"]?["session_id"] as? String, "s1")
        XCTAssertEqual(seen["/api/terminal/resize"]?["rows"] as? Int, 30)
        XCTAssertEqual(seen["/api/terminal/resize"]?["cols"] as? Int, 100)
        XCTAssertEqual(seen["/api/terminal/close"]?["session_id"] as? String, "s1")
    }

    func testOutputEndpointURL() {
        let url = Endpoint.terminalOutput(sessionID: "a b").url(relativeTo: URL(string: "https://example.test")!)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.path, "/api/terminal/output")
        XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "session_id", value: "a b")])
    }

    func testRemoteBackend400IsRecognised() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, Data(#"{"error":"remote_terminal_backend_unsupported","code":"remote_terminal_backend_unsupported"}"#.utf8))
        }
        do {
            _ = try await client.terminalStart(sessionID: "s1", rows: 24, cols: 80)
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertTrue(error.indicatesRemoteTerminalBackend)
        }
    }

    func testEventDecoding() {
        XCTAssertEqual(
            TerminalStreamEventDecoder.decode(eventType: "output", data: #"{"text":"\u001b[1mhi"}"#, lastEventID: "7"),
            .output(text: "\u{1B}[1mhi", seq: 7)
        )
        XCTAssertEqual(TerminalStreamEventDecoder.decode(eventType: "terminal_closed", data: #"{"exit_code":0}"#, lastEventID: nil), .closed(exitCode: 0))
        XCTAssertEqual(TerminalStreamEventDecoder.decode(eventType: "terminal_error", data: #"{"error":"boom"}"#, lastEventID: nil), .serverError("boom"))
        XCTAssertEqual(TerminalStreamEventDecoder.decode(eventType: "something_new", data: #"{"x":1}"#, lastEventID: "3"), .ignored)
        XCTAssertEqual(TerminalStreamEventDecoder.decode(eventType: "output", data: "not json", lastEventID: "3"), .ignored)
    }
}

// MARK: - Controller

private final class FakeTerminalAPI: TerminalAPI, @unchecked Sendable {
    let lock = NSLock()
    var inputs: [String] = []
    var starts: [(restart: Bool, rows: Int, cols: Int)] = []
    var resizes: [(Int, Int)] = []
    var startError: Error?
    var resizeError: Error?
    var inputError: Error?
    /// When set, each input POST waits for this to be signalled once.
    var inputGate: AsyncStream<Void>.Continuation?
    var inputGateStream: AsyncStream<Void>?

    func terminalStart(sessionID: String, rows: Int, cols: Int, restart: Bool) async throws -> TerminalStartResponse {
        lock.withLock { starts.append((restart, rows, cols)) }
        if let startError { throw startError }
        return TerminalStartResponse(ok: true, sessionId: sessionID, workspace: "/ws", running: true)
    }

    func terminalInput(sessionID: String, data: String) async throws -> TerminalOKResponse {
        if let stream = inputGateStream {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        lock.withLock { inputs.append(data) }
        if let inputError { throw inputError }
        return TerminalOKResponse(ok: true, closed: nil)
    }

    func terminalResize(sessionID: String, rows: Int, cols: Int) async throws -> TerminalOKResponse {
        lock.withLock { resizes.append((rows, cols)) }
        if let resizeError { throw resizeError }
        return TerminalOKResponse(ok: true, closed: nil)
    }
}

@MainActor
private final class ScriptedTerminalStream: TerminalOutputStreaming {
    private(set) var startedLastEventIDs: [String?] = []
    private(set) var stopCount = 0
    private var onEvent: (@MainActor (TerminalStreamEvent) -> Void)?

    func start(url: URL, lastEventID: String?, onEvent: @escaping @MainActor (TerminalStreamEvent) -> Void) {
        startedLastEventIDs.append(lastEventID)
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
        onEvent = nil
    }

    func play(_ events: TerminalStreamEvent...) {
        for event in events { onEvent?(event) }
    }
}

@MainActor
final class TerminalSessionControllerTests: XCTestCase {
    private let server = URL(string: "https://example.test")!
    private var api: FakeTerminalAPI!
    private var stream: ScriptedTerminalStream!
    private var output: [String] = []

    override func setUp() async throws {
        TerminalShellRegistry.reset()
        api = FakeTerminalAPI()
        stream = ScriptedTerminalStream()
        output = []
    }

    private func makeController(sessionID: String = "s1") -> TerminalSessionController {
        let controller = TerminalSessionController(
            sessionID: sessionID, server: server, api: api, stream: stream,
            resizeDebounce: .zero, reconnectDelay: { _ in .zero }
        )
        controller.onOutput = { [weak self] in self?.output.append($0) }
        return controller
    }

    func testOpenStartsAtMeasuredSizeThenGoesLive() async {
        let controller = makeController()
        await controller.open(rows: 33, cols: 77)
        XCTAssertEqual(api.starts.count, 1)
        XCTAssertEqual(api.starts.first?.rows, 33)
        XCTAssertEqual(api.starts.first?.cols, 77)
        XCTAssertEqual(controller.state, .live)
        XCTAssertEqual(controller.workspace, "/ws")
        XCTAssertEqual(stream.startedLastEventIDs, [nil])
    }

    func test404OnAttachEndsSession() async {
        let controller = makeController()
        await controller.open(rows: 24, cols: 80)
        stream.play(.gone)
        XCTAssertEqual(controller.state, .ended(.gone))
        XCTAssertEqual(api.starts.count, 1, "never auto-starts a new shell")
    }

    func testTerminalClosedEndsSessionAndRestartGoesLive() async {
        let controller = makeController()
        await controller.open(rows: 24, cols: 80)
        stream.play(.output(text: "a", seq: 1), .closed(exitCode: 0))
        XCTAssertEqual(controller.state, .ended(.exited(0)))
        await controller.restart()
        XCTAssertEqual(controller.state, .live)
        XCTAssertEqual(api.starts.last?.restart, true)
        XCTAssertEqual(stream.startedLastEventIDs.last, .some(nil), "a fresh shell replays from the start")
    }

    func testReconnectSendsLastEventIDAndSkipsSeenSeqs() async throws {
        let controller = makeController()
        await controller.open(rows: 24, cols: 80)
        stream.play(.output(text: "one", seq: 1), .output(text: "two", seq: 2), .disconnected(nil))
        XCTAssertEqual(controller.state, .reconnecting)
        // Reconnect delay is zero; let the scheduled task run.
        for _ in 0..<20 where stream.startedLastEventIDs.count < 2 { await Task.yield() }
        XCTAssertEqual(stream.startedLastEventIDs.last, "2")
        stream.play(.output(text: "two", seq: 2), .output(text: "three", seq: 3))
        XCTAssertEqual(output, ["one", "two", "three"])
        XCTAssertEqual(controller.state, .live)
    }

    func testBackgroundThenForegroundReattachesWithLastSeq() async {
        let controller = makeController()
        await controller.open(rows: 24, cols: 80)
        stream.play(.output(text: "x", seq: 5))
        controller.suspend()
        XCTAssertEqual(controller.state, .reconnecting)
        controller.resume()
        XCTAssertEqual(stream.startedLastEventIDs.last, "5")
    }

    func testReopenAfterCleanupShowsNoticeAndStartsFresh() async {
        let first = makeController()
        await first.open(rows: 24, cols: 80)
        first.detach()
        api.resizeError = APIError.http(statusCode: 404, body: #"{"error":"terminal not running"}"#)
        let second = makeController()
        await second.open(rows: 24, cols: 80)
        XCTAssertEqual(output.first?.contains(TerminalSessionController.previousSessionNotice), true)
        XCTAssertEqual(second.state, .live)
    }

    func testReopenWhileAliveHasNoNotice() async {
        let first = makeController()
        await first.open(rows: 24, cols: 80)
        first.detach()
        let second = makeController()
        await second.open(rows: 24, cols: 80)
        XCTAssertTrue(output.isEmpty)
    }

    func testRemoteBackendFailsWithoutTerminal() async {
        api.startError = APIError.http(statusCode: 400, body: #"{"error":"remote_terminal_backend_unsupported"}"#)
        let controller = makeController()
        await controller.open(rows: 24, cols: 80)
        guard case .failed = controller.state else { return XCTFail("expected failed, got \(controller.state)") }
        XCTAssertTrue(stream.startedLastEventIDs.isEmpty)
    }

    func testChunkSplitting() {
        var buffer = String(repeating: "a", count: 20_000)
        var chunks: [String] = []
        while !buffer.isEmpty { chunks.append(TerminalSessionController.takeChunk(from: &buffer)) }
        let limit = TerminalSessionController.maxInputChunk
        XCTAssertLessThanOrEqual(limit, 8192, "server rejects larger inputs with 413")
        XCTAssertEqual(chunks.count, (20_000 + limit - 1) / limit)
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.count == limit })
        XCTAssertEqual(chunks.joined(), String(repeating: "a", count: 20_000))
        var accented = String(repeating: "é", count: limit + 1)
        XCTAssertEqual(TerminalSessionController.takeChunk(from: &accented).unicodeScalars.count, limit)
    }

    func testInputIsSerialOrderedCoalescedAndSplit() async throws {
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        api.inputGateStream = gateStream
        let controller = makeController()
        await controller.open(rows: 24, cols: 80)

        controller.send("a")            // first POST starts, blocked on the gate
        for _ in 0..<10 { await Task.yield() }
        controller.send("b")
        controller.send("c")
        let limit = TerminalSessionController.maxInputChunk
        let pasted = String(repeating: "x", count: limit + 100)
        controller.send(pasted)
        gate.yield(())                   // release "a"
        for _ in 0..<10 { await Task.yield() }
        gate.yield(())                   // release coalesced chunk 1
        for _ in 0..<10 { await Task.yield() }
        gate.yield(())                   // release chunk 2
        for _ in 0..<50 where api.inputs.count < 3 { await Task.yield() }

        XCTAssertEqual(api.inputs.count, 3)
        XCTAssertEqual(api.inputs[0], "a")
        XCTAssertEqual(api.inputs[1].count, limit)
        XCTAssertTrue(api.inputs[1].hasPrefix("bcx"), "keys typed during a POST coalesce into the next one")
        XCTAssertEqual(api.inputs.joined(), "abc" + pasted)
        XCTAssertTrue(api.inputs.allSatisfy { $0.count <= limit })
    }

    func testInput404EndsSession() async throws {
        api.inputError = APIError.http(statusCode: 404, body: nil)
        let controller = makeController()
        await controller.open(rows: 24, cols: 80)
        controller.send("ls\r")
        for _ in 0..<50 where controller.state == .live { await Task.yield() }
        XCTAssertEqual(controller.state, .ended(.gone))
    }
}

/// Check 9: the terminal cover belongs to one signed-in server.
@MainActor
final class TerminalAuthGateTests: XCTestCase {
    private let a = URL(string: "https://a.test")!
    private let b = URL(string: "https://b.test")!

    func testStaysOpenWhileItsServerIsSignedIn() {
        XCTAssertFalse(TerminalAuthGate.shouldDismiss(terminalServer: a, state: .loggedIn(server: a)))
    }

    func testDismissesOnSwitchSignOutOrReset() {
        XCTAssertTrue(TerminalAuthGate.shouldDismiss(terminalServer: a, state: .loggedIn(server: b)))
        XCTAssertTrue(TerminalAuthGate.shouldDismiss(terminalServer: a, state: .loggedOut(server: a)))
        XCTAssertTrue(TerminalAuthGate.shouldDismiss(terminalServer: a, state: .unconfigured))
    }

    func testAuthManagerPostsStateChangesSoAnOpenTerminalCanClose() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        registry.activate(url: b)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: a.absoluteString, password: "")
        XCTAssertEqual(manager.state, .loggedIn(server: a))
        let bAccount = try XCTUnwrap(registry.servers.first { $0.id == b.absoluteString })

        var seen: [AuthManager.State] = []
        let token = NotificationCenter.default.addObserver(forName: .hermexAuthStateDidChange, object: manager, queue: nil) { note in
            if let m = note.object as? AuthManager { MainActor.assumeIsolated { seen.append(m.state) } }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.switchActiveServer(to: bAccount)
        XCTAssertEqual(seen.last, .loggedIn(server: b))
        XCTAssertTrue(TerminalAuthGate.shouldDismiss(terminalServer: a, state: try XCTUnwrap(seen.last)))

        await manager.signOut()
        // Sign-out hands over to the remaining server (A), so B is never signed in afterwards.
        XCTAssertNotEqual(seen.last, .loggedIn(server: b))
        XCTAssertTrue(TerminalAuthGate.shouldDismiss(terminalServer: b, state: manager.state))
    }

    func testTerminalShellRegistryIsScopedPerServer() {
        XCTAssertNotEqual(TerminalShellRegistry.key(server: a, sessionID: "s1"),
                          TerminalShellRegistry.key(server: b, sessionID: "s1"))
    }
}

final class TerminalLinksTests: XCTestCase {
    func testOnlyWebLinksOpen() {
        XCTAssertEqual(TerminalLinks.openableURL("https://example.com/x?y=1")?.host, "example.com")
        XCTAssertNotNil(TerminalLinks.openableURL("http://example.com"))
        XCTAssertNil(TerminalLinks.openableURL("file:///etc/passwd"))
        XCTAssertNil(TerminalLinks.openableURL("tel:123"))
        XCTAssertNil(TerminalLinks.openableURL("hermex://session/1"))
        XCTAssertNil(TerminalLinks.openableURL("https://"))
    }
}

@MainActor
final class TerminalOutputBatcherTests: XCTestCase {
    func testChunksInOneTurnAreFedOnceInOrder() async {
        var fed: [String] = []
        let batcher = TerminalOutputBatcher { fed.append($0) }
        batcher.append("a"); batcher.append("b"); batcher.append("c")
        XCTAssertEqual(fed, [], "nothing is fed synchronously")
        let done = expectation(description: "next turn")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(fed, ["abc"])
        batcher.append("d")
        batcher.flush()
        XCTAssertEqual(fed, ["abc", "d"], "flush feeds what is pending right away")
    }

    func testFloodIsFedInBoundedSlicesInOrderWithoutLoss() {
        var fed: [String] = []
        let batcher = TerminalOutputBatcher(maxPerPass: 1000) { fed.append($0) }
        var expected = ""
        for i in 1...2000 {
            let line = "\(i) h\u{e9}llo \u{1F600} \u{1B}[32mgreen\u{1B}[0m\r\n"
            expected += line
            batcher.append(line)
        }
        var passes = 0
        while batcher.hasPending { batcher.drainOnePass(); passes += 1 }
        XCTAssertGreaterThan(passes, 50, "a flood takes many passes")
        XCTAssertTrue(fed.allSatisfy { $0.utf8.count <= 1000 }, "each pass stays within the cap")
        XCTAssertEqual(fed.joined(), expected, "nothing lost, reordered or split inside a scalar")
    }

    func testFloodYieldsToTheRunLoopBetweenSlices() async {
        var fed: [String] = []
        let batcher = TerminalOutputBatcher(maxPerPass: 10) { fed.append($0) }
        batcher.append(String(repeating: "x", count: 35))
        XCTAssertEqual(fed.count, 0, "append never feeds synchronously")
        batcher.drainOnePass()
        XCTAssertEqual(fed.count, 1, "one pass feeds at most one budget's worth")
        XCTAssertTrue(batcher.hasPending)
        let drained = expectation(description: "drained")
        func poll() { if batcher.hasPending { DispatchQueue.main.async { poll() } } else { drained.fulfill() } }
        poll()
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(fed, ["xxxxxxxxxx", "xxxxxxxxxx", "xxxxxxxxxx", "xxxxx"])
    }
}
