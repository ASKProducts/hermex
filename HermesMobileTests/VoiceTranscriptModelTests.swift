import XCTest
@testable import HermesMobile

extension VoiceTurn {
    /// The turn's parts as tests read them: `text:`, `thinking:`, `tool:<id>:<name>:<running|done|failed>`,
    /// `steer:`, `append:<ordinal>`.
    var described: [String] {
        parts.map { part in
            switch part {
            case .text(let text): return "text:\(text)"
            case .thinking(let text): return "thinking:\(text)"
            case .steer(let text, _): return "steer:\(text)"
            case .append(let observation): return "append:\(observation.ordinal)"
            case .tool(let id):
                let tool = tools.first { $0.id == id }
                let state = tool?.isCompleted != true ? "running" : tool?.isError == true ? "failed" : "done"
                return "tool:\(id):\(tool?.name ?? ""):\(state)"
            }
        }
    }
}

@MainActor final class VoiceTranscriptModelTests: XCTestCase {
    private static func row(_ id: Int, _ role: String, _ content: String, _ extra: [String: BotJSON] = [:]) -> BotJSON {
        var fields: [String: BotJSON] = ["id": .number(Double(id)), "role": .string(role), "content": .string(content),
                                         "timestamp": .number(Double(100 + id))]
        fields.merge(extra) { _, new in new }
        return .object(fields)
    }

    /// One saved turn: user 11, assistant 12 calling t1, tool 13, reply 14.
    private static let savedTurn: [BotJSON] = [
        row(11, "user", "what is in my home folder"),
        row(12, "assistant", "", ["tool_calls": .array([.object(["id": .string("t1"), "type": .string("function"),
            "function": .object(["name": .string("terminal"), "arguments": .string("{\"command\": \"ls ~\"}")])])])]),
        row(13, "tool", "Desktop Documents", ["tool_call_id": .string("t1")]),
        row(14, "assistant", "Three folders.")
    ]

    private static let receipt: BotJSON = .object(["complete": .bool(true), "user_row_id": .number(11),
                                                   "row_ids": .array([.number(11), .number(12), .number(13), .number(14)]),
                                                   "final_assistant_row_id": .number(14)])

    private func contents(_ display: VoiceTranscriptModel.Display) -> [String] { display.messages.map { $0.content ?? "" } }

    // MARK: Normal mode

    func testNormalTurnDrawsAsTheChatsStreamingTurnAndAsksForItsSavedRows() {
        let model = VoiceTranscriptModel()
        var finished: [String] = []
        model.onTurnFinished = { finished.append($0) }
        model.userSent("what is in my home folder")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("tool.start", .object(["tool_id": .string("t1"), "name": .string("terminal"), "context": .string("ls ~")]))
        model.gatewayEvent("tool.complete", .object(["tool_id": .string("t1"), "name": .string("terminal")]))
        model.gatewayEvent("message.delta", .object(["text": .string("Three ")]))
        model.gatewayEvent("message.delta", .object(["text": .string("folders.")]))
        XCTAssertEqual(model.live?.described, ["tool:t1:terminal:done", "text:Three folders."])
        let shown = model.display(.full)
        XCTAssertEqual(contents(shown), ["what is in my home folder", "Three folders."])
        XCTAssertEqual(shown.liveTools.map(\.id), ["t1"], "the card on the reply row, as the chat's live tools")
        XCTAssertEqual(shown.liveAnchor, shown.messages.last?.messageId)
        XCTAssertNotNil(model.activeRunID)
        XCTAssertNotNil(model.workingSince)
        model.gatewayEvent("message.complete", .object(["status": .string("complete"), "persisted_turn": Self.receipt]))
        XCTAssertEqual(finished, ["voice:1"])
        XCTAssertNil(model.activeRunID, "a finished turn is no longer streaming")
        XCTAssertNil(model.workingSince)
        XCTAssertEqual(model.liveUserMessage?.content, "what is in my home folder", "drawn until the saved rows arrive")
    }

    func testSavedRowsReplaceTheFinishedTurnAsTheChatDrawsThem() {
        let model = VoiceTranscriptModel()
        model.userSent("what is in my home folder")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.delta", .object(["text": .string("Three folders.")]))
        model.gatewayEvent("message.complete", .object(["status": .string("complete"), "persisted_turn": Self.receipt]))
        XCTAssertFalse(model.applySaved(Array(Self.savedTurn.prefix(2)), reachedStart: true, runID: "voice:1"),
                       "rows without the turn's saved reply leave it in place")
        XCTAssertNotNil(model.live)
        XCTAssertTrue(model.applySaved(Self.savedTurn, reachedStart: true, runID: "voice:1"))
        XCTAssertNil(model.live)
        let shown = model.display(.full)
        let projected = HermesTranscriptProjection.project(Self.savedTurn, root: "voice")
        XCTAssertEqual(shown.messages, projected.messages, "the chat's own projection of the saved rows")
        XCTAssertEqual(shown.toolCallGroups, projected.toolCallGroups)
        XCTAssertEqual(shown.toolCallGroups.first?.anchorMessageID, "voice/row-14")
    }

