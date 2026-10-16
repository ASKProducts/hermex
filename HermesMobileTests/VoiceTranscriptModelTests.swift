import XCTest
@testable import HermesMobile

@MainActor final class VoiceTranscriptModelTests: XCTestCase {
    private func texts(_ turn: ChatTurn?) -> [String] {
        (turn?.segments ?? []).map {
            switch $0.kind {
            case .text(let t): return "text:\(t.string)"
            case .thinking(let t): return "thinking:\(t.string)"
            case .tool(let tool): return "tool:\(tool.id):\(tool.name):\(tool.state)"
            case .steer(let s): return "steer:\(s)"
            case .append(let a): return "append:\(a.ordinal)"
            case .delegationCompletion(let c): return "delegation-completion:\(c.report)"
            }
        }
    }

    private static func savedRows(_ json: String) throws -> [ChatMessage] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([ChatMessage].self, from: Data(json.utf8))
    }

    /// One saved turn: user 11, assistant 12 calling t1, tool 13, reply 14.
    private static let savedTurnJSON = """
    [
     {"id": 11, "role": "user", "content": "what is in my home folder", "timestamp": 100.0},
     {"id": 12, "role": "assistant", "content": "", "timestamp": 101.0,
      "tool_calls": [{"id": "t1", "type": "function", "function": {"name": "terminal", "arguments": "{\\"command\\": \\"ls ~\\"}"}}]},
     {"id": 13, "role": "tool", "content": "Desktop Documents", "tool_call_id": "t1", "tool_name": "terminal", "timestamp": 102.0},
     {"id": 14, "role": "assistant", "content": "Three folders.", "timestamp": 103.0, "finish_reason": "stop"}
    ]
    """

    // MARK: Mapper

    private static func duplicateSourceIdentities(_ turns: [ChatTurn]) -> Int {
        let ids = turns.flatMap { [TranscriptItems.turnKey($0)] + $0.segments.map { $0.id.rawValue } }
        return Dictionary(grouping: ids, by: { $0 }).values.filter { $0.count > 1 }.count
    }

    func testMapperMapsGatewayFrames() {
        XCTAssertEqual(VoiceTurnMapper.events(type: "message.delta", payload: .object(["text": .string("Hi")]), streamedReply: false),
                       [.token("Hi")])
        XCTAssertEqual(VoiceTurnMapper.events(type: "reasoning.delta", payload: .object(["text": .string("hmm")]), streamedReply: false),
                       [.reasoning("hmm")])
        XCTAssertEqual(VoiceTurnMapper.events(type: "thinking.delta", payload: .object(["text": .string("(°□°) reflecting...")]),
                                              streamedReply: false), [], "spinner text, not reasoning")
        let start = VoiceTurnMapper.events(type: "tool.start", payload: .object([
            "tool_id": .string("t1"), "name": .string("terminal"), "context": .string("ls ~"),
            "args": .object(["command": .string("ls ~")])
        ]), streamedReply: false)
        XCTAssertEqual(start, [.toolStarted(ToolStreamEvent(eventType: "tool.start", name: "terminal", preview: "ls ~",
                                                            args: ["command": .string("ls ~")], duration: nil, isError: nil,
                                                            stableID: "t1"))])
        let complete = VoiceTurnMapper.events(type: "tool.complete", payload: .object([
            "tool_id": .string("t1"), "name": .string("terminal"), "duration_s": .number(1.5), "summary": .string("ok")
        ]), streamedReply: true)
        XCTAssertEqual(complete, [.toolCompleted(ToolStreamEvent(eventType: "tool.complete", name: "terminal", preview: nil,
                                                                 args: nil, duration: 1.5, isError: nil, stableID: "t1"))])
        XCTAssertEqual(VoiceTurnMapper.events(type: "message.complete", payload: .object(["status": .string("complete"), "text": .string("Hi")]),
                                              streamedReply: true), [.done(DoneStreamEvent())])
        XCTAssertEqual(VoiceTurnMapper.events(type: "message.complete", payload: .object(["status": .string("complete"), "text": .string("Hi")]),
                                              streamedReply: false), [.token("Hi"), .done(DoneStreamEvent())])
        XCTAssertEqual(VoiceTurnMapper.events(type: "message.complete", payload: .object(["status": .string("interrupted")]),
                                              streamedReply: true), [.cancelled])
        XCTAssertEqual(VoiceTurnMapper.events(type: "message.complete", payload: .object(["status": .string("error"), "text": .string("boom")]),
                                              streamedReply: true), [.error("boom")])
        XCTAssertEqual(VoiceTurnMapper.events(type: "message.start", payload: .null, streamedReply: false), [])
        XCTAssertEqual(VoiceTurnMapper.events(type: "message.delta", payload: .object(["text": .string("")]), streamedReply: false), [])
        XCTAssertEqual(VoiceTurnMapper.events(type: "status.update", payload: .null, streamedReply: false), [])
    }

    func testMapperReadsToolErrorFlag() {
        let events = VoiceTurnMapper.events(type: "tool.complete", payload: .object([
            "tool_id": .string("t2"), "name": .string("terminal"), "error": .string("exit 1")
        ]), streamedReply: false)
        guard case .toolCompleted(let tool) = events.first else { return XCTFail("no completion") }
        XCTAssertEqual(tool.isError, true)
    }

    // MARK: Normal mode

    func testNormalTurnBuildsLiveTurnWithUserRowThatStays() {
        let model = VoiceTranscriptModel()
        var finished: [String] = []
        model.onTurnFinished = { finished.append($0) }
        model.userSent("what is in my home folder")
        XCTAssertEqual(model.liveUserMessage?.content, "what is in my home folder")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("tool.start", .object(["tool_id": .string("t1"), "name": .string("terminal"), "context": .string("ls ~")]))
        model.gatewayEvent("tool.complete", .object(["tool_id": .string("t1"), "name": .string("terminal")]))
        model.gatewayEvent("message.delta", .object(["text": .string("Three ")]))
        model.gatewayEvent("message.delta", .object(["text": .string("folders.")]))
        XCTAssertEqual(texts(model.liveTurn), ["tool:t1:terminal:done", "text:Three folders."])
        XCTAssertNotNil(model.activeRunID)
        XCTAssertNotNil(model.workingSince)
        model.gatewayEvent("message.complete", .object(["status": .string("complete"),
            "persisted_turn": .object(["complete": .bool(true), "user_row_id": .number(11),
                "row_ids": .array([.number(11), .number(12)]), "final_assistant_row_id": .number(12)])]))
        XCTAssertEqual(finished, ["voice:1"])
        XCTAssertNil(model.activeRunID, "a finished turn is no longer streaming")
        XCTAssertNil(model.workingSince)
        // The user's words stay as the turn's user row until the saved rows arrive.
        XCTAssertEqual(model.liveUserMessage?.content, "what is in my home folder")
        XCTAssertEqual(TranscriptItems.turnKey(model.liveTurn!), "run:voice:1")
    }

    func testSettleOntoSavedRowsPairsToolsAndKeepsTheTurnKey() throws {
        let model = VoiceTranscriptModel()
        model.userSent("what is in my home folder")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("tool.start", .object(["tool_id": .string("t1"), "name": .string("terminal")]))
        model.gatewayEvent("tool.complete", .object(["tool_id": .string("t1"), "name": .string("terminal")]))
        model.gatewayEvent("message.delta", .object(["text": .string("Three folders.")]))
        let liveIDs = model.liveTurn!.segments.map(\.id)
        model.gatewayEvent("message.complete", .object(["status": .string("complete")]))
        model.applySaved(try Self.savedRows(Self.savedTurnJSON), hasOlder: false, runID: "voice:1")
        XCTAssertNil(model.fold)
        XCTAssertNil(model.liveUserMessage)
        XCTAssertEqual(model.settledTurns.count, 1)
        let settled = model.settledTurns[0]
        XCTAssertEqual(settled.userMessageID, 11)
        XCTAssertEqual(TranscriptItems.turnKey(settled), "run:voice:1", "settled turn drawn under its live key")
        XCTAssertEqual(settled.segments.map(\.id), liveIDs, "every segment drawn under its live id")
        guard case .tool(let tool) = settled.segments.first?.kind else { return XCTFail("tool first") }
        XCTAssertEqual(tool.id, "t1")
    }

    /// The interrupted turn was drawn from local rows (`pos:` keys). When the refetch that
    /// settles the next turn brings the saved rows, that turn must keep the ids it was drawn
    /// under, as the chat's turns do (their aliases are keyed by saved ids): otherwise the
    /// collection's list changes in the same update and the settled reply (an equal item)
    /// is not re-hosted, losing its copy / time row.
    func testRefetchKeepsTheInterruptedTurnsDrawnIDsSoOnlyTheSettleChanges() throws {
        let model = VoiceTranscriptModel()
        model.userSent("tell me a story")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.delta", .object(["text": .string("Once upon")]))
        model.interrupt()
        model.userSent("what year is it")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.delta", .object(["text": .string("It's 2026.")]))
        model.gatewayEvent("message.complete", .object(["status": .string("complete")]))
        let drawn = { (turns: [ChatTurn]) in
            turns.flatMap { [TranscriptItems.turnKey($0)] + $0.segments.map { $0.id.rawValue } }
        }
        let before = drawn(model.settledTurns + [model.liveTurn].compactMap { $0 })
        let nativeBefore = ChatViewModel.transcriptMessages(from: VoiceTranscriptProjection.rows(model, mode: .full, filter: .all).all).map(\.renderID)
        let saved = try Self.savedRows("""
        [
         {"id": 21, "role": "user", "content": "tell me a story", "timestamp": 100.0},
         {"id": 22, "role": "assistant", "content": "Once upon", "timestamp": 101.0},
         {"id": 23, "role": "user", "content": "what year is it", "timestamp": 102.0},
         {"id": 24, "role": "assistant", "content": "It's 2026.", "timestamp": 103.0, "finish_reason": "stop"}
        ]
        """)
        XCTAssertTrue(model.applySaved(saved, hasOlder: false, runID: "voice:2"))
        XCTAssertEqual(drawn(model.settledTurns), before, "the settle re-keys nothing")
        XCTAssertEqual(ChatViewModel.transcriptMessages(from: VoiceTranscriptProjection.rows(model, mode: .full, filter: .all).all).map(\.renderID), nativeBefore)
    }

    func testRefetchOfAnOlderRunDoesNotDropTheTurnInFlight() throws {
        let model = VoiceTranscriptModel()
        model.userSent("first")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.complete", .object(["status": .string("complete"), "text": .string("One.")]))
        model.userSent("second")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.delta", .object(["text": .string("Tw")]))
        model.applySaved(try Self.savedRows(Self.savedTurnJSON), hasOlder: false, runID: "voice:1")
        XCTAssertEqual(model.liveUserMessage?.content, "second")
        XCTAssertEqual(texts(model.liveTurn), ["text:Tw"])
    }

    func testInterruptedTurnKeepsItsTextAndUserRow() {
        let model = VoiceTranscriptModel()
        model.userSent("tell me a story")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.delta", .object(["text": .string("Once upon")]))
        model.interrupt()
        XCTAssertEqual(model.liveTurn?.state, .interrupted(runID: "voice:1"))
        XCTAssertEqual(texts(model.liveTurn), ["text:Once upon"])
        // The server's own `interrupted` complete after our interrupt changes nothing.
        model.gatewayEvent("message.complete", .object(["status": .string("interrupted")]))
        XCTAssertEqual(texts(model.liveTurn), ["text:Once upon"])
        // The user's next words: the interrupted turn becomes rows, the new one opens.
        model.userSent("shorter please")
        XCTAssertEqual(model.liveUserMessage?.content, "shorter please")
        XCTAssertEqual(model.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(model.messages.map(\.content), ["tell me a story", "Once upon"])
        XCTAssertEqual(TranscriptItems.turnKey(model.settledTurns[0]), "run:voice:1")
        // Cut off: its reply row is partial (the chat's footer says "Interrupted").
        XCTAssertEqual(model.messages.map(\.isPartial), [false, true])
    }

    func testInterruptedMarkSurvivesTheRefetchOfSavedRows() throws {
        let model = VoiceTranscriptModel()
        model.userSent("what is in my home folder")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.delta", .object(["text": .string("Three")]))
        model.interrupt()
        model.userSent("never mind")
        // The dashboard's saved rows carry no partial mark; the turn's reply is marked anyway.
        let saved = try Self.savedRows(Self.savedTurnJSON)
        model.loadHistory(saved, hasOlder: false)
        XCTAssertEqual(model.messages.map(\.isPartial), [false, false, false, true])
        // A finished turn's rows are not marked.
        XCTAssertEqual(VoiceTranscriptModel.markingInterrupted(saved, userTexts: []).map(\.isPartial), [false, false, false, false])
        XCTAssertEqual(VoiceTranscriptModel.markingInterrupted(saved, userTexts: ["something else"]).map(\.isPartial),
                       [false, false, false, false])
    }

    func testWordsSentWhileATurnRunsOpenTheNextTurn() {
        let model = VoiceTranscriptModel()
        model.userSent("first")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.delta", .object(["text": .string("Working")]))
        model.userSent("and also this")
        XCTAssertEqual(model.liveUserMessage?.content, "first", "the running turn keeps its own user row")
        model.gatewayEvent("message.complete", .object(["status": .string("complete")]))
        model.gatewayEvent("message.start", .null)
        XCTAssertEqual(model.liveUserMessage?.content, "and also this")
        XCTAssertEqual(model.messages.map(\.content), ["first", "Working"])
    }

    func testFramesWithoutAStartOpenATurn() {
        let model = VoiceTranscriptModel()
        model.gatewayEvent("message.delta", .object(["text": .string("Resumed")]))
        XCTAssertEqual(texts(model.liveTurn), ["text:Resumed"])
        XCTAssertNil(model.liveUserMessage)
    }

    // MARK: GPT-Live

    func testLiveExchangeBecomesLocalRowsDrawnUnderItsLiveIDs() {
        let model = VoiceTranscriptModel()
        model.liveUserSpeech("What's the", startsSegment: true)
        model.liveUserSpeech(" weather", startsSegment: false)
        XCTAssertEqual(model.liveUserMessage?.content, "What's the weather")
        model.liveAssistantSpeech("Let me check.")
        model.delegationStarted(id: "d1", prompt: "weather in SF")
        model.delegatedEvent("tool.start", .object(["tool_id": .string("w1"), "name": .string("web_search")]))
        model.delegatedEvent("tool.complete", .object(["tool_id": .string("w1"), "name": .string("web_search")]))
        model.delegationFinished(id: "d1")
        model.liveAssistantSpeech(" It's sunny.")
        XCTAssertEqual(texts(model.liveTurn), ["text:Let me check.", "tool:delegation:d1:Hermes:done",
                                                "tool:w1:web_search:done", "text: It's sunny."])
        let liveIDs = model.liveTurn!.segments.map(\.id)
        model.liveUserSpeech("Thanks", startsSegment: true)
        XCTAssertEqual(model.messages.map(\.role), ["user", "assistant", "tool", "tool", "assistant"])
        XCTAssertEqual(model.messages[0].content, "What's the weather")
        XCTAssertEqual(model.messages[1].content, "Let me check.")
        XCTAssertEqual(model.messages[4].content, " It's sunny.")
        XCTAssertEqual(model.settledTurns.count, 1)
        let settled = model.settledTurns[0]
        XCTAssertEqual(TranscriptItems.turnKey(settled), "run:live:1")
        XCTAssertEqual(Set(settled.segments.map(\.id)), Set(liveIDs), "local rows drawn under the live ids")
        XCTAssertEqual(model.liveUserMessage?.content, "Thanks")
        XCTAssertEqual(TranscriptItems.turnKey(model.liveTurn!), "run:live:2")
    }

    func testRefetchReplacesLocalRows() throws {
        let model = VoiceTranscriptModel()
        model.liveUserSpeech("Hi", startsSegment: true)
        model.liveAssistantSpeech("Hello.")
        model.finishExchange()
        XCTAssertEqual(model.messages.count, 2)
        model.loadHistory(try Self.savedRows(Self.savedTurnJSON), hasOlder: false)
        XCTAssertEqual(model.messages.compactMap(\.serverID), [11, 12, 13, 14])
        XCTAssertEqual(model.settledTurns.count, 1)
        XCTAssertEqual(TranscriptItems.turnKey(model.settledTurns[0]), "msg:11")
    }

    // MARK: History, modes

    func testHistoryAboveVoiceTurnsAndOlderPagePrepends() throws {
        let model = VoiceTranscriptModel()
        let rows = try Self.savedRows(Self.savedTurnJSON)
        model.loadHistory(Array(rows[2...]), hasOlder: true)
        XCTAssertTrue(model.hasOlder)
        model.prependOlder(Array(rows[..<2]), hasOlder: false)
        XCTAssertFalse(model.hasOlder)
        XCTAssertEqual(model.messages.compactMap(\.serverID), [11, 12, 13, 14])
        XCTAssertEqual(model.settledTurns.count, 1)
        model.userSent("and now")
        XCTAssertEqual(model.settledTurns.count, 1, "the voice turn is live, below the history")
        XCTAssertEqual(model.liveUserMessage?.content, "and now")
    }

    func testCurrentExchangeSlicesRowsAndKeepsIndicesValid() throws {
        let model = VoiceTranscriptModel()
        model.loadHistory(try Self.savedRows(Self.savedTurnJSON), hasOlder: false)
        model.userSent("second question")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.delta", .object(["text": .string("Answer.")]))
        // In flight: only the live turn.
        var shown = model.display(.current)
        XCTAssertEqual(shown.turns, [])
        XCTAssertEqual(shown.messages, [])
        model.interrupt()
        model.finishLocally()
        // Settled: the last turn only, rows sliced from its first row.
        shown = model.display(.current)
        XCTAssertEqual(shown.turns.count, 1)
        XCTAssertEqual(shown.messages.first?.content, "second question")
        let turn = shown.turns[0]
        let rows = try XCTUnwrap(turn.rows)
        XCTAssertEqual(rows.lowerBound, shown.offset)
        XCTAssertTrue(rows.allSatisfy { shown.messages.indices.contains($0 - shown.offset) })
        if let user = turn.userRowIndex { XCTAssertEqual(shown.messages[user - shown.offset].content, "second question") }
        // Full: everything.
        let full = model.display(.full)
        XCTAssertEqual(full.turns.count, 2)
        XCTAssertEqual(full.messages.count, model.messages.count)
    }

    /// Sim 10-02 00:08 (fix-think): Hermes thought before and after the voice's own line in one
    /// exchange (thinking, the voice's text, thinking, a tool). The local rows put both thoughts
    /// in one row's `reasoning`, drawn above the text, so at the exchange's end the second
    /// Thinking row moved up and its group re-keyed (the open group drew closed). The rows keep
    /// the live order: every live segment keeps its id and place, one Thinking row per step.
    func testLiveExchangeWithThinkingAroundTheVoicesTextSettlesInLiveOrder() {
        let model = VoiceTranscriptModel()
        model.liveUserSpeech("Check the temp folder", startsSegment: true)
        model.delegationStarted(id: "d1", prompt: "check temp")
        model.delegatedEvent("reasoning.delta", .object(["text": .string("Where is TMPDIR.")]))
        model.liveAssistantSpeech("Okay, checking.")
        model.delegatedEvent("reasoning.delta", .object(["text": .string("List by size.")]))
        model.delegatedEvent("tool.start", .object(["tool_id": .string("r1"), "name": .string("terminal")]))
        model.delegatedEvent("tool.complete", .object(["tool_id": .string("r1"), "name": .string("terminal")]))
        model.delegatedEvent("reasoning.delta", .object(["text": .string("Pick the oldest.")]))
        model.delegationFinished(id: "d1")
        model.liveAssistantSpeech(" The oldest one.")
        let live = model.liveTurn!.segments.map(\.id)
        let liveTexts = texts(model.liveTurn)
        model.finishExchange()
        let settled = model.settledTurns[0]
        XCTAssertEqual(texts(settled), liveTexts, "same rows in the same order")
        XCTAssertEqual(settled.segments.map(\.id), live, "drawn under the live ids, in order")
        XCTAssertTrue(settled.steps.allSatisfy { step in
            step.segments.filter { if case .thinking = $0.kind { return true } else { return false } }.count <= 1
        })
        XCTAssertEqual(Self.duplicateSourceIdentities(model.settledTurns), 0)
    }

    /// Sim 10-02 00:25 (tip-think): the gateway's spinner (`thinking.delta` "(°□°) reflecting...",
    /// agent/turn_iteration_prep.py:272 through `thinking_callback`) drew as a Thinking row and
    /// split the voice's line in two ("Okay, I'll check" / Thinking / "that now."). Spinner frames
    /// are not reasoning (`BotConversation` treats them as status): no row, the line stays whole.
    func testSpinnerFramesBetweenTextDeltasDrawNoThinkingRow() {
        let normal = VoiceTranscriptModel()
        normal.userSent("check the temp folder")
        normal.gatewayEvent("message.start", .null)
        normal.gatewayEvent("message.delta", .object(["text": .string("Okay, I'll check")]))
        normal.gatewayEvent("thinking.delta", .object(["text": .string("(°□°) reflecting...")]))
        normal.gatewayEvent("thinking.delta", .object(["text": .string("(¬_¬) brainstorming...")]))
        normal.gatewayEvent("message.delta", .object(["text": .string(" that now.")]))
        XCTAssertEqual(texts(normal.liveTurn), ["text:Okay, I'll check that now."], "Normal")

        let live = VoiceTranscriptModel()
        live.liveUserSpeech("Check the temp folder", startsSegment: true)
        live.delegationStarted(id: "d1", prompt: "check temp")
        live.delegatedEvent("reasoning.delta", .object(["text": .string("Where is TMPDIR.")]))
        live.delegatedEvent("thinking.delta", .object(["text": .string("(°□°) reflecting...")]))
        live.liveAssistantSpeech("Okay, I'll check")
        live.delegatedEvent("thinking.delta", .object(["text": .string("(¬_¬) brainstorming...")]))
        live.liveAssistantSpeech(" that now.")
        XCTAssertEqual(texts(live.liveTurn), ["tool:delegation:d1:Hermes:running", "thinking:Where is TMPDIR.",
                                              "text:Okay, I'll check that now."], "GPT-Live")
    }

    func testLocalRowsCarryToolCallsAndResults() {
        var fold = ChatTurnLiveFold(runID: "live:9")
        fold.apply(seq: nil, event: .toolStarted(ToolStreamEvent(eventType: "tool.start", name: "Hermes", preview: "do it",
                                                                 args: ["a": .string("b")], duration: nil, isError: nil,
                                                                 stableID: "delegation:x")))
        fold.apply(seq: nil, event: .token("Done."))
        let rows = VoiceTranscriptModel.localRows(user: nil, turn: fold.turn, runID: "live:9", at: 1)
        XCTAssertEqual(rows.map(\.role), ["assistant", "tool", "assistant"])
        XCTAssertEqual(rows[1].toolCallId, "delegation:x")
        let turns = ChatTurn.turns(from: rows)
        let names: [String] = turns.flatMap(\.segments).compactMap {
            if case .tool(let tool) = $0.kind { return tool.name } else { return nil }
        }
        XCTAssertEqual(names, ["Hermes"])
    }
}
