import XCTest
import Observation
@testable import HermesMobile

@MainActor final class HermesTerminalTests: XCTestCase {
    override func tearDown() { HermesHostFixture.reset(); super.tearDown() }

    func testMountedSocketIsTheCapability() {
        XCTAssertTrue(HermexCompanionRoutes(pluginVersion: nil, routes: ["WS /terminal/shell"]).supportsTerminal)
        XCTAssertFalse(HermexCompanionRoutes(pluginVersion: HermexPushPluginVersion("99.0.0"), routes: []).supportsTerminal)
        XCTAssertFalse(HermexCompanionRoutes(pluginVersion: nil, routes: ["GET /terminal/shell/status"]).supportsTerminal)
    }

    func testUpgradePreservesSubpathsAndFormSafeQueries() throws {
        let request = try HermesREST.terminalUpgrade(base: URL(string: "https://hermes.example/hermes/")!,
            sessionID: "chat +/雪", profile: "work+one", size: TerminalSize(columns: 92, rows: 33), ticket: "ticket+value")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/hermes/api/plugins/hermex-push/terminal/shell")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "session_id" }?.value, "chat +/雪")
        XCTAssertEqual(items.first { $0.name == "shell_profile" }?.value, "work+one")
        XCTAssertEqual(items.first { $0.name == "ticket" }?.value, "ticket+value")
        XCTAssertTrue(url.absoluteString.contains("%2B"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"))
        XCTAssertEqual(TerminalSize(columns: 0, rows: 2000), TerminalSize(columns: 1, rows: 1000))
        guard case .string(let frame) = TerminalSize(columns: 92, rows: 33).frame else { return XCTFail() }
        XCTAssertEqual(frame, "\u{1b}[RESIZE:92;33]")
        let status = try HermesREST.terminalStatus(sessionID: "chat +", profile: "work+one").request(base: URL(string: "https://hermes.example/hermes/")!)
        XCTAssertEqual(status.url?.path, "/hermes/api/plugins/hermex-push/terminal/shell/status")
        XCTAssertTrue(status.url?.absoluteString.contains("%2B") == true)
    }

    func testFailureMappingKeepsPermanentFailuresAndTransientHTTPStatuses() {
        for code in [408, 429, 500, 503] {
            XCTAssertTrue(HermesTerminalFailure.read(BotFailure.rejected(code), closeCode: 1006).canReconnect)
        }
        for error: BotFailure in [.signInExpired, .blocked, .browserSignIn, .notDashboard, .outdated("old"), .unsupported,
                                  .invalidAddress, .missingChat, .stale, .upgradeRefused(403)] {
            let failure = HermesTerminalFailure.read(error, closeCode: 1006)
            XCTAssertEqual(failure, .connection(error)); XCTAssertFalse(failure.canReconnect)
        }
        XCTAssertFalse(HermesTerminalFailure.read(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")), closeCode: 0).canReconnect)
        XCTAssertEqual(HermesTerminalFailure.read(URLError(.networkConnectionLost), closeCode: 4410), .exited)
        XCTAssertEqual(HermesTerminalFailure.read(URLError(.networkConnectionLost), closeCode: 4409), .replaced)
        XCTAssertEqual(HermesTerminalFailure.read(URLError(.networkConnectionLost), closeCode: 4401), .refused)
    }

    func testListTargetPolicyAndConnectionIdentity() {
        let http = target().http
        let row = SessionSummary(sessionId: "tip", profile: "row-profile", hermes: .init(lineageRoot: "root", unread: false, preview: nil))
        let listed = HermesTerminalTarget.listed(row, server: http.connection.address, http: http, profile: "selected")
        XCTAssertTrue(SessionRowActionPolicy.offersTerminal(for: row))
        XCTAssertFalse(SessionRowActionPolicy.offersTerminal(for: SessionSummary(sessionId: "webui")))
        XCTAssertEqual(listed?.sessionID, "tip"); XCTAssertEqual(listed?.profile, "row-profile")
        let replacement = HermesConnection(connection: http.connection, configuration: HermesHostFixture.configuration { _ in nil })
        XCTAssertNotEqual(listed?.id, HermesTerminalTarget.listed(row, server: http.connection.address, http: replacement, profile: "selected")?.id)
        var covers = HermesSessionListCovers(); covers.terminal = listed
        XCTAssertTrue(covers.isCoveredByScreen); covers.bringForward(); XCTAssertNil(covers.terminal)
    }

    func testArrowSequencesUseApplicationCursorMode() {
        XCTAssertEqual(Data(TerminalArrow.up.bytes(applicationCursor: false)), Data("\u{1b}[A".utf8))
        XCTAssertEqual(Data(TerminalArrow.left.bytes(applicationCursor: true)), Data("\u{1b}OD".utf8))
    }

    func testCapabilitiesAreSharedByConnectionAndInvalidatedAfterProvisioning() async throws {
        let http = target().http
        _ = await HermesTerminalClient.isAvailable(on: http)
        _ = await HermesTerminalClient.isAvailable(on: http)
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/hermex-push/capabilities"), 1)
        http.invalidateCompanionRoutes()
        _ = await HermesTerminalClient.isAvailable(on: http)
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/hermex-push/capabilities"), 2)
    }

    func testEveryAttachMintsANewTicketWithItsOwnServerHeaders() async throws {
        let configuration = HermesHostFixture.configuration { request in
            if request.url!.path == "/api/auth/ws-ticket" { return .json(200, .object(["ticket": .string(UUID().uuidString)])) }
            return nil
        }
        let a = target(configuration: configuration)
        let b = BotConnection(id: UUID(), name: "B", address: URL(string: "https://b.example")!, username: "test", password: "test", installID: "b")
        let httpB = HermesConnection(connection: b, configuration: configuration)
        let first = try await a.http.terminalUpgrade(sessionID: "chat", profile: "default", size: TerminalSize())
        let second = try await a.http.terminalUpgrade(sessionID: "chat", profile: "default", size: TerminalSize())
        let other = try await httpB.terminalUpgrade(sessionID: "chat", profile: "default", size: TerminalSize())
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(first.url?.host, "terminal.example"); XCTAssertEqual(other.url?.host, "b.example")
        XCTAssertEqual(first.value(forHTTPHeaderField: "X-Test"), "terminal-only")
        XCTAssertEqual(HermesHostFixture.count("/api/auth/ws-ticket"), 3)
    }

    func testAcceptedValidationCloseDoesNotSpendAnotherTicket() async {
        let refused = expectation(description: "validation refused"), socket = TerminalTestSocket()
        socket.onPing = { [weak socket] in
            socket?.finish(code: 4400)
            throw URLError(.networkConnectionLost)
        }
        var opens = 0
        let client = HermesTerminalClient(target: target(), options: .init(socketFactory: { _ in
            opens += 1; return socket
        }))
        client.start(size: TerminalSize()) { event in
            if case .failed(let failure) = event {
                XCTAssertEqual(failure, .refused)
                XCTAssertFalse(failure.canReconnect)
                refused.fulfill()
            }
        }
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(HermesHostFixture.count("/api/auth/ws-ticket"), 1)
        client.stop()
    }

    func test403GetsOneFreshTicketBeforeFailure() async {
        let refused = expectation(description: "refused"), first = TerminalTestSocket(), second = TerminalTestSocket()
        first.onPing = { throw BotFailure.upgradeRefused(403) }; second.onPing = first.onPing
        var count = 0
        let client = HermesTerminalClient(target: target(), options: .init(socketFactory: { _ in
            count += 1; return count == 1 ? first : second
        }))
        client.start(size: TerminalSize()) { event in
            if case .failed(let error) = event { XCTAssertEqual(error, .connection(.upgradeRefused(403))); refused.fulfill() }
            else { XCTFail("Refused socket admitted input") }
        }
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertEqual(count, 2); client.stop()
    }

    func testControlFramesAndUnknownTextKeepTheirOrder() async {
        let clientSocket = TerminalTestSocket(), live = expectation(description: "live")
        let client = HermesTerminalClient(target: target(), options: .init(socketFactory: { _ in clientSocket }))
        var events: [HermesTerminalEvent] = []
        client.start(size: TerminalSize()) { event in
            events.append(event)
            if event == .output(Data("live".utf8)) { live.fulfill() }
        }
        clientSocket.replay("history", unseen: 3)
        clientSocket.push(.string("unknown")); clientSocket.push(.data(Data("live".utf8)))
        await fulfillment(of: [live], timeout: 5)
        XCTAssertEqual(events, [.opened, .replayStarted(unseen: 3), .output(Data("history".utf8)), .replayEnded, .output(Data("live".utf8))])
        client.stop()
    }

    func testPongOrOutputKeepsTheSocketAliveAndQuietSocketTimesOut() async {
        let socket = TerminalTestSocket(), output = expectation(description: "output"), failed = expectation(description: "quiet deadline")
        let tick = expectation(description: "next tick"); tick.expectedFulfillmentCount = 2
        var clock: [CheckedContinuation<Void, Error>] = [], pongs: [CheckedContinuation<Void, Error>] = []
        socket.onPing = { try await withCheckedThrowingContinuation { pongs.append($0) } }
        let client = HermesTerminalClient(target: target(), options: .init(sleep: { _ in
            tick.fulfill(); try await withCheckedThrowingContinuation { clock.append($0) }
        }, socketFactory: { _ in socket }))
        let firstTick = expectation(description: "first tick")
        socket.onReceive = { firstTick.fulfill() }
        client.start(size: TerminalSize()) { event in
            if case .output = event { output.fulfill() }
            if event == .failed(.lost) { failed.fulfill() }
        }
        await fulfillment(of: [firstTick], timeout: 5)
        socket.onReceive = nil
        socket.push(.data(Data("alive".utf8)))
        await fulfillment(of: [output], timeout: 5)
        clock.removeFirst().resume()
        await fulfillment(of: [tick], timeout: 5)
        clock.removeFirst().resume()
        await fulfillment(of: [failed], timeout: 5)
        pongs.forEach { $0.resume(throwing: CancellationError()) }; client.stop()
    }

    func testRetiredConnectionRejectsInputAndOutput() async {
        let socket = TerminalTestSocket(), opened = expectation(description: "opened"), retired = expectation(description: "retired")
        let target = target()
        let actual = HermesTerminalClient(target: target, options: .init(socketFactory: { _ in socket }))
        actual.start(size: TerminalSize()) { event in
            if event == .opened { opened.fulfill() }
            if case .output = event { XCTFail("Retired connection fed the terminal") }
            if event == .failed(.connection(.stale)) { retired.fulfill() }
        }
        await fulfillment(of: [opened], timeout: 5)
        target.http.retire()
        var sent = false
        socket.onSend = { _ in sent = true }
        actual.send(.data(Data("old".utf8)))
        socket.push(.data(Data("old server".utf8)))
        await fulfillment(of: [retired], timeout: 5)
        XCTAssertFalse(sent)
        actual.stop()
    }

    func testStatusDoesNotInventRunningForAnUnknownReply() async throws {
        let configuration = HermesHostFixture.configuration { request in
            if request.url!.path.hasSuffix("/terminal/shell/status") { return .json(200, .object(["future": .bool(true)])) }
            return nil
        }
        let status = try await HermesTerminalClient(target: target(configuration: configuration)).status()
        XCTAssertNil(status)
    }

    private func target(configuration: URLSessionConfiguration = HermesHostFixture.configuration { _ in nil }) -> HermesTerminalTarget {
        var record = BotConnection(id: UUID(), name: "Test", address: URL(string: "https://terminal.example")!, username: "test", password: "test", installID: "terminal-test")
        record.headers = [CustomHeader(name: "X-Test", value: "terminal-only")]
        return HermesTerminalTarget(server: record.address, http: HermesConnection(connection: record, configuration: configuration), sessionID: "chat", profile: "default")
    }
}

@MainActor final class TerminalViewModelTests: XCTestCase {
    override func tearDown() { HermesHostFixture.reset(); super.tearDown() }

    func testUnseenStartupQueriesAreAnsweredAndSeenHistoryIsSuppressed() async {
        let fixture = TerminalModelFixture(), rendered = expectation(description: "rendered")
        rendered.expectedFulfillmentCount = 2
        let query = "\u{1b}[6n", answer = Data("\u{1b}[1;1R".utf8)
        fixture.display.onFeed = { bytes in
            if String(decoding: bytes, as: UTF8.self) == query { fixture.model.send(answer); rendered.fulfill() }
        }
        let sent = expectation(description: "startup and live queries answered")
        sent.expectedFulfillmentCount = 2
        fixture.socket.onSend = { if case .data(let data) = $0 { XCTAssertEqual(data, answer); sent.fulfill() } }
        fixture.socket.replay(query + query, unseen: query.utf8.count)
        fixture.start()
        await fulfillment(of: [rendered], timeout: 5)
        fixture.display.onFeed = { bytes in
            if String(decoding: bytes, as: UTF8.self) == query { fixture.model.send(answer) }
        }
        fixture.socket.push(.data(Data(query.utf8)))
        await fulfillment(of: [sent], timeout: 5)
        XCTAssertEqual(fixture.display.resets, 1)
        fixture.model.suspend()
    }

    func testFailedReconnectPreservesDisplayUntilReplayStarts() async {
        let fixture = TerminalModelFixture(), rendered = expectation(description: "initial")
        fixture.display.onFeed = { _ in rendered.fulfill() }
        fixture.socket.replay("prompt", unseen: 0); fixture.start()
        await fulfillment(of: [rendered], timeout: 5)
        fixture.model.suspend()
        fixture.model.reconnect()
        XCTAssertEqual(String(decoding: fixture.display.bytes, as: UTF8.self), "prompt")
        XCTAssertEqual(fixture.display.resets, 1)
        fixture.model.suspend()
    }

    func testDetachedExitRequiresStartNewShell() async {
        let checked = expectation(description: "status")
        let fixture = TerminalModelFixture(configuration: HermesHostFixture.configuration { request in
            if request.url!.path.hasSuffix("/terminal/shell/status") { checked.fulfill(); return .json(200, .object(["running": .bool(false)])) }
            return nil
        })
        let rendered = expectation(description: "initial")
        fixture.display.onFeed = { _ in rendered.fulfill() }
        fixture.socket.replay("prompt", unseen: 0); fixture.start()
        await fulfillment(of: [rendered], timeout: 5)
        fixture.model.suspend(); fixture.model.activate()
        let changed = expectation(description: "status consumed")
        withObservationTracking { _ = fixture.model.state } onChange: { changed.fulfill() }
        await fulfillment(of: [checked, changed], timeout: 5)
        XCTAssertEqual(fixture.model.state, .failed(.exited)); XCTAssertEqual(fixture.opens, 1)
        fixture.model.suspend()
    }

    func testReplayFeedingYieldsAndCancellationDropsRemainingBytes() async {
        let fixture = TerminalModelFixture(), first = expectation(description: "first piece")
        fixture.display.onFeed = { _ in fixture.model.suspend(); first.fulfill() }
        fixture.socket.replay(String(repeating: "x", count: 100000), unseen: 0); fixture.start()
        await fulfillment(of: [first], timeout: 5)
        XCTAssertEqual(fixture.display.bytes.count, 16384)
        XCTAssertEqual(fixture.model.state, .paused)
    }

    func testUnframedHostAnswersLiveQueries() async {
        let fixture = TerminalModelFixture(), sent = expectation(description: "query answer")
        let query = Data("\u{1b}[6n".utf8), answer = Data("\u{1b}[1;1R".utf8)
        fixture.display.onFeed = { _ in fixture.model.send(answer) }
        fixture.socket.onSend = { if case .data(let data) = $0 { XCTAssertEqual(data, answer); sent.fulfill() } }
        fixture.socket.push(.data(query)); fixture.start()
        await fulfillment(of: [sent], timeout: 5)
        XCTAssertEqual(fixture.display.resets, 1)
        fixture.model.suspend()
    }

    func testExitAndReplacementRemainExplicitAfterBackgrounding() async {
        for code in [4409, 4410] {
            let fixture = TerminalModelFixture(), ready = expectation(description: "ready")
            fixture.display.onFeed = { _ in ready.fulfill() }
            fixture.socket.replay("ready", unseen: 0); fixture.start()
            await fulfillment(of: [ready], timeout: 5)
            let closed = expectation(description: "closed")
            withObservationTracking { _ = fixture.model.state } onChange: { closed.fulfill() }
            fixture.socket.finish(code: code)
            await fulfillment(of: [closed], timeout: 5)
            fixture.model.suspend(); fixture.model.activate()
            XCTAssertEqual(fixture.opens, 1)
            XCTAssertEqual(fixture.model.state, .failed(code == 4410 ? .exited : .replaced))
            fixture.model.suspend()
        }
    }

    func testFailedOpensBackOffAndStopAfterSixAutomaticAttempts() async {
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
        var wakes: [CheckedContinuation<Void, Error>] = []
        let waiting = (0..<6).map { expectation(description: "backoff \($0)") }
        var observed: [Duration] = []
        let fixture = TerminalModelFixture(sleep: { delay in
            observed.append(delay)
            waiting[observed.count - 1].fulfill()
            try await withCheckedThrowingContinuation { wakes.append($0) }
        })
        let stopped = expectation(description: "last failure")
        fixture.factory = {
            let socket = TerminalTestSocket()
            socket.onPing = {
                if fixture.opens == 7 {
                    withObservationTracking { _ = fixture.model.state } onChange: { stopped.fulfill() }
                }
                throw URLError(.notConnectedToInternet)
            }
            return socket
        }
        fixture.start()
        for index in 0..<6 {
            await fulfillment(of: [waiting[index]], timeout: 5)
            wakes.removeFirst().resume()
        }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(observed, delays)
        XCTAssertEqual(fixture.opens, 7)
        XCTAssertEqual(fixture.model.state, .failed(.lost))
        fixture.model.suspend()
    }

    func testModelReleaseCancelsItsSocket() async {
        var fixture: TerminalModelFixture? = TerminalModelFixture()
        let socket = fixture!.socket, writing = expectation(description: "pending write")
        var pending: CheckedContinuation<Void, Error>?
        socket.onWrite = {
            try await withCheckedThrowingContinuation { pending = $0; writing.fulfill() }
        }
        defer { pending?.resume(throwing: CancellationError()) }
        fixture!.start(); await fulfillment(of: [writing], timeout: 5)
        fixture = nil
        XCTAssertTrue(socket.cancelled)
    }
}

@MainActor private final class TerminalModelFixture {
    let socket = TerminalTestSocket()
    let display = TerminalTestDisplay()
    var model: TerminalViewModel!
    var opens = 0
    var factory: (() -> TerminalTestSocket)?
    init(sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }, configuration: URLSessionConfiguration = HermesHostFixture.configuration { _ in nil }) {
        let record = BotConnection(id: UUID(), name: "Test", address: URL(string: "https://terminal.example")!, username: "test", password: "test", installID: "terminal-test")
        let target = HermesTerminalTarget(server: record.address, http: HermesConnection(connection: record, configuration: configuration), sessionID: "chat", profile: "default")
        let client = HermesTerminalClient(target: target, options: .init(socketFactory: { [weak self] _ in
            self!.opens += 1; return self!.factory?() ?? self!.socket
        }))
        model = TerminalViewModel(client: client, sleep: sleep)
    }
    func start() { model.attach(display); model.activate() }
}

@MainActor private final class TerminalTestDisplay: TerminalDisplay {
    var resets = 0
    var bytes: [UInt8] = []
    var onFeed: ((ArraySlice<UInt8>) -> Void)?
    func reset() { resets += 1; bytes = [] }
    func feed(_ data: ArraySlice<UInt8>) { bytes.append(contentsOf: data); onFeed?(data) }
}

private final class TerminalTestSocket: KanbanSocket, @unchecked Sendable {
    let channel = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>.makeStream()
    private let lock = NSLock()
    private var code = 0
    var cancelled = false
    var closeCode: Int { lock.withLock { code } }
    var onSend: ((URLSessionWebSocketTask.Message) -> Void)?
    var onWrite: (@MainActor () async throws -> Void)?
    var onPing: (@MainActor () async throws -> Void)?
    var onReceive: (@MainActor () -> Void)?
    func receive() async throws -> URLSessionWebSocketTask.Message {
        await onReceive?()
        var iterator = channel.stream.makeAsyncIterator()
        guard let message = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        return message
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { onSend?(message); try await onWrite?() }
    func ping() async throws { try await onPing?() }
    func cancel() { cancelled = true; channel.continuation.finish(throwing: CancellationError()) }
    func push(_ message: URLSessionWebSocketTask.Message) { channel.continuation.yield(message) }
    func replay(_ text: String, unseen: Int) {
        push(.string("{\"type\":\"replay\",\"state\":\"start\",\"unseen\":\(unseen)}"))
        push(.data(Data(text.utf8)))
        push(.string(#"{"type":"replay","state":"end"}"#))
    }
    func finish(code: Int) {
        lock.withLock { self.code = code }
        channel.continuation.finish(throwing: URLError(.networkConnectionLost))
    }
}