    func testMissingOrIncompleteReceiptKeepsTheTurnAsALocalTurn() {
        for receipt: BotJSON in [.null, .object(["complete": .bool(false), "row_ids": .array([.number(11)])])] {
            let model = VoiceTranscriptModel()
            var finished = false
            model.onTurnFinished = { _ in finished = true }
            model.userSent("Hello")
            model.gatewayEvent("message.delta", .object(["text": .string("Hi")]))
            model.gatewayEvent("message.complete", .object(["text": .string("Hi"), "status": .string("complete"), "persisted_turn": receipt]))
            XCTAssertFalse(finished)
            XCTAssertNil(model.live)
            XCTAssertEqual(contents(model.display(.full)), ["Hello", "Hi"], "the reply is not repeated by the complete's text")
        }
    }

    func testCompleteTextTheDeltasNeverCarriedIsTheReply() {
        let model = VoiceTranscriptModel()
        model.userSent("Hello")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.complete", .object(["status": .string("complete"), "text": .string("One.")]))
        XCTAssertEqual(contents(model.display(.full)), ["Hello", "One."])
    }

    func testReadOfAnOlderRunDoesNotDropTheTurnInFlight() {
        let model = VoiceTranscriptModel()
        model.userSent("first")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.complete", .object(["status": .string("complete"), "text": .string("One.")]))
        model.userSent("second")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.delta", .object(["text": .string("Tw")]))
        XCTAssertTrue(model.applySaved(Self.savedTurn, reachedStart: true, runID: "voice:1"))
        XCTAssertEqual(model.liveUserMessage?.content, "second")
        XCTAssertEqual(model.live?.described, ["text:Tw"])
    }

    func testInterruptedTurnKeepsItsTextAndUserRow() {
        let model = VoiceTranscriptModel()
        model.userSent("tell me a story")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.delta", .object(["text": .string("Once upon")]))
        model.interrupt()
        XCTAssertEqual(model.live?.ending, .interrupted)
        // The server's own `interrupted` complete after our interrupt changes nothing.
        model.gatewayEvent("message.complete", .object(["status": .string("interrupted")]))
        XCTAssertEqual(model.live?.described, ["text:Once upon"])
        let ids = model.display(.full).messages.compactMap(\.messageId)
        // The user's next words: the interrupted turn stays as it was drawn, the new one opens.
        model.userSent("shorter please")
        XCTAssertEqual(model.liveUserMessage?.content, "shorter please")
        XCTAssertEqual(model.messages.map(\.content), ["tell me a story", "Once upon"])
        XCTAssertEqual(Array(model.display(.full).messages.compactMap(\.messageId).prefix(2)), ids, "same rows, same ids")
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
        XCTAssertEqual(model.live?.described, ["text:Resumed"])
        XCTAssertNil(model.liveUserMessage)
    }

    /// The gateway's spinner (`thinking.delta` "(°□°) reflecting...") is status text, not
    /// reasoning (`HermesChatTurnCoordinator.apply` drops it): no Thinking, the line stays whole.
    func testSpinnerFramesBetweenTextDeltasDrawNoThinking() {
        let normal = VoiceTranscriptModel()
        normal.userSent("check the temp folder")
        normal.gatewayEvent("message.start", .null)
        normal.gatewayEvent("message.delta", .object(["text": .string("Okay, I'll check")]))
        normal.gatewayEvent("thinking.delta", .object(["text": .string("(°□°) reflecting...")]))
        normal.gatewayEvent("message.delta", .object(["text": .string(" that now.")]))
        XCTAssertEqual(normal.live?.described, ["text:Okay, I'll check that now."])

        let live = VoiceTranscriptModel()
        live.liveUserSpeech("Check the temp folder", startsSegment: true)
        live.delegationStarted(id: "d1", prompt: "check temp")
        live.delegatedEvent("reasoning.delta", .object(["text": .string("Where is TMPDIR.")]))
        live.delegatedEvent("thinking.delta", .object(["text": .string("(°□°) reflecting...")]))
        live.liveAssistantSpeech("Okay, I'll check")
        live.delegatedEvent("thinking.delta", .object(["text": .string("(¬_¬) brainstorming...")]))
        live.liveAssistantSpeech(" that now.")
        XCTAssertEqual(live.live?.described, ["tool:delegation:d1:Hermes:running", "thinking:Where is TMPDIR.",
                                              "text:Okay, I'll check that now."])
    }

    func testToolErrorFlagFailsTheCard() {
        let model = VoiceTranscriptModel()
        model.userSent("run it")
        model.gatewayEvent("tool.start", .object(["tool_id": .string("t2"), "name": .string("terminal")]))
        model.gatewayEvent("tool.complete", .object(["tool_id": .string("t2"), "name": .string("terminal"), "error": .string("exit 1")]))
        XCTAssertEqual(model.live?.described, ["tool:t2:terminal:failed"])
        XCTAssertEqual(model.display(.full).messages.last?.content, "", "an empty reply row carries the card until text comes")
    }

    // MARK: GPT-Live

