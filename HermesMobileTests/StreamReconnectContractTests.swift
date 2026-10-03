import XCTest
@testable import HermesMobile

/// Contract tests for the riskiest streaming paths: disconnect → reconnect
/// with replayed tokens, server restart mid-stream, and replay of content the
/// client already rendered. Each test drives a real `ChatViewModel` (which
/// owns the replay dedup from PR #211) and a real `ChatStreamCoordinator`
/// through a full scripted wire sequence via `ScriptedSSEStreamingClient`.
final class StreamReconnectContractTests: APIClientTestCase {
    @MainActor
    func testColdRelaunchRestoresUnansweredSavedToolUntilReplayCompletion() async throws {
        try await assertSavedToolRecovery(reopen: false)
    }

    @MainActor
    func testLeaveAndReopenRestoresUnansweredSavedToolUntilReplayCompletion() async throws {
        try await assertSavedToolRecovery(reopen: true)
    }

    @MainActor
    func testLeaveAndReopenRestoresSavedToolsWhenServerOmitsMessageIDs() async throws {
        try await assertSavedToolRecovery(reopen: true, omitsMessageIDs: true)
    }

    @MainActor
    private func assertSavedToolRecovery(reopen: Bool, omitsMessageIDs: Bool = false) async throws {
        ChatViewModel.resetActiveStreamSnapshotsForTesting()
        defer { ChatViewModel.resetActiveStreamSnapshotsForTesting() }
        let stream = ScriptedSSEStreamingClient()
        let handler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            switch request.url?.path {
            case "/api/session":
                let json = """
                {"session":{"session_id":"session-abc","active_stream_id":"stream-123","messages":[
                    {"role":"user","content":"Old turn","message_id":"old-user"},
                    {"role":"assistant","content":"Old answer","message_id":"old-assistant","tool_calls":[
                        {"id":"old-tool","function":{"name":"terminal","arguments":"{}"}}]},
                    {"role":"user","content":"Run a slow command","message_id":"user-1"},
                    {"role":"assistant","content":"","message_id":"assistant-1","tool_calls":[
                        {"id":"finished-tool","function":{"name":"terminal","arguments":"{}"}},
                        {"id":"running-tool","function":{"name":"terminal","arguments":"{\\"command\\":\\"sleep 40\\"}"}}]},
                    {"role":"tool","tool_call_id":"finished-tool","content":""}
                ]}}
                """
                return apiTestJSONResponse(
                    omitsMessageIDs ? json.replacingOccurrences(of: ",\"message_id\":\"assistant-1\"", with: "") : json,
                    for: request
                )
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active":true,"stream_id":"stream-123","replay_available":true}"#, for: request
                )
            default:
                throw URLError(.badURL)
            }
        }
        var viewModel = try makeViewModel(streamClient: stream, handler: handler)
        await viewModel.loadMessages()
        await viewModel.reconnectStreamIfNeeded()
        var activeStream = stream
        if reopen {
            viewModel.suspendStreamForNavigation()
            activeStream = ScriptedSSEStreamingClient()
            viewModel = try makeViewModel(streamClient: activeStream, handler: handler)
            await viewModel.loadMessages()
            await viewModel.reconnectStreamIfNeeded()
        }
        XCTAssertEqual(viewModel.completedToolCallGroups.flatMap(\.toolCalls).first { $0.id == "old-tool" }?.isCompleted, true)
        XCTAssertEqual(viewModel.latestTurnToolCalls.first { $0.id == "finished-tool" }?.isCompleted, true)
        XCTAssertEqual(viewModel.latestTurnToolCalls.first { $0.id == "running-tool" }?.isCompleted, false)
        XCTAssertEqual(viewModel.latestTurnToolCalls.count, 2)
        let start = ToolStreamEvent(eventType: "tool.started", name: "terminal", preview: "sleep 40",
                                    args: ["command": .string("sleep 40")], duration: nil, isError: nil,
                                    stableID: "running-tool")
        activeStream.emit(.toolStarted(start), lastEventID: "stream-123:1")
        XCTAssertEqual(viewModel.latestTurnToolCalls.first { $0.id == "running-tool" }?.isCompleted, false)
        let completion = ToolStreamEvent(eventType: "tool.completed", name: "terminal", preview: "command finished",
                                         args: ["command": .string("sleep 40")], duration: 40, isError: false,
                                         stableID: "running-tool")
        activeStream.emit(.toolCompleted(completion), lastEventID: "stream-123:2")
        let completed = try XCTUnwrap(viewModel.latestTurnToolCalls.first { $0.id == "running-tool" })
        XCTAssertTrue(completed.isCompleted)
        XCTAssertEqual(completed.preview, "command finished")
        XCTAssertEqual(completed.duration, 40)
        XCTAssertEqual(completed.isError, false)
        XCTAssertEqual(viewModel.latestTurnToolCalls.count, 2)
        XCTAssertEqual(activeStream.droppedEventCount, 0)
    }

    @MainActor
    func testFinishedSavedTurnKeepsUnansweredLegacyToolsCompleted() async throws {
        ChatViewModel.resetActiveStreamSnapshotsForTesting()
        let stream = ScriptedSSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: stream) { request in
            return apiTestJSONResponse("""
            {"session":{"session_id":"session-abc","messages":[
                {"role":"user","content":"Earlier request","message_id":"user-1"},
                {"role":"assistant","content":"Done","message_id":"assistant-1","tool_calls":[
                    {"id":"tool-1","function":{"name":"terminal","arguments":"{}"}}]}
            ]}}
            """, for: request)
        }
        await viewModel.loadMessages()
        XCTAssertEqual(viewModel.latestTurnToolCalls.map(\.isCompleted), [true])
        XCTAssertNil(viewModel.activeStreamID)
    }

    // MARK: - Scenario 1: reconnect with overlapping replayed tokens (#201 regression guard)

    @MainActor
    func testReconnectWithOverlappingReplayRendersEachTokenExactlyOnce() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.transportError("The network connection was lost."))
            ],
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.token("charlie "), lastEventID: "stream-123:3"),
                .init(.token("delta."), lastEventID: "stream-123:4"),
                .init(.done(DoneStreamEvent())),
                .init(.streamEnd)
            ]
        ])
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active": false, "stream_id": "stream-123", "replay_available": true}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    #"{"session": {"session_id": "session-abc", "title": "Planning"}}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo "])
        XCTAssertTrue(viewModel.isActiveStreamConnectionSuspended)

        // The transport error schedules an async reconnect; the status probe
        // reports the stream inactive with a replay journal available.
        try await waitUntil { streamClient.startedURLs.count == 2 }

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let query = queryDictionary(of: replayURL)
        XCTAssertEqual(replayURL.path, "/api/chat/stream")
        XCTAssertEqual(query["stream_id"], "stream-123")
        XCTAssertEqual(query["replay"], "1")
        XCTAssertEqual(query["after_seq"], "2")

        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo charlie delta."])
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(streamClient.droppedEventCount, 0)
    }

    // MARK: - Scenario 2: server restart mid-stream (no replay journal)

    @MainActor
    func testServerRestartMidStreamRecoversToConsistentCompletedState() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.transportError("The network connection was lost."))
            ]
        ])
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                // A restarted server has neither the live stream nor its replay journal.
                return apiTestJSONResponse(
                    #"{"active": false, "stream_id": "stream-123", "replay_available": false}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "Alpha bravo charlie delta.",
                        "timestamp": 1770000101,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo "])
        XCTAssertTrue(viewModel.isActiveStreamConnectionSuspended)

        // The async reconnect probe finds the stream gone, refreshes the
        // transcript, and completes the response from the server copy.
        try await waitUntil { viewModel.activeStreamID == nil }

        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(
            viewModel.messages.compactMap(\.content),
            ["Keep working", "Alpha bravo charlie delta."]
        )
        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo charlie delta."])
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertNil(viewModel.streamingAssistantMessageID)
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(streamClient.droppedEventCount, 0)
    }

    // MARK: - Scenario 3: replay arriving after the response already rendered locally

    @MainActor
    func testReplayAfterStreamAlreadyCompletedLocallyIsIgnoredCleanly() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo."), lastEventID: "stream-123:2")
            ],
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo."), lastEventID: "stream-123:2"),
                .init(.done(DoneStreamEvent())),
                .init(.streamEnd)
            ]
        ])
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active": false, "stream_id": "stream-123", "replay_available": true}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    #"{"session": {"session_id": "session-abc", "title": "Planning"}}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo."])

        // The app backgrounds after the full text rendered but before the
        // completion events arrive; on foreground the replay re-sends the
        // entire already-rendered response plus the completion.
        viewModel.suspendStreamForBackground()
        await viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(streamClient.startedURLs.count, 2)
        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let query = queryDictionary(of: replayURL)
        XCTAssertEqual(query["replay"], "1")
        XCTAssertEqual(query["after_seq"], "2")

        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo."])
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(streamClient.droppedEventCount, 0)
    }

    @MainActor
    func testDuplicateStartReconnectsExistingStreamWithoutKeepingOptimisticMessage() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token(" continuation"), lastEventID: "stream-existing:1")
        ]])
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return self.jsonResponse(
                    #"{"error":"session already has an active stream","active_stream_id":"stream-existing"}"#,
                    statusCode: 409,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-existing",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Already accepted",
                        "timestamp": 1770000100,
                        "message_id": "user-existing"
                      },
                      {
                        "role": "assistant",
                        "content": "Partial answer",
                        "timestamp": 1770000101,
                        "message_id": "assistant-existing"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Duplicate request")

        XCTAssertFalse(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-existing")
        XCTAssertEqual(
            viewModel.messages.compactMap(\.content),
            ["Already accepted", "Partial answer"]
        )
        XCTAssertEqual(viewModel.streamingAssistantMessageID, "assistant-existing")
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(queryDictionary(of: try XCTUnwrap(streamClient.startedURLs.first))["stream_id"], "stream-existing")

        streamClient.playArmedConnectionScript()
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(
            assistantContents(of: viewModel),
            ["Partial answer continuation"]
        )
    }

    @MainActor
    func testDuplicateStartReconnectDoesNotReusePreviousTurnAssistantAnchor() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("new response"), lastEventID: "stream-existing:1")
        ]])
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return self.jsonResponse(
                    #"{"error":"session already has an active stream","active_stream_id":"stream-existing"}"#,
                    statusCode: 409,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-existing",
                    "messages": [
                      {
                        "role": "assistant",
                        "content": "Previous response",
                        "timestamp": 1770000099,
                        "message_id": "assistant-previous"
                      },
                      {
                        "role": "user",
                        "content": "Already accepted",
                        "timestamp": 1770000100,
                        "message_id": "user-existing"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Duplicate request")

        XCTAssertFalse(didStart)
        XCTAssertEqual(
            viewModel.messages.compactMap(\.content),
            ["Previous response", "Already accepted"]
        )
        XCTAssertNil(viewModel.streamingAssistantMessageID)

        streamClient.playArmedConnectionScript()
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(
            assistantContents(of: viewModel),
            ["Previous response", "new response"]
        )
    }

    func testOnlySpecificMissingStream404IsTerminal() {
        XCTAssertTrue(
            APIError.http(statusCode: 404, body: #"{"error":"stream not found"}"#).indicatesMissingStream
        )
        XCTAssertFalse(
            APIError.http(statusCode: 404, body: #"{"error":"endpoint not found"}"#).indicatesMissingStream
        )
        XCTAssertFalse(APIError.http(statusCode: 404, body: nil).indicatesMissingStream)
    }

    @MainActor
    func testMissingStatusAfterDisconnectFinalizesInsteadOfRetryingStaleStream() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Partial"), lastEventID: "stream-123:1"),
            .init(.transportError("Connection lost"))
        ]])
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id":"session-abc","stream_id":"stream-123"}"#, for: request)
            case "/api/chat/stream/status":
                return self.jsonResponse(#"{"error":"stream not found"}"#, statusCode: 404, for: request)
            case "/api/session":
                return apiTestJSONResponse(#"{"session":{"session_id":"session-abc","title":"Planning","messages":[]}}"#, for: request)
            default:
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()
        try await waitUntil { viewModel.activeStreamID == nil }

        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertNil(viewModel.sendErrorMessage)
    }

    private func jsonResponse(
        _ json: String,
        statusCode: Int,
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(json.utf8)
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(
        streamClient: ScriptedSSEStreamingClient,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-abc",
              "title": "Planning",
              "workspace": "/tmp/workspace"
            }
            """.utf8)
        )

        let viewModel = ChatViewModel(
            session: session,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient(),
            btwStreamClient: ScriptedSSEStreamingClient()
        )
        streamClient.flushPendingStreamingContent = { [weak viewModel] in
            viewModel?.flushPendingStreamingContent()
        }
        return viewModel
    }

    @MainActor
    private func assistantContents(of viewModel: ChatViewModel) -> [String] {
        viewModel.messages.filter { $0.role == "assistant" }.compactMap(\.content)
    }

    private func queryDictionary(of url: URL) -> [String: String] {
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