    func testLiveExchangeEndsAsALocalTurnDrawnUnchanged() {
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
        XCTAssertEqual(model.live?.described, ["text:Let me check.", "tool:delegation:d1:Hermes:done",
                                               "tool:w1:web_search:done", "text: It's sunny."])
        let before = model.display(.full)
        XCTAssertEqual(contents(before), ["What's the weather", "Let me check.", " It's sunny."])
        model.liveUserSpeech("Thanks", startsSegment: true)
        XCTAssertEqual(model.localTurns.count, 1)
        let after = model.display(.full)
        XCTAssertEqual(Array(after.messages.prefix(3)), before.messages, "the ended exchange keeps its rows and ids")
        XCTAssertEqual(after.toolCallGroups.first?.toolCalls.map(\.id), before.liveTools.map(\.id))
        XCTAssertEqual(after.toolCallGroups.first?.anchorMessageID, before.liveAnchor, "its cards stay on the same row")
        XCTAssertEqual(model.liveUserMessage?.content, "Thanks")
    }

    func testReadReplacesLocalTurns() {
        let model = VoiceTranscriptModel()
        model.liveUserSpeech("Hi", startsSegment: true)
        model.liveAssistantSpeech("Hello.")
        model.finishExchange()
        XCTAssertEqual(model.messages.count, 2)
        model.loadHistory(Self.savedTurn, reachedStart: true)
        XCTAssertTrue(model.localTurns.isEmpty)
        XCTAssertEqual(model.display(.full).messages.compactMap(\.rowID), [11, 14])
    }

    func testThinkingAroundTheVoicesTextKeepsTheLiveOrder() {
        let model = VoiceTranscriptModel()
        model.liveUserSpeech("Check the temp folder", startsSegment: true)
        model.delegationStarted(id: "d1", prompt: "check temp")
        model.delegatedEvent("reasoning.delta", .object(["text": .string("Where is TMPDIR.")]))
        model.liveAssistantSpeech("Okay, checking.")
        model.delegatedEvent("reasoning.delta", .object(["text": .string("List by size.")]))
        model.delegatedEvent("tool.start", .object(["tool_id": .string("r1"), "name": .string("terminal")]))
        model.delegatedEvent("tool.complete", .object(["tool_id": .string("r1"), "name": .string("terminal")]))
        model.delegationFinished(id: "d1")
        model.liveAssistantSpeech(" The oldest one.")
        let live = model.live?.described
        XCTAssertEqual(contents(model.display(.full)), ["Check the temp folder", "Okay, checking.", " The oldest one."])
        model.finishExchange()
        XCTAssertEqual(model.localTurns.last?.described, live, "same parts in the same order")
        XCTAssertEqual(model.display(.full).reasoningGroups.map(\.text), ["Where is TMPDIR.\n\nList by size."])
    }

    // MARK: History, modes

    func testHistoryPagesAsTheChatsDoAboveTheVoiceTurns() {
        let model = VoiceTranscriptModel()
        model.loadHistory(Array(Self.savedTurn[2...]), reachedStart: false)
        XCTAssertTrue(model.hasOlder)
        XCTAssertEqual(model.history.nextOffset, 2)
        XCTAssertTrue(model.prependOlder(Array(Self.savedTurn[..<2])))
        XCTAssertFalse(model.hasOlder, "a short page reached the first row")
        XCTAssertEqual(model.display(.full).messages.compactMap(\.rowID), [11, 14])
        model.userSent("and now")
        XCTAssertEqual(contents(model.display(.full)).last, "and now", "the voice turn is live, below the history")
    }

    func testCurrentShowsTheTurnInFlightOrTheLastTurn() {
        let model = VoiceTranscriptModel()
        model.loadHistory(Self.savedTurn, reachedStart: true)
        model.userSent("second question")
        model.gatewayEvent("message.start", .null)
        model.gatewayEvent("message.delta", .object(["text": .string("Answer.")]))
        var shown = model.display(.current)
        XCTAssertEqual(contents(shown), ["second question", "Answer."])
        XCTAssertEqual(shown.offset, 2, "rows before it keep their render positions")
        model.interrupt()
        model.finishLocally()
        shown = model.display(.current)
        XCTAssertEqual(contents(shown), ["second question", "Answer."])
        XCTAssertEqual(model.display(.full).messages.count, 4)
        model.loadHistory(Self.savedTurn, reachedStart: true)
        shown = model.display(.current)
        XCTAssertEqual(shown.messages.compactMap(\.rowID), [11, 14])
        XCTAssertEqual(shown.toolCallGroups.count, 1)
    }

    func testHiddenCardsDrawNoEmptyRow() {
        let model = VoiceTranscriptModel()
        model.liveUserSpeech("Do it", startsSegment: true)
        model.delegationStarted(id: "d1", prompt: "do it")
        XCTAssertEqual(model.display(.full).messages.count, 2)
        let hidden = model.display(.full, TranscriptSegmentFilter(appends: true, thinkingAndTools: false))
        XCTAssertEqual(contents(hidden), ["Do it"])
        XCTAssertTrue(hidden.liveTools.isEmpty)
    }
}
