import AVFoundation
import XCTest
@testable import HermesMobile

/// GPT-Live (Live mode) rules: recorded server events, append chunking, the delegation turn,
/// the desktop's settle rules on a fake clock, and stop phrases.
@MainActor final class VoiceLiveTests: XCTestCase {
    // Recorded frames, shapes from tools/voice_live.py + the vendor delegation guide.
    static let recorded = [
        #"{"type":"session.started","event_id":"ev_1","session":{"id":"sess_abc"}}"#,
        #"{"type":"session.input_transcript.delta","delta":"What's the ","start_ms":100,"end_ms":600}"#,
        #"{"type":"session.input_transcript.delta","delta":"weather today?","start_ms":600,"end_ms":1200}"#,
        #"{"type":"session.output_transcript.delta","delta":"Let me check.","start_ms":1300,"end_ms":2000}"#,
        #"{"type":"session.delegation.created","delegation":{"id":"del_1","type":"client","target":"hermes"}}"#,
        #"{"type":"error","error":{"code":"context_injection_incomplete","message":"late"}}"#,
        #"{"type":"error","error":{"code":"rate_limited","message":"slow down"}}"#,
        #"{"type":"session.closed","reason":"client_closed","usage":{"seconds":42.5}}"#
    ]

    func testParsesRecordedServerEvents() {
        let parsed = Self.recorded.map(VoiceLive.ServerEvent.parse)
        XCTAssertEqual(parsed[0], .started(sessionID: "sess_abc"))
        XCTAssertEqual(parsed[1], .transcript(.init(speaker: .user, text: "What's the ", startMs: 100, endMs: 600)))
        XCTAssertEqual(parsed[3], .transcript(.init(speaker: .assistant, text: "Let me check.", startMs: 1300, endMs: 2000)))
        XCTAssertEqual(parsed[4], .delegation(id: "del_1"))
        XCTAssertEqual(parsed[5], .error(code: "context_injection_incomplete", message: "late"))
        XCTAssertEqual(parsed[7], .closed(reason: "client_closed", seconds: 42.5))
        XCTAssertNil(VoiceLive.ServerEvent.parse("not json"))
        XCTAssertEqual(VoiceLive.ServerEvent.parse(#"{"type":"session.delegation.created","delegation":{}}"#), .other("session.delegation.created"))
    }

    func testEventsCoreRoutesFramesAndIgnoresInjectionNoise() {
        var sent: [String] = []
        let events = VoiceLiveEvents { sent.append($0); return true }
        var delegated: [(String, [VoiceLive.Fragment])] = []
        var errors: [String] = []
        var closed: [(String, Double?)] = []
        events.onDelegation = { delegated.append(($0, $1)) }
        events.onError = { errors.append($0) }
        events.onClosed = { closed.append(($0, $1)) }
        Self.recorded.forEach(events.handle)
        XCTAssertTrue(events.started)
        XCTAssertEqual(events.sessionID, "sess_abc")
        XCTAssertEqual(delegated.first?.0, "del_1")
        XCTAssertEqual(delegated.first?.1.count, 3)
        XCTAssertEqual(errors, ["slow down"])
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.1, 42.5)
        events.finish("again", nil)
        XCTAssertEqual(closed.count, 1, "closed fires once")
    }

    func testClientEventsHaveUniqueIdsAndShapes() throws {
        var sent: [BotJSON] = []
        let events = VoiceLiveEvents { sent.append(try! JSONDecoder().decode(BotJSON.self, from: Data($0.utf8))); return true }
        events.think("del_1", "  Hermes   is working.  ")
        events.speak("del_1", "Done.")
        events.instruct("Be brief.")
        events.mute(true); events.mute(false)
        XCTAssertTrue(events.requestClose())
        XCTAssertEqual(sent.map { $0["type"].text }, ["session.thinking.append", "session.commentary.append", "session.instructions.append",
                                                      "session.input_audio.mute", "session.input_audio.unmute", "session.close"])
        XCTAssertEqual(sent[0]["content"].text, "Hermes is working.")
        XCTAssertEqual(sent[0]["delegation_id"].text, "del_1")
        XCTAssertEqual(sent[2]["delegation_id"], .null)
        let ids = sent.compactMap { $0["event_id"].text }
        XCTAssertEqual(ids.count, 5)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertNil(sent[5]["event_id"].text)
    }

    func testCommentaryChunksAt1400OnSentenceBoundaries() {
        let sentence = String(repeating: "word ", count: 59) + "end."   // 299 chars
        let text = Array(repeating: sentence, count: 10).joined(separator: "  \n")
        let chunks = VoiceLive.chunkForCommentary(text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1_400 })
        XCTAssertTrue(chunks.allSatisfy { $0.hasSuffix("end.") })
        XCTAssertEqual(chunks.joined(separator: " "), VoiceLive.collapse(text))
        XCTAssertEqual(chunks.count, 3)   // 4 + 4 + 2 sentences
        let long = String(repeating: "x", count: 3_000)
        XCTAssertEqual(VoiceLive.chunkForCommentary("Hi. " + long).map(\.count), [3, 1_400, 1_400, 200])
        XCTAssertEqual(VoiceLive.chunkForCommentary("  short  "), ["short"])
        XCTAssertEqual(VoiceLive.chunkForCommentary("   "), [])
        // Each append the session sends is one chunk.
        var sent: [String] = []
        let events = VoiceLiveEvents { sent.append($0); return true }
        events.speak("d", text)
        XCTAssertEqual(sent.count, 3)
    }

    func testSeedHistoryCaps() {
        let turns = (0..<30).map { (role: $0 % 2 == 0 ? "user" : "assistant", text: "turn \($0) " + String(repeating: "a", count: 2_000)) }
        let history = VoiceLive.history(turns)
        XCTAssertEqual(history.count, 7)   // Newest whole messages within 16,000 UTF-8 bytes.
        XCTAssertEqual(history.compactMap { $0["content"].list?.first?["text"].text }, turns.suffix(7).map(\.text))
        XCTAssertEqual(history.last?["role"].text, "assistant")
        XCTAssertEqual(history.last?["content"].list?.first?["type"].text, "output_text")
    }

    func testSeedHistoryKeepsBriefingWhole() {
        let lastItem = "9. The blue umbrella is in the garage."
        let briefing = String(repeating: "a", count: 3_600 - lastItem.count) + lastItem
        XCTAssertEqual(briefing.count, 3_600)
        let history = VoiceLive.history([(role: "assistant", text: briefing)])
        XCTAssertEqual(history.first?["content"].list?.first?["text"].text, briefing)
    }

    func testSeedHistoryKeepsBriefingAfterRecentVoiceTurns() {
        let briefing = "Briefing " + String(repeating: "b", count: 3_600)
        let turns = [(role: "assistant", text: briefing)] + (0..<4).map {
            (role: $0.isMultiple(of: 2) ? "user" : "assistant", text: String(repeating: "v", count: 2_000))
        }
        XCTAssertEqual(VoiceLive.history(turns).compactMap { $0["content"].list?.first?["text"].text }, turns.map(\.text))
    }

    func testSeedHistoryDropsOldestWholeMessagesWithoutSkippingMiddle() {
        let turns = [(role: "user", text: "old"),
                     (role: "assistant", text: String(repeating: "b", count: 13_000)),
                     (role: "user", text: String(repeating: "c", count: 3_600))]
        let history = VoiceLive.history(turns)
        XCTAssertEqual(history.compactMap { $0["content"].list?.first?["text"].text }, [turns[2].text])
    }

    func testSeedHistoryOversizedNewestKeepsStartAndExplicitMarker() {
        let newest = "START " + String(repeating: "a", count: 20_000) + " END"
        let history = VoiceLive.history([(role: "user", text: "old"), (role: "assistant", text: newest)])
        let text = history.first?["content"].list?.first?["text"].text ?? ""
        let marker = "[rest of this message cut]"
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(text, String(newest.prefix(16_000 - marker.count - 1)) + "\n" + marker)
        XCTAssertEqual(text.count, 16_000)
    }

    func testSeedHistoryRetains24MessageCap() {
        let turns = (0..<30).map { (role: "user", text: "turn \($0)") }
        XCTAssertEqual(VoiceLive.history(turns).compactMap { $0["content"].list?.first?["text"].text }, turns.suffix(24).map(\.text))
    }

    func testLiveSessionRequestScopesResumedProfileAndLeavesNewChatUnscoped() throws {
        let base = URL(string: "https://example.test")!
        let seed = VoiceLive.history([(role: "assistant", text: "briefing")])
        for profile in ["briefing", "briefing & a/b?", nil] {
            let request = try HermesREST.voiceLiveSession(sdp: "v=0\r\n", history: seed, profile: profile).request(base: base)
            let parts = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertEqual(parts?.queryItems?.first?.name, profile == nil ? nil : "profile")
            XCTAssertEqual(parts?.queryItems?.first?.value, profile)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/audio/voice-live/session")
            let body = try JSONDecoder().decode(BotJSON.self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(body["sdp"].text, "v=0\r\n")
            XCTAssertEqual(body["history"], .array(seed))
        }
    }

    func testLiveTransportUsesResumedProfileButNotANewChatProfile() async {
        for key in ["original-key", nil] {
            let backend = FakeVoiceBackend()
            let transport = FakeLiveTransport()
            let conversation = VoiceLiveConversation(backend: backend, makeTransport: { transport },
                                                     resumeSessionKey: key, resumeProfile: "briefing")
            await conversation.start()
            XCTAssertEqual(transport.startedProfile, key == nil ? nil : "briefing")
            await conversation.end()
        }
    }

    func testSeedHistoryPreservesWhitespaceAndBoundsUTF8() {
        let text = " 1. First\n\n2. Second  "
        let history = VoiceLive.history([(role: "assistant", text: text), (role: "user", text: " \n ")])
        XCTAssertEqual(history.first?["content"].list?.first?["text"].text, text)
        let unicode = String(repeating: "☂️", count: 4_000)
        let cut = VoiceLive.history([(role: "assistant", text: unicode)])
        let cutText = cut.first?["content"].list?.first?["text"].text ?? ""
        XCTAssertLessThanOrEqual(cutText.utf8.count, 16_000)
        XCTAssertTrue(cutText.hasSuffix("\n[rest of this message cut]"))
        XCTAssertTrue(unicode.hasPrefix(String(cutText.split(separator: "\n")[0])))
    }

    func testDelegationPromptAndSubmitParams() {
        let context: [VoiceLive.Fragment] = [
            .init(speaker: .user, text: "Hi ", startMs: 0, endMs: 1), .init(speaker: .user, text: "there.", startMs: 1, endMs: 2),
            .init(speaker: .assistant, text: "Hello!", startMs: 2, endMs: 3),
            .init(speaker: .user, text: "Check   the build", startMs: 3, endMs: 4), .init(speaker: .assistant, text: "", startMs: 4, endMs: 5)
        ]
        let (prompt, voiceContext) = VoiceLive.delegationPrompt(context)
        XCTAssertEqual(prompt, "Check the build")
        XCTAssertEqual(voiceContext, "User: Hi there.\nVoice assistant: Hello!\nUser: Check the build")
        let call = VoiceLiveConversation.submitCall(runtime: "rt-1", prompt: prompt, voiceContext: voiceContext)
        XCTAssertEqual(call.method, "prompt.submit")
        // Exactly `{session_id, text, surface: "voice-live", voice_context}`: no `interrupted`, no `queued`.
        XCTAssertEqual(try call.params(), ["session_id": .string("rt-1"), "text": .string(prompt), "surface": .string("voice-live"),
                                           "voice_context": .string(voiceContext)])
        XCTAssertThrowsError(try HermesCall.voiceLivePromptSubmit(sessionID: "rt-1", text: "", voiceContext: "c").params())
        XCTAssertThrowsError(try HermesCall.voiceLivePromptSubmit(sessionID: "rt-1", text: "p",
                                                                  voiceContext: String(repeating: "c", count: 6_001)).params())
        let huge = VoiceLiveConversation.submitCall(runtime: "rt", prompt: "p", voiceContext: String(repeating: "c", count: 9_000))
        XCTAssertEqual(try huge.params()["voice_context"]?.text?.count, 6_000)
        XCTAssertEqual(VoiceLive.delegationPrompt([.init(speaker: .assistant, text: "Only me", startMs: 0, endMs: 1)]).prompt,
                       "Voice assistant: Only me")
    }

    /// Speech sanitization cases for code, markup, links, and spoken text.
    func testSanitizeForSpeechMatchesDesktopSuite() {
        let s = VoiceLive.sanitizeForSpeech
        XCTAssertEqual(s("Here is code:\n```ts\nconst x = 1\n```\nDone."), "Here is code. Done.")
        XCTAssertEqual(s("Use `git status` after the change."), "Use git status after the change.")
        XCTAssertEqual(s("""
            Here is the quick takeaway: the totals remain unchanged.

            | Item | Value | Notes |
            | --- | ---: | --- |
            | Example A | 10 | first row |
            | Example B | 20 | second row |

            Full detail stays visible on screen.
            """), "Here is the quick takeaway: the totals remain unchanged. Item, Value, Notes. Full detail stays visible on screen.")
        let chinese = s("""
            对比如下：

            | 模型 | 价格 |
            | --- | ---: |
            | 甲 | 10 |

            代码：
            ```py
            print(1)
            ```
            详情见 https://example.com/docs
            """)
        XCTAssertTrue(chinese.contains("模型, 价格"), chinese)
        XCTAssertNil(chinese.range(of: "[A-Za-z]", options: .regularExpression), chinese)
        XCTAssertEqual(s("Before the table.\n\n|   |   |\n| --- | --- |\n| a | b |\n\nAfter the table."), "Before the table. After the table.")
        XCTAssertEqual(s("Use the summary first | keep the table on screen when it matters."),
                       "Use the summary first | keep the table on screen when it matters.")
        XCTAssertEqual(s("First sentence.\n\nSecond sentence."), "First sentence. Second sentence.")
        XCTAssertEqual(s("The files are below.\nMEDIA:/Users/ricardo/Documents/inference-server-shopping-list.xlsx\nBye."), "The files are below. Bye.")
        XCTAssertEqual(s("See MEDIA:/tmp/report-2026-q3.xlsx. Then reply."), "See. Then reply.")
        XCTAssertEqual(s("See https://example.com/a-huge-page for details"), "See for details")
        XCTAssertEqual(s("This ~~is~~ old."), "This is old.")
        XCTAssertEqual(s("The file is below: MEDIA:/tmp/x.py"), "The file is below.")
        XCTAssertEqual(s("One line added to the regex list:\n```ts\nconst x = 1\n```\nBye."), "One line added to the regex list. Bye.")
        XCTAssertEqual(s("The regex list:"), "The regex list.")
        XCTAssertEqual(s("**First sentence.**\n\nSecond sentence."), "First sentence. Second sentence.")
        XCTAssertEqual(s("“First sentence.”\n\nSecond sentence."), "“First sentence.” Second sentence.")
        XCTAssertEqual(s("(First sentence.)\n\nSecond sentence."), "(First sentence.) Second sentence.")
        XCTAssertEqual(s("Main takeaway: total is unchanged.\n\nItem | Value\n--- | ---:\nExample A | 10\nExample B | 20\n\nDone."),
                       "Main takeaway: total is unchanged. Item, Value. Done.")
        XCTAssertEqual(s("Before the table.\n\n> | Item | Value |\n> | --- | ---: |\n> | Example A | 10 |\n> | Example B | 20 |\n\nAfter the table."),
                       "Before the table. Item, Value. After the table.")
        XCTAssertEqual(s("Before the table.\n\n>    | Item | Value |\n>    | --- | ---: |\n>    | Example A | 10 |\n\nAfter the table."),
                       "Before the table. Item, Value. After the table.")
        XCTAssertEqual(s("Before the table.\n\n| Item |\n| --- |\n| Example A |\n\nAfter the table."), "Before the table. Item. After the table.")
        XCTAssertEqual(s("> | Item | Value |\n> | --- | ---: |\n> | Example A | 10 |\nOutside | prose"), "Item, Value. Outside | prose")
        XCTAssertTrue(s("Heading | Detail\n--- | --- | ---\nKeep this prose.").contains("Heading | Detail"))
        XCTAssertEqual(s("Before the table.\n\n| Item | Value |\n| --- | ---: |\n| Example A |\n| Example B | 20 | ignored |\n\nAfter the table."),
                       "Before the table. Item, Value. After the table.")
        XCTAssertEqual(s("Before the table.\n\n| Item \\| detail | Value |\n| --- | ---: |\n| Example A | 10 |\n\nAfter the table."),
                       "Before the table. Item detail, Value. After the table.")
        XCTAssertTrue(s("    Item | Value\n    --- | ---\n    Example A | 10").contains("Item | Value"))
    }

    func testStopPhrasesWholeUtteranceOnly() {
        for phrase in ["stop", "Stop!", "hey hermes, stop", "okay never mind", "Goodbye.", "that's all"] {
            XCTAssertTrue(VoiceText.isStopCommand(phrase), phrase)
        }
        for phrase in ["stop the docker container", "how do I stop a process", "hermes", ""] {
            XCTAssertFalse(VoiceText.isStopCommand(phrase), phrase)
        }
    }

    // MARK: Conversation (fake transport, fake clock)

    var clock = Date(timeIntervalSince1970: 1_000)
    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    func makeConversation() async -> (VoiceLiveConversation, FakeVoiceBackend, FakeLiveTransport) {
        let backend = FakeVoiceBackend()
        let transport = FakeLiveTransport()
        let conversation = VoiceLiveConversation(backend: backend, makeTransport: { transport }, now: { [unowned self] in self.clock },
                                                 reconnectDelay: { _ in })
        await conversation.start()
        transport.events.handle(#"{"type":"session.started","session":{"id":"s"}}"#)
        return (conversation, backend, transport)
    }

    func delegate(_ transport: FakeLiveTransport, _ words: String, id: String = "del_1") {
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"\#(words)","start_ms":0,"end_ms":900}"#)
        transport.events.handle(#"{"type":"session.delegation.created","delegation":{"id":"\#(id)"}}"#)
    }

    func testBusyHangUpSendsActualTailBeforeHermesCompletesWithoutInterrupt() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "Do the task.")
        await waitUntil { conversation.turnsSubmitted == 1 }
        backend.emit("message.start")
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Actually use Friday.","start_ms":1000,"end_ms":1500}"#)
        await conversation.end()
        transport.events.finish("client_closed", nil)
        await waitUntil { backend.calls.contains { $0.0 == "session.steer" } }
        let steer = backend.calls.first { $0.0 == "session.steer" }?.1
        XCTAssertEqual(steer?["session_id"], .string("rt-1"))
        XCTAssertEqual(steer?["text"], .string(VoiceLiveConversation.callEndedPrompt + "\n\nUser: Actually use Friday."))
        XCTAssertEqual(transport.mutes.last, true)
        XCTAssertEqual(transport.cuts.last, true)
        XCTAssertFalse(backend.closed)
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.interrupt" || $0.0 == "session.close" })
        backend.emit("message.complete", ["text": .string("Friday noted.")])
        await waitUntil { backend.closed }
        XCTAssertTrue(transport.commentary.isEmpty, "no speech after hang-up")
    }

    func testEmptyNewLiveCallDoesNotOpenReservedChat() async {
        let (conversation, backend, transport) = await makeConversation()
        await conversation.end()
        transport.events.finish("client_closed", nil)
        let key = await conversation.chatForOpening()
        XCTAssertNil(key)
        XCTAssertFalse(backend.calls.contains { $0.0 == "prompt.submit" })
        await conversation.awaitChatWorkSettled()
    }

    func testRejectedFirstFinalNoteDoesNotOpenReservedChat() async {
        let (conversation, backend, transport) = await makeConversation()
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Hello.","start_ms":0,"end_ms":500}"#)
        backend.callHook = { method, _ in
            method == "prompt.submit" ? .object(["status": .string("rejected")]) : nil
        }
        await conversation.end()
        transport.events.finish("client_closed", nil)
        let key = await conversation.chatForOpening()
        XCTAssertNil(key)
        await conversation.awaitChatWorkSettled()
        XCTAssertTrue(backend.closed)
    }

    func testAcceptedDelegationOpensWithoutWaitingForFinalTail() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "Work.")
        await waitUntil { conversation.turnsSubmitted == 1 }
        await conversation.end()
        // The transport has not finished: final admission is still waiting on its close.
        let key = await conversation.chatForOpening()
        XCTAssertEqual(key, "key-1")
        transport.events.finish("client_closed", nil)
        backend.emit("message.start")
        backend.emit("message.complete")
        await conversation.awaitChatWorkSettled()
    }

    func testIdleNoDelegationHangUpCreatesCompactFinalTurnWithHiddenContext() async {
        let (conversation, backend, transport) = await makeConversation()
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Remember Friday.","start_ms":0,"end_ms":500}"#)
        transport.events.handle(#"{"type":"session.output_transcript.delta","delta":"Noted.","start_ms":600,"end_ms":900}"#)
        await conversation.end()
        transport.events.finish("client_closed", nil)
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        let submit = backend.calls.first { $0.0 == "prompt.submit" }?.1
        XCTAssertEqual(submit?["text"], .string(VoiceLiveConversation.callEndedPrompt))
        XCTAssertEqual(submit?["surface"], .string("voice-live"))
        XCTAssertEqual(submit?["voice_context"], .string("User: Remember Friday.\nVoice assistant: Noted."))
        XCTAssertFalse(backend.closed)
        backend.emit("message.start")
        backend.emit("message.complete", ["text": .string("Remembered.")])
        await waitUntil { backend.closed }
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.close" })
    }

    func testRejectedBusySteerFallsBackOnceToQueuedTranscriptText() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "Work.")
        await waitUntil { conversation.turnsSubmitted == 1 }
        backend.emit("message.start")
        backend.steerStatus = "rejected"
        transport.events.handle(#"{"type":"session.output_transcript.delta","delta":"Friday matters.","start_ms":1000,"end_ms":1500}"#)
        await conversation.end()
        await conversation.end()
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 2 }
        let final = backend.calls.last { $0.0 == "prompt.submit" }!.1
        XCTAssertEqual(final["queued"], .bool(true))
        XCTAssertEqual(final["text"], .string(VoiceLiveConversation.callEndedPrompt + "\n\nVoice assistant: Friday matters."))
        XCTAssertNil(final["voice_context"])
        XCTAssertEqual(backend.calls.filter { $0.0 == "session.steer" }.count, 1)
        backend.emit("message.complete")
        XCTAssertFalse(backend.closed, "the queued final turn still owes a start")
        backend.emit("message.start")
        backend.emit("message.complete")
        await waitUntil { backend.closed }
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.interrupt" || $0.0 == "session.close" })
    }

    func testEmptyTailDoesNothingAndClosesLocally() async {
        let (conversation, backend, _) = await makeConversation()
        XCTAssertEqual(backend.calls.map(\.0), ["session.create"])
        await conversation.end()
        await conversation.end()
        await waitUntil { backend.closed }
        XCTAssertEqual(backend.calls.map(\.0), ["session.create"])
    }

    func testAcceptedBusySteerIsNeverResentAndLateVoiceCannotRestoreAudio() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "Work.")
        await waitUntil { conversation.turnsSubmitted == 1 }
        backend.emit("message.start")
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Correction.","start_ms":1000,"end_ms":1500}"#)
        await conversation.end()
        await waitUntil { backend.calls.contains { $0.0 == "session.steer" } }
        await conversation.end()
        transport.onSpeakingChange?(false)
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"late","start_ms":2000,"end_ms":2500}"#)
        backend.emit("message.delta", ["text": .string("A late sentence. ")])
        conversation.tick()
        XCTAssertEqual(transport.cuts, [true])
        XCTAssertTrue(transport.commentary.isEmpty)
        XCTAssertEqual(backend.calls.filter { $0.0 == "session.steer" }.count, 1)
        XCTAssertEqual(backend.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        XCTAssertFalse(backend.closed)
        backend.emit("message.complete")
        await waitUntil { backend.closed }
    }

    func testEndWaitsForPendingAcceptanceAndKeepsOnlyTheReceivedTail() async {
        let (conversation, backend, transport) = await makeConversation()
        var admission: CheckedContinuation<BotJSON, Never>?
        backend.callHook = { method, _ in
            if method == "prompt.submit", admission == nil {
                return await withCheckedContinuation { admission = $0 }
            }
            return nil
        }
        delegate(transport, "Already sent.")
        await waitUntil { admission != nil }
        backend.emit("message.start")
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Tail correction.","start_ms":1000,"end_ms":1500}"#)
        await conversation.end()
        XCTAssertEqual(transport.mutes.last, true)
        XCTAssertEqual(transport.cuts.last, true)
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.steer" })
        admission?.resume(returning: .object(["status": .string("streaming")]))
        await waitUntil { backend.calls.contains { $0.0 == "session.steer" } }
        XCTAssertEqual(backend.calls.last { $0.0 == "session.steer" }?.1["text"],
                       .string(VoiceLiveConversation.callEndedPrompt + "\n\nUser: Tail correction."))
        backend.emit("message.complete")
        await waitUntil { backend.closed }
    }

    func testEndAfterRejectedInFlightAdmissionKeepsAllWordsWithoutLateSpeech() async {
        let (conversation, backend, transport) = await makeConversation()
        var admission: CheckedContinuation<BotJSON, Never>?
        var submissions = 0
        backend.callHook = { method, _ in
            guard method == "prompt.submit" else { return nil }
            submissions += 1
            if submissions == 1 { return await withCheckedContinuation { admission = $0 } }
            return nil
        }
        delegate(transport, "Rejected request.")
        await waitUntil { admission != nil }
        transport.events.handle(#"{"type":"session.output_transcript.delta","delta":"Received tail.","start_ms":1000,"end_ms":1500}"#)
        await conversation.end()
        admission?.resume(returning: .object(["status": .string("rejected")]))
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 2 }
        XCTAssertEqual(backend.calls.last { $0.0 == "prompt.submit" }?.1["voice_context"],
                       .string("User: Rejected request.\nVoice assistant: Received tail."))
        XCTAssertTrue(transport.commentary.isEmpty)
        backend.emit("message.start")
        backend.emit("message.complete")
        await waitUntil { backend.closed }
    }

    func testGracefulCloseRetainsReceivedFragmentsAndIgnoresMinutesPreference() async {
        let (conversation, backend, transport) = await makeConversation()
        let defaults = UserDefaults(suiteName: "Issue37EndTail")!
        defaults.set("1", forKey: VoiceLive.ContextMode.defaultsKey)
        transport.events.defaults = defaults
        defer { defaults.removePersistentDomain(forName: "Issue37EndTail") }
        transport.finishOnClose = false
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Old but unsent.","start_ms":0,"end_ms":500}"#)
        await conversation.end()
        transport.events.handle(#"{"type":"session.output_transcript.delta","delta":"Graceful tail.","start_ms":120000,"end_ms":120500}"#)
        transport.events.finish("client_closed", nil)
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        XCTAssertEqual(backend.calls.last?.1["voice_context"], .string("User: Old but unsent.\nVoice assistant: Graceful tail."))
        backend.emit("message.start")
        backend.emit("message.complete")
        await waitUntil { backend.closed }
    }

    func testVendorLossRetainsTailAndRepeatedCloseDoesNotDuplicateDelivery() async {
        let (conversation, backend, transport) = await makeConversation()
        transport.events.handle(#"{"type":"session.output_transcript.delta","delta":"Assistant-only tail.","start_ms":0,"end_ms":500}"#)
        transport.events.finish("connection_lost", nil)
        await conversation.end()
        transport.events.finish("connection_lost", nil)
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        XCTAssertEqual(backend.calls.last?.1["voice_context"], .string("Voice assistant: Assistant-only tail."))
        XCTAssertEqual(backend.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        backend.emit("message.start")
        backend.emit("message.complete")
        await waitUntil { backend.closed }
    }

    func testAcceptedRequestWithNoTailWaitsForItsWorkWithoutSendingAnything() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "Work.")
        await waitUntil { conversation.turnsSubmitted == 1 }
        backend.emit("message.start")
        await conversation.end()
        XCTAssertFalse(backend.closed)
        backend.emit("message.complete")
        await waitUntil { backend.closed }
        XCTAssertEqual(backend.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.steer" || $0.0 == "session.close" })
    }

    func testResumedFinalTailUsesTheOriginalRuntimeAndProfile() async {
        let backend = FakeVoiceBackend()
        let transport = FakeLiveTransport()
        let conversation = VoiceLiveConversation(backend: backend, makeTransport: { transport },
                                                 resumeSessionKey: "original-key", resumeProfile: "original-profile")
        await conversation.start()
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Resumed tail.","start_ms":0,"end_ms":500}"#)
        await conversation.end()
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        XCTAssertEqual(backend.calls.first?.1["session_id"], .string("original-key"))
        XCTAssertEqual(backend.calls.first?.1["profile"], .string("original-profile"))
        XCTAssertEqual(backend.calls.last?.1["session_id"], .string("rt-resumed"))
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.create" })
        for type in ["message.start", "message.complete"] {
            backend.onEvent?(.object(["type": .string(type), "session_id": .string("rt-resumed"), "payload": .object([:])]))
        }
        await waitUntil { backend.closed }
    }

    func testFinalHiddenContextUsesExistingNewestWholeTurnCap() async {
        let (conversation, backend, transport) = await makeConversation()
        for index in 0..<12 {
            let type = index.isMultiple(of: 2) ? "input" : "output"
            let text = "turn\(index) " + String(repeating: "word ", count: 150)
            transport.events.handle(#"{"type":"session.\#(type)_transcript.delta","delta":"\#(text)","start_ms":\#(index * 1000),"end_ms":\#(index * 1000 + 500)}"#)
        }
        let expected = VoiceLive.delegationContext(transport.events.contextWindow(.sinceLastRequest)).context
        await conversation.end()
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        let actual = backend.calls.last?.1["voice_context"]?.text ?? ""
        XCTAssertEqual(actual, expected)
        XCTAssertLessThanOrEqual(actual.count, 6000)
        XCTAssertTrue(actual.hasPrefix(VoiceLive.contextCutMarker))
        XCTAssertTrue(actual.contains("Voice assistant: turn11"))
        backend.emit("message.start")
        backend.emit("message.complete")
        await waitUntil { backend.closed }
    }

    func testOnlyAcceptedBackendAdmissionConsumesTheTranscriptBoundary() async {
        for status in ["streaming", "queued", "redirected", "steered"] {
            let (conversation, backend, transport) = await makeConversation()
            backend.submitStatus = status
            delegate(transport, "Remember Friday.")
            await waitUntil { conversation.turnsSubmitted == 1 }
            XCTAssertEqual(transport.events.cutPoint, transport.events.receivedFragments, status)
            await conversation.end()
        }
        for rejected in [false, true] {
            let (conversation, backend, transport) = await makeConversation()
            backend.failSubmit = rejected
            backend.submitStatus = "rejected"
            delegate(transport, "Keep this correction.")
            await waitUntil { transport.commentary.contains(VoiceLiveConversation.submitFailedLine) }
            XCTAssertEqual(transport.events.cutPoint, 0)
            XCTAssertEqual(conversation.turnsSubmitted, 0)
            await conversation.end()
        }
    }

    func testDelegationBecomesVoiceLiveTurnAndStreamsSentences() async {
        let (conversation, backend, transport) = await makeConversation()
        XCTAssertEqual(conversation.phase, .listening)
        delegate(transport, "What is two plus two?")
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        XCTAssertEqual(backend.calls.map(\.0), ["session.create", "prompt.submit"])
        let submit = backend.calls[1].1
        XCTAssertEqual(submit["text"], .string("What is two plus two?"))
        XCTAssertEqual(submit["surface"], .string("voice-live"))
        XCTAssertEqual(submit["voice_context"], .string("User: What is two plus two?"))
        XCTAssertEqual(conversation.sessionKey, "key-1")
        XCTAssertEqual(conversation.phase, .working(nil))
        backend.emit("message.start")
        backend.emit("tool.start", ["name": .string("terminal")])
        XCTAssertEqual(transport.sent(type: "session.thinking.append").count, 0,
                       "a step alone is not sent: GPT-Live answers every append aloud (#115)")
        backend.emit("message.delta", ["text": .string("It is **four**. Two plus")])
        XCTAssertEqual(transport.commentary, ["It is four."])
        backend.emit("message.delta", ["text": .string(" two is four. And")])
        XCTAssertEqual(transport.commentary, ["It is four.", "Two plus two is four."])
        backend.emit("message.complete", ["text": .string("It is **four**. Two plus two is four. And done")])
        XCTAssertEqual(transport.commentary, ["It is four.", "Two plus two is four.", "And done"])
        XCTAssertNil(conversation.activeDelegation)
        XCTAssertEqual(conversation.phase, .listening)
        XCTAssertTrue(transport.sent(type: "session.commentary.append").allSatisfy { $0["delegation_id"].text == "del_1" })
    }

    func testReplyAfterToolStreamsCleanChunksWhenCompleteTextIsTrimmed() async {
        let (conversation, backend, transport) = await makeConversation()
        defer { withExtendedLifetime(conversation) {} }
        delegate(transport, "Print the date")
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.emit("message.start")
        backend.emit("tool.start", ["name": .string("terminal")])
        backend.emit("tool.complete")
        backend.emit("message.delta", ["text": .string("\n\nI ran it on the Mac. It says")])
        backend.emit("message.delta", ["text": .string(" Wednesday.")])
        backend.emit("message.complete", ["text": .string("I ran it on the Mac. It says Wednesday.")])
        XCTAssertEqual(transport.commentary, ["I ran it on the Mac.", "It says Wednesday."],
                       "\(transport.frames.map { "\($0["type"].text ?? "-"):\($0["content"].text ?? "")" }) calls \(backend.calls.map(\.0))")
    }

    /// Ids the voice screen draws (rows, then every card), repeated.
    private func duplicateIDs(_ model: VoiceTranscriptModel) -> [String] {
        let shown = model.display(.full)
        let identities = shown.messages.compactMap(\.messageId)
            + (shown.toolCallGroups.flatMap(\.toolCalls) + shown.liveTools).map(\.id)
        return Dictionary(grouping: identities, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    }

    private func delegationTurns(_ model: VoiceTranscriptModel, _ id: String) -> Int {
        let turns = model.localTurns + (model.live.map { [$0] } ?? [])
        return turns.filter { $0.described.contains { $0.hasPrefix("tool:delegation:\(id):") } }.count
    }

    /// 10-01 22:46 crash: the user spoke again while a delegation ran (the user's words open the next
    /// exchange), then Hermes's reply finished the delegation. The finish landed in the NEW
    /// exchange as a second card with the same id: `run:tool:delegation:<id>` [group, group]
    /// and its member [member, member], which the snapshot apply raises on.
    func testReplyAfterTheUserSpokeAgainFinishesTheDelegationInItsOwnExchange() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "How are the running chats", id: "del_A")
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.emit("message.start")
        advance(3)
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Also","start_ms":5000,"end_ms":5400}"#)
        backend.emit("message.complete", ["text": .string("Two chats are running.")])
        XCTAssertEqual(transport.commentary, ["Two chats are running."])
        XCTAssertNil(conversation.activeDelegation)
        let model = conversation.transcript
        XCTAssertEqual(delegationTurns(model, "del_A"), 1, "the delegation's card lives in one exchange")
        XCTAssertEqual(duplicateIDs(model), [])
        model.finishExchange()
        XCTAssertEqual(delegationTurns(model, "del_A"), 1)
        XCTAssertEqual(duplicateIDs(model), [])
    }

    /// The 22:40:59 → 22:41:35 sequence: a new request while the previous one still ran. The
    /// previous delegation is finished in the exchange that holds it, never copied into the new one.
    func testNewRequestWhileTheLastRunsFinishesTheLastInItsOwnExchange() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "Talk to me about the progress", id: "del_A")
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 1 }
        backend.emit("message.start")
        advance(3)
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Is CI green","start_ms":5000,"end_ms":5600}"#)
        transport.events.handle(#"{"type":"session.delegation.created","delegation":{"id":"del_B"}}"#)
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 2 }
        let model = conversation.transcript
        XCTAssertEqual(delegationTurns(model, "del_A"), 1)
        XCTAssertEqual(delegationTurns(model, "del_B"), 1)
        XCTAssertEqual(duplicateIDs(model), [])
        model.finishExchange()
        XCTAssertEqual(delegationTurns(model, "del_A"), 1)
        XCTAssertEqual(duplicateIDs(model), [])
    }

    func testDelegatedThinkingIsDrawnAndSettlesToOneRowPerStep() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "Check the running chats", id: "del_T")
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.emit("message.start")
        backend.emit("reasoning.delta", ["text": .string("Listing the chats ")])
        backend.emit("thinking.delta", ["text": .string("(°□°) reflecting...")])
        backend.emit("reasoning.delta", ["text": .string("first.")])
        backend.emit("tool.start", ["tool_id": .string("t1"), "name": .string("terminal")])
        backend.emit("tool.complete", ["tool_id": .string("t1"), "name": .string("terminal")])
        backend.emit("reasoning.delta", ["text": .string("Two are running.")])
        let model = conversation.transcript
        let live = model.live?.described ?? []
        XCTAssertEqual(live.filter { $0.hasPrefix("thinking:") }, ["thinking:Listing the chats first.", "thinking:Two are running."],
                       "live Thinking, one part per Hermes step")
        advance(3)
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Thanks","start_ms":5000,"end_ms":5400}"#)
        backend.emit("message.complete", ["text": .string("Two chats are running.")])
        XCTAssertEqual(duplicateIDs(model), [])
        XCTAssertEqual(delegationTurns(model, "del_T"), 1)
        let settled = model.localTurns.last { $0.described.contains("tool:delegation:del_T:Hermes:done") }
        XCTAssertEqual(settled?.described.filter { $0.hasPrefix("thinking:") }, live.filter { $0.hasPrefix("thinking:") },
                       "the ended exchange keeps its Thinking as it was drawn")
        model.finishExchange()
        XCTAssertEqual(duplicateIDs(model), [])
    }

    func testInterruptedTurnsCompleteDoesNotSettleTheNewerDelegationAndItsReplyIsSpoken() async {
        let (conversation, backend, transport) = await makeConversation()
        defer { withExtendedLifetime(conversation) {} }
        delegate(transport, "Check CI", id: "del_A")
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 1 }
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("Looking at the runs now. The second")])
        XCTAssertEqual(transport.commentary, ["Looking at the runs now."])
        delegate(transport, "Is CI green", id: "del_B")
        await waitUntil { conversation.holdingFollowUp }
        XCTAssertEqual(backend.calls.map(\.0), ["session.create", "prompt.submit", "session.interrupt"],
                       "B's words wait for A's turn to end (#69)")
        backend.emit("message.delta", ["text": .string(" one failed. Retrying it.")])
        backend.emit("message.complete", ["status": .string("interrupted"), "text": .string("Looking at the runs now. The second one")])
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 2 }
        XCTAssertEqual(backend.calls.map(\.0), ["session.create", "prompt.submit", "session.interrupt", "prompt.submit"])
        conversation.tick()
        advance(120); conversation.tick()
        XCTAssertEqual(conversation.activeDelegation, "del_B", "A's interrupted complete must not settle B, even if B starts late")
        XCTAssertEqual(conversation.phase, .working(nil))
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("CI is green. All")])
        backend.emit("message.delta", ["text": .string(" four jobs passed.")])
        backend.emit("message.complete", ["status": .string("complete"), "text": .string("CI is green. All four jobs passed.")])
        XCTAssertEqual(transport.commentary, ["Looking at the runs now.", "CI is green.", "All four jobs passed."],
                       "B's reply goes to GPT-Live; A's text after B was asked never does")
        XCTAssertTrue(transport.sent(type: "session.commentary.append").dropFirst().allSatisfy { $0["delegation_id"].text == "del_B" })
        XCTAssertFalse(transport.sent(type: "session.thinking.append").contains { $0["content"].text == VoiceLiveConversation.noSpokenResultLine })
        XCTAssertNil(conversation.activeDelegation)
        XCTAssertEqual(conversation.phase, .listening)
        XCTAssertEqual(duplicateIDs(conversation.transcript), [])
    }

    /// B asked before A's `message.start` arrived (the app saw no running turn, so no interrupt;
    /// the gateway queues B behind A): A's start is not B's, B's turn is the next one.
    func testDelegationSubmittedBeforeTheEarlierTurnStartedWaitsForItsOwnTurn() async {
        let (conversation, backend, transport) = await makeConversation()
        defer { withExtendedLifetime(conversation) {} }
        delegate(transport, "Check CI", id: "del_A")
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 1 }
        backend.submitStatus = "queued"
        delegate(transport, "Is CI green", id: "del_B")
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 2 }
        XCTAssertEqual(conversation.interruptsSent, 0)
        backend.emit("message.start")
        backend.emit("tool.start", ["tool_id": .string("t1"), "name": .string("terminal")])
        backend.emit("message.delta", ["text": .string("The first answer. More")])
        backend.emit("message.complete", ["status": .string("interrupted"), "text": .string("The first answer.")])
        XCTAssertEqual(conversation.activeDelegation, "del_B")
        XCTAssertTrue(transport.commentary.isEmpty, "A's turn is not B's: nothing of it is spoken")
        XCTAssertTrue(transport.sent(type: "session.thinking.append").isEmpty, "A's tool is not reported as B's progress")
        backend.emit("message.start")
        backend.emit("message.complete", ["status": .string("complete"), "text": .string("Yes, CI is green.")])
        XCTAssertEqual(transport.commentary, ["Yes, CI is green."])
        XCTAssertNil(conversation.activeDelegation)
    }

    /// The gateway folded B's words into the running turn (`prompt.submit` → "redirected"): that
    /// turn's frames now answer B.
    func testRedirectedSubmitMakesTheRunningTurnTheDelegations() async {
        let (conversation, backend, transport) = await makeConversation()
        defer { withExtendedLifetime(conversation) {} }
        delegate(transport, "Check CI", id: "del_A")
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 1 }
        backend.submitStatus = "redirected"
        delegate(transport, "Only the main branch", id: "del_B")
        await waitUntil { conversation.turnsSubmitted == 2 }
        backend.emit("message.start")
        backend.emit("message.complete", ["status": .string("complete"), "text": .string("Main is green.")])
        XCTAssertEqual(transport.commentary, ["Main is green."])
        XCTAssertNil(conversation.activeDelegation)
    }

    func testUnseenTurnNeverSettlesFromElapsedTime() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "Do the thing")
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        advance(120); conversation.tick()
        XCTAssertNotNil(conversation.activeDelegation, "elapsed time cannot prove that our turn completed")
        XCTAssertTrue(transport.sent(type: "session.thinking.append").isEmpty)
        backend.emit("message.start")
        backend.emit("message.complete")
        XCTAssertNil(conversation.activeDelegation)
        XCTAssertEqual(transport.sent(type: "session.thinking.append").last?["content"].text, VoiceLiveConversation.noSpokenResultLine)
    }

    func testObservedToolOnlyTurnSettlesAtCompleteWithoutGrace() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "Clean up")
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.emit("message.start")
        advance(1)
        backend.emit("message.complete")
        XCTAssertNil(conversation.activeDelegation)
        XCTAssertEqual(transport.sent(type: "session.thinking.append").last?["content"].text, VoiceLiveConversation.noSpokenResultLine)
    }

    func testBusyDelegationInterruptsFirstAndSubmitFailureIsSpoken() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "First")
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 1 }
        backend.emit("message.start")
        delegate(transport, "Second instead", id: "del_2")
        await waitUntil { conversation.holdingFollowUp }
        backend.emit("message.complete", ["status": .string("interrupted")])
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 2 }
        XCTAssertEqual(backend.calls.map(\.0), ["session.create", "prompt.submit", "session.interrupt", "prompt.submit"])
        XCTAssertEqual(conversation.interruptsSent, 1)
        backend.failSubmit = true
        backend.emit("message.start")
        backend.emit("message.complete")
        delegate(transport, "Third", id: "del_3")
        await waitUntil { transport.commentary.contains(VoiceLiveConversation.submitFailedLine) }
        XCTAssertEqual(transport.sent(type: "session.commentary.append").last?["delegation_id"].text, "del_3")
        XCTAssertNil(conversation.activeDelegation)
    }

    func testSpokenStopEndsAfterUtteranceSettlesAndDelegatedStopNeverSubmits() async {
        let (conversation, backend, transport) = await makeConversation()
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Stop the","start_ms":0,"end_ms":1}"#)
        advance(1); conversation.tick()
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":" container","start_ms":1,"end_ms":2}"#)
        advance(1.6); conversation.tick()
        XCTAssertFalse(conversation.isEnded, "\"stop the container\" is a request")
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Okay, stop.","start_ms":3,"end_ms":4}"#)
        advance(1.0); conversation.tick()
        XCTAssertFalse(conversation.isEnded)
        advance(0.6); conversation.tick()
        await waitUntil { conversation.isEnded }
        XCTAssertTrue(transport.closeCalls >= 1)
        XCTAssertTrue(backend.calls.filter { $0.0 == "prompt.submit" }.allSatisfy { $0.1["text"] == .string(VoiceLiveConversation.callEndedPrompt) },
                      "stop is never a delegation task; only the final received context may submit")

        let (c2, b2, t2) = await makeConversation()
        delegate(t2, "goodbye")
        await waitUntil { c2.isEnded }
        await waitUntil { b2.calls.contains { $0.0 == "prompt.submit" } }
        XCTAssertEqual(b2.calls.last?.1["text"], .string(VoiceLiveConversation.callEndedPrompt))
        XCTAssertEqual(b2.calls.last?.1["voice_context"], .string("User: goodbye"))
        XCTAssertEqual(t2.events.cutPoint, t2.events.receivedFragments)
    }

    func testApprovalByVoiceOnceOnly() async {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "Delete the temp files")
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.onEvent?(.object(["jsonrpc": .string("2.0"), "id": .string("srv-1"), "method": .string("approval"), "params": .object([
            "session_id": .string("rt-1"), "request_id": .string("req-1"), "command": .string("rm -rf /tmp/x"),
            "choices": .array([.string("once"), .string("session"), .string("always"), .string("deny")])])]))
        XCTAssertNotNil(conversation.pendingApproval)
        XCTAssertTrue(transport.commentary.last?.contains("approve or deny") == true)
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"approve","start_ms":3,"end_ms":4}"#)
        advance(2); conversation.tick()
        await waitUntil { backend.calls.contains { $0.0 == "approval.respond" } }
        let respond = backend.calls.first { $0.0 == "approval.respond" }!.1
        XCTAssertEqual(respond["choice"], .string("once"))
        XCTAssertNil(conversation.pendingApproval)
    }

    func testSudoNeedsTheApp() async {
        let (conversation, backend, transport) = await makeConversation()
        var needs: [String] = []
        conversation.onNeedsApp = { needs.append($0) }
        delegate(transport, "Install it")
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.onEvent?(.object(["jsonrpc": .string("2.0"), "id": .string("srv-3"), "method": .string("sudo"), "params": .object([
            "session_id": .string("rt-1")])]))
        XCTAssertEqual(needs.count, 1)
        XCTAssertFalse(backend.calls.contains { $0.0 == "approval.respond" })
    }

    func testMuteCloseAndEndedReason() async {
        let (conversation, _, transport) = await makeConversation()
        conversation.toggleMute()
        XCTAssertTrue(conversation.muted)
        XCTAssertEqual(transport.mutes, [true])
        transport.events.handle(#"{"type":"session.closed","reason":"idle_timeout","usage":{"seconds":61.2}}"#)
        XCTAssertEqual(conversation.phase, .ended("idle_timeout (61s)"))
        XCTAssertEqual(conversation.usageSeconds, 61.2)
    }

    func testStatusDecode() {
        let ok = VoiceLive.Status(.object(["ok": .bool(true), "mode": .string("gpt-live"), "available": .bool(true),
                                           "model": .string("gpt-live-1"), "voice": .string("marin")]))
        XCTAssertEqual(ok?.available, true)
        XCTAssertNil(ok?.unavailableReason)
        let off = VoiceLive.Status(.object(["ok": .bool(true), "available": .bool(false), "reason": .string("No OpenAI key")]))
        XCTAssertEqual(off?.mode, "chained")
        XCTAssertEqual(off?.unavailableReason, "No OpenAI key")
        XCTAssertNil(VoiceLive.Status(.object(["ok": .bool(false)])))
    }

    /// WebRTC re-applies its own configuration when the audio unit starts; that configuration must
    /// carry the call options, or `.playAndRecord` falls back to the earpiece.
    func testGPTLiveAudioConfigurationWebRTCAppliesRoutesLikeACall() {
        VoiceLiveSession.configureAudioSession()
        let applied = VoiceLiveSession.webRTCAudio
        XCTAssertEqual(applied.category, AVAudioSession.Category.playAndRecord.rawValue)
        XCTAssertEqual(applied.mode, AVAudioSession.Mode.voiceChat.rawValue)
        XCTAssertTrue(applied.options.contains(.defaultToSpeaker), "speaker, not the earpiece, when nothing is connected")
        XCTAssertTrue(applied.options.contains(.allowBluetoothHFP), "AirPods / car Bluetooth when connected")
        XCTAssertFalse(applied.options.contains(.mixWithOthers))
    }

    /// Normal and GPT-Live use the one call configuration, so both route the same way.
    func testBothVoiceModesShareTheCallAudioConfiguration() {
        XCTAssertEqual(VoiceCallAudio.category, .playAndRecord)
        XCTAssertEqual(VoiceCallAudio.mode, .voiceChat)
        XCTAssertEqual(VoiceCallAudio.options, [.defaultToSpeaker, .allowBluetoothHFP])
        VoiceLiveSession.configureAudioSession()
        XCTAssertEqual(VoiceLiveSession.webRTCAudio.options, VoiceCallAudio.options)
    }

    /// Every route change during a live call becomes `voice-route` with the reason code and the
    /// new output port type (numbers and codes only), and stops once the call is torn down.

    final class ScriptedHermes {
        enum Step { case idle, model, tool }
        var step = Step.idle
        var stopPending = false
        /// Gateway order of what the app sent and what Hermes emitted.
        var log: [String] = []
    }

    private func script(_ backend: FakeVoiceBackend) -> ScriptedHermes {
        let hermes = ScriptedHermes()
        backend.callHook = { method, params in
            hermes.log.append(method)
            switch method {
            case "session.interrupt":
                hermes.stopPending = true
                return .object(["ok": .bool(true)])
            case "prompt.submit":
                hermes.log[hermes.log.count - 1] = "prompt.submit:" + (params["text"]?.text ?? "")
                switch hermes.step {
                case .idle: return .object(["status": .string("streaming")])
                case .tool: return .object(["status": .string("steered")])
                case .model: return .object(["status": .string(hermes.stopPending ? "queued" : "redirected")])
                }
            default: return nil
            }
        }
        return hermes
    }

    private func emit(_ backend: FakeVoiceBackend, _ hermes: ScriptedHermes, _ type: String, _ payload: [String: BotJSON] = [:]) {
        switch type {
        case "message.start": hermes.step = .model
        case "tool.start": hermes.step = .tool
        case "tool.complete": hermes.step = .model
        case "message.complete": hermes.step = .idle; hermes.stopPending = false
        default: break
        }
        hermes.log.append(type)
        backend.emit(type, payload)
    }

    private func submits(_ hermes: ScriptedHermes) -> [String] { hermes.log.filter { $0.hasPrefix("prompt.submit:") } }

    /// Settles until the app either holds the follow-up or has sent it (main sends it at once).
    private func settleFollowUp(_ conversation: VoiceLiveConversation, _ hermes: ScriptedHermes, submits count: Int) async {
        await waitUntil { conversation.holdingFollowUp || self.submits(hermes).count >= count }
    }

    func testFollowUpDuringAToolCallIsSubmittedFreshAfterTheStoppedTurnCompletes() async {
        let (conversation, backend, transport) = await makeConversation()
        defer { withExtendedLifetime(conversation) {} }
        let hermes = script(backend)
        delegate(transport, "Look at the Brain Fart project", id: "del_A")
        await waitUntil { self.submits(hermes).count == 1 }
        emit(backend, hermes, "message.start")
        emit(backend, hermes, "tool.start", ["tool_id": .string("t1"), "name": .string("terminal")])
        delegate(transport, "No, I said the other project", id: "del_B")
        await waitUntil { hermes.log.contains("session.interrupt") }
        await settleFollowUp(conversation, hermes, submits: 2)
        XCTAssertEqual(submits(hermes).count, 1, "no prompt.submit before the stopped turn's message.complete")
        emit(backend, hermes, "tool.complete", ["tool_id": .string("t1")])
        emit(backend, hermes, "message.complete", ["status": .string("interrupted")])
        await waitUntil { self.submits(hermes).count == 2 }
        XCTAssertEqual(Array(hermes.log.drop { $0 != "session.interrupt" }),
                       ["session.interrupt", "tool.complete", "message.complete",
                        "prompt.submit:No, I said the other project"],
                       "exactly one fresh prompt.submit, after message.complete")
        // The fresh turn answers the new words.
        emit(backend, hermes, "message.start")
        emit(backend, hermes, "message.complete", ["status": .string("complete"), "text": .string("The other project has two open bugs.")])
        XCTAssertEqual(transport.commentary, ["The other project has two open bugs."])
        XCTAssertTrue(transport.sent(type: "session.commentary.append").allSatisfy { $0["delegation_id"].text == "del_B" })
        XCTAssertFalse(transport.sent(type: "session.thinking.append").contains { $0["content"].text == VoiceLiveConversation.noSpokenResultLine })
        XCTAssertNil(conversation.activeDelegation)
        XCTAssertEqual(submits(hermes).count, 2)
    }

    /// (b) Words during a model call (no tool running).
    func testFollowUpDuringAModelCallIsSubmittedFreshAfterTheStoppedTurnCompletes() async {
        let (conversation, backend, transport) = await makeConversation()
        defer { withExtendedLifetime(conversation) {} }
        let hermes = script(backend)
        delegate(transport, "Summarise the logs", id: "del_A")
        await waitUntil { self.submits(hermes).count == 1 }
        emit(backend, hermes, "message.start")
        emit(backend, hermes, "message.delta", ["text": .string("The logs show")])
        delegate(transport, "Only today's", id: "del_B")
        await waitUntil { hermes.log.contains("session.interrupt") }
        await settleFollowUp(conversation, hermes, submits: 2)
        XCTAssertEqual(submits(hermes).count, 1, "no prompt.submit before the stopped turn's message.complete")
        emit(backend, hermes, "message.complete", ["status": .string("interrupted"), "text": .string("The logs show")])
        await waitUntil { self.submits(hermes).count == 2 }
        XCTAssertEqual(Array(hermes.log.drop { $0 != "session.interrupt" }),
                       ["session.interrupt", "message.complete", "prompt.submit:Only today's"])
        emit(backend, hermes, "message.start")
        emit(backend, hermes, "message.complete", ["status": .string("complete"), "text": .string("Today had one error.")])
        XCTAssertEqual(transport.commentary, ["Today had one error."], "A's interrupted text is never spoken; B's answer is")
        XCTAssertNil(conversation.activeDelegation)
        XCTAssertEqual(submits(hermes).count, 2)
    }

    /// (c) Two quick follow-ups during the hold: joined into the one fresh submit, none dropped.
    func testTwoFollowUpsDuringTheHoldJoinOneFreshSubmit() async {
        let (conversation, backend, transport) = await makeConversation()
        defer { withExtendedLifetime(conversation) {} }
        let hermes = script(backend)
        delegate(transport, "Deploy the site", id: "del_A")
        await waitUntil { self.submits(hermes).count == 1 }
        emit(backend, hermes, "message.start")
        emit(backend, hermes, "tool.start", ["tool_id": .string("t1"), "name": .string("terminal")])
        delegate(transport, "Wait", id: "del_B")
        await waitUntil { conversation.holdingFollowUp }
        transport.events.handle(#"{"type":"session.output_transcript.delta","delta":"Okay.","start_ms":1000,"end_ms":1400}"#)
        delegate(transport, "use staging", id: "del_C")
        XCTAssertEqual(conversation.activeDelegation, "del_C")
        XCTAssertEqual(submits(hermes).count, 1)
        XCTAssertEqual(conversation.interruptsSent, 1, "one stop for the one running turn")
        emit(backend, hermes, "message.complete", ["status": .string("interrupted")])
        await waitUntil { self.submits(hermes).count == 2 }
        XCTAssertEqual(Array(hermes.log.drop { $0 != "session.interrupt" }),
                       ["session.interrupt", "message.complete", "prompt.submit:Wait use staging"])
        emit(backend, hermes, "message.start")
        emit(backend, hermes, "message.complete", ["status": .string("complete"), "text": .string("Deployed to staging.")])
        XCTAssertEqual(transport.commentary, ["Deployed to staging."])
        XCTAssertTrue(transport.sent(type: "session.commentary.append").allSatisfy { $0["delegation_id"].text == "del_C" })
        XCTAssertNil(conversation.activeDelegation)
        XCTAssertEqual(submits(hermes).count, 2)
    }

    func testConnectionLostDuringTheHoldEndsTheCallAndSendsNothing() async {
        let (conversation, backend, transport) = await makeConversation()
        defer { withExtendedLifetime(conversation) {} }
        let hermes = script(backend)
        delegate(transport, "Deploy the site", id: "del_A")
        await waitUntil { self.submits(hermes).count == 1 }
        emit(backend, hermes, "message.start")
        delegate(transport, "Wait", id: "del_B")
        await waitUntil { conversation.holdingFollowUp }
        backend.resumeFailure = .stale
        backend.onDisconnect?(BotFailure.transport)
        await waitUntil { !conversation.holdingFollowUp }
        XCTAssertEqual(conversation.phase, .ended(String(localized: "Lost the connection to Hermes.")))
        XCTAssertEqual(submits(hermes).count, 1)
    }

    // MARK: Status line (Hermes's own gateway events)

    func testStatusLineFollowsHermesWorkingThinkingIdle() async {
        let (conversation, backend, transport) = await makeConversation()
        defer { withExtendedLifetime(conversation) {} }
        XCTAssertEqual(conversation.hermesStatus.label(now: clock), "Idle")
        delegate(transport, "Check CI")
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.emit("message.start")
        advance(3)
        XCTAssertEqual(conversation.hermesStatus.label(now: clock), "Thinking · 0:03")
        backend.emit("tool.start", ["tool_id": .string("t1"), "name": .string("terminal")])
        advance(72)
        XCTAssertEqual(conversation.hermesStatus.label(now: clock), "Working: Running a command · 1:12")
        backend.emit("tool.complete", ["tool_id": .string("t1")])
        advance(2)
        XCTAssertEqual(conversation.hermesStatus.label(now: clock), "Thinking · 0:02")
        backend.emit("message.complete", ["text": .string("All green.")])
        XCTAssertEqual(conversation.hermesStatus.label(now: clock), "Idle")
    }

    func testStatusLineSaysStoppedWhenAnOpenRequestsTurnEndsWithoutAReply() async {
        let (conversation, backend, transport) = await makeConversation()
        defer { withExtendedLifetime(conversation) {} }
        delegate(transport, "Check CI")
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.emit("message.start")
        backend.emit("message.complete", ["status": .string("interrupted")])
        XCTAssertEqual(conversation.hermesStatus.state, .stopped)
        XCTAssertEqual(conversation.hermesStatus.label(now: clock), "Stopped: your last request got no answer")
        backend.emit("message.start")
        XCTAssertEqual(conversation.hermesStatus.state, .thinking, "the next turn clears it")
    }

    /// A delegation whose turn has started, with the progress switch set as given.
    private func progressCall(_ on: Bool) async -> (VoiceLiveConversation, FakeVoiceBackend, FakeLiveTransport) {
        let (conversation, backend, transport) = await makeConversation()
        delegate(transport, "Clean up the build folder")
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.emit("message.start")
        return (conversation, backend, transport)
    }

    /// One remark as the gateway streams it: deltas, then the interim marking them, then a tool.
    private func remark(_ backend: FakeVoiceBackend, _ text: String) {
        backend.emit("message.delta", [ "text": .string(text)])
        backend.emit("message.interim", ["text": .string(text), "already_streamed": .bool(true)])
        backend.emit("tool.start", ["tool_id": .string(UUID().uuidString), "name": .string("terminal")])
    }

    private func progressNotes(_ transport: FakeLiveTransport) -> [String] {
        transport.commentary.filter { $0.hasPrefix("Progress update") }
    }

    /// An update handed over but not yet voiced holds the next, even past the interval, until
    /// GPT-Live has spoken.

    /// Switch off: nothing unprompted, and the reply is spoken as before.
    func testSwitchOffSendsNoProgress() async {
        let (conversation, backend, transport) = await progressCall(false)
        defer { withExtendedLifetime(conversation) {} }
        backend.emit("message.interim", ["text": .string("Listing the folders."), "already_streamed": .bool(false)])
        backend.emit("tool.start", ["tool_id": .string("t1"), "name": .string("terminal")])
        advance(60)
        conversation.tick()
        transport.onSpeakingChange?(true)
        transport.onSpeakingChange?(false)
        backend.emit("tool.complete")
        backend.emit("message.complete", ["text": .string("Done. Freed 4 GB.")])
        XCTAssertEqual(progressNotes(transport), [])
        XCTAssertEqual(transport.commentary.joined(separator: " "), "Done. Freed 4 GB.")
    }

    /// Once the final reply has started, nothing unprompted is said, and the reply is spoken as before.
    func testNoProgressAfterTheFinalReplyStarts() async {
        let (conversation, backend, transport) = await progressCall(true)
        defer { withExtendedLifetime(conversation) {} }
        transport.onSpeakingChange?(true)
        remark(backend, "Deleting the old builds now.")
        backend.emit("tool.complete")
        backend.emit("message.delta", ["text": .string("Done. I freed")])
        advance(VoiceWorkLog.firstDelay)
        transport.onSpeakingChange?(false)
        backend.emit("message.delta", ["text": .string(" 4 GB.")])
        backend.emit("message.interim", ["text": .string("Late remark."), "already_streamed": .bool(false)])
        backend.emit("message.complete", ["text": .string("Done. I freed 4 GB.")])
        XCTAssertEqual(progressNotes(transport), [])
        XCTAssertEqual(transport.commentary.joined(separator: " "), "Done. I freed 4 GB.")
    }

    /// With the switch on, a remark's streamed words go out as the progress note (or not at all),
    /// never also as the start of the reply.
    func testStreamedRemarkIsNotAlsoSpokenAsReply() async {
        let (conversation, backend, transport) = await progressCall(true)
        defer { withExtendedLifetime(conversation) {} }
        transport.onSpeakingChange?(true)
        remark(backend, "Checking the disk.")
        backend.emit("tool.complete")
        backend.emit("message.delta", ["text": .string("All clean.")])
        backend.emit("message.complete", ["text": .string("All clean.")])
        transport.onSpeakingChange?(false)
        XCTAssertEqual(transport.commentary, ["All clean."])
    }
}

@MainActor final class FakeLiveTransport: VoiceLiveTransport {
    var frames: [BotJSON] = []
    var closeCalls = 0
    var mutes: [Bool] = []
    var onSpeakingChange: ((Bool) -> Void)?
    lazy var events: VoiceLiveEvents = VoiceLiveEvents { [unowned self] text in
        self.frames.append(try! JSONDecoder().decode(BotJSON.self, from: Data(text.utf8))); return true
    }
    var startedHistory: [BotJSON] = []
    var startedProfile: String?
    func start(history: [BotJSON], profile: String?) async throws { startedHistory = history; startedProfile = profile }
    func setMuted(_ muted: Bool) { mutes.append(muted); events.mute(muted) }
    var cuts: [Bool] = []
    func setPlayoutCut(_ cut: Bool) { cuts.append(cut) }
    func inputLevel() async -> Double? { 0.25 }
    func outputLevel() async -> Double? { 0.5 }
    var finishOnClose = true
    func close() {
        closeCalls += 1
        _ = events.requestClose()
        if finishOnClose { events.finish("close_requested", nil) }
    }
    func sent(type: String) -> [BotJSON] { frames.filter { $0["type"].text == type } }
    var commentary: [String] { sent(type: "session.commentary.append").compactMap { $0["content"].text } }
}

extension FakeVoiceBackend: VoiceLiveBackend {
    func voiceLiveStatus() async throws -> VoiceLive.Status? { nil }
    func voiceLiveSession(sdp: String, history: [BotJSON], profile: String?) async throws -> (answer: String, sessionID: String?) { ("v=0\r\n", "s") }
}

@MainActor final class VoiceLiveContextTests: XCTestCase {
    private var defaults: UserDefaults!
    private var events: VoiceLiveEvents!
    private var contexts: [String] = []
    private var receivedContexts: [[VoiceLive.Fragment]] = []
    private var clockMs: Double = 0

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "voice.live.context")
        defaults = UserDefaults(suiteName: "VoiceLiveContextTests")
        defaults.removePersistentDomain(forName: "VoiceLiveContextTests")
        events = VoiceLiveEvents { _ in true }
        events.defaults = defaults
        events.onDelegation = { [unowned self] _, fragments in
            contexts.append(VoiceLive.delegationPrompt(fragments).context)
            receivedContexts.append(fragments)
            // This context fixture models successful backend admission, not vendor receipt.
            events.acceptContext(through: events.receivedFragments)
        }
        clockMs = 0
    }

    /// `words` as consecutive deltas of one turn, `stepMs` apart; a new turn starts 1 s later.
    private func say(_ speaker: VoiceLive.Fragment.Speaker, _ words: [String], stepMs: Double = 300) {
        clockMs += 1_000
        for (i, word) in words.enumerated() {
            let type = speaker == .user ? "session.input_transcript.delta" : "session.output_transcript.delta"
            let frame: [String: Any] = ["type": type, "delta": i == 0 ? word : " " + word, "start_ms": clockMs, "end_ms": clockMs + stepMs]
            events.handle(String(decoding: try! JSONSerialization.data(withJSONObject: frame), as: UTF8.self))
            clockMs += stepMs
        }
    }
    private func words(_ prefix: String, _ count: Int) -> [String] { (1...count).map { "\(prefix)\($0)" } }
    private var delegationCount = 0
    private func delegate() {
        delegationCount += 1
        events.handle(#"{"type":"session.delegation.created","delegation":{"id":"del_\#(delegationCount)"}}"#)
    }

    func testUnacceptedDelegationKeepsTheReceivedTailForTheNextRequest() {
        events.onDelegation = { [unowned self] _, fragments in contexts.append(VoiceLive.delegationPrompt(fragments).context) }
        say(.user, ["Remember", "Friday."])
        delegate()
        XCTAssertEqual(events.cutPoint, 0)
        say(.assistant, ["Understood."])
        delegate()
        XCTAssertEqual(contexts[1], "User: Remember Friday.\nVoice assistant: Understood.")
        XCTAssertEqual(events.cutPoint, 0)
    }

    func testAcceptedSnapshotDoesNotConsumeFragmentsReceivedDuringAdmission() {
        say(.user, ["First."])
        let boundary = events.receivedFragments
        say(.assistant, ["Later."])
        events.acceptContext(through: boundary)
        XCTAssertEqual(events.cutPoint, boundary)
        XCTAssertEqual(VoiceLive.delegationContext(events.takeContext()).context, "Voice assistant: Later.")
    }

    func testOlderAcceptanceCannotMoveTheDeliveryBoundaryBackwards() {
        say(.user, ["First."])
        let first = events.receivedFragments
        say(.assistant, ["Second."])
        let second = events.receivedFragments
        events.acceptContext(through: second)
        events.acceptContext(through: first)
        XCTAssertEqual(events.cutPoint, second)
        XCTAssertTrue(events.takeContext().isEmpty)
    }

    func testModeParsingFallsBackToSince() {
        XCTAssertEqual(VoiceLive.ContextMode.defaultsKey, "voice.live.context")
        XCTAssertEqual(VoiceLive.ContextMode(stored: nil), .sinceLastRequest)
        XCTAssertEqual(VoiceLive.ContextMode(stored: "since"), .sinceLastRequest)
        XCTAssertEqual(VoiceLive.ContextMode(stored: "3"), .sinceLastRequest)
        XCTAssertEqual(VoiceLive.ContextMode(stored: "junk"), .sinceLastRequest)
        for n in [1, 2, 5, 10] {
            XCTAssertEqual(VoiceLive.ContextMode(stored: "\(n)"), .lastMinutes(n))
            XCTAssertEqual(VoiceLive.ContextMode.lastMinutes(n).stored, "\(n)")
        }
        XCTAssertEqual(VoiceLive.ContextMode.sinceLastRequest.stored, "since")
    }

    func testFirstRequestGetsEverythingThenEachRequestExactlyWhatFollowedThePrevious() {
        say(.user, words("a", 150)); say(.assistant, words("b", 100)); say(.user, words("c", 60))
        delegate()
        XCTAssertEqual(contexts[0], "User: \(words("a", 150).joined(separator: " "))\n"
                       + "Voice assistant: \(words("b", 100).joined(separator: " "))\nUser: \(words("c", 60).joined(separator: " "))")
        say(.assistant, words("d", 5)); say(.user, words("e", 7))
        delegate()
        XCTAssertEqual(contexts[1], "Voice assistant: \(words("d", 5).joined(separator: " "))\nUser: \(words("e", 7).joined(separator: " "))")
        say(.user, words("f", 3))
        delegate()
        XCTAssertEqual(contexts[2], "User: \(words("f", 3).joined(separator: " "))")
        XCTAssertEqual(receivedContexts.map(\.count), [310, 12, 3])
    }

    func testGroundRuleSaidThreeHundredWordsEarlierIsInTheContext() {
        say(.user, ["From", "now", "on", "only", "note", "decisions,", "don't", "act", "on", "them."])
        say(.assistant, ["Got", "it."])
        say(.user, words("talk", 300))
        say(.user, ["please", "note", "that", "we", "ship", "Friday"])
        delegate()
        XCTAssertEqual(contexts.count, 1)
        XCTAssertTrue(contexts[0].hasPrefix("User: From now on only note decisions, don't act on them.\n"), String(contexts[0].prefix(120)))
        XCTAssertTrue(contexts[0].hasSuffix("please note that we ship Friday"))
    }

    func testOverSixThousandCharsKeepsTheNewestWholeTurnsAfterTheMarker() {
        let turns = (1...12).map { t in words("t\(t)w", 80) }  // ~12 × 450 chars
        for (i, turn) in turns.enumerated() { say(i.isMultiple(of: 2) ? .user : .assistant, turn) }
        delegate()
        let text = contexts[0]
        XCTAssertLessThanOrEqual(text.count, VoiceLive.contextCharLimit)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, VoiceLive.contextCutMarker)
        XCTAssertEqual(lines.last, "Voice assistant: \(turns[11].joined(separator: " "))", "newest turn kept whole")
        // Every kept line is a whole turn, consecutive up to the newest.
        let kept = lines.dropFirst()
        let firstKept = 12 - kept.count
        for (offset, line) in kept.enumerated() {
            let t = firstKept + offset
            XCTAssertEqual(line, "\(t.isMultiple(of: 2) ? "User" : "Voice assistant"): \(turns[t].joined(separator: " "))")
        }
        XCTAssertGreaterThan(firstKept, 0)
        // Adding the dropped turn back would overflow.
        let droppedLine = "\((firstKept - 1).isMultiple(of: 2) ? "User" : "Voice assistant"): \(turns[firstKept - 1].joined(separator: " "))"
        XCTAssertGreaterThan(text.count + droppedLine.count + 1, VoiceLive.contextCharLimit)
        XCTAssertEqual(VoiceLive.delegationPrompt([.init(speaker: .user, text: "short", startMs: 0, endMs: 1)]).context, "User: short")
    }

    func testMinutesModeHonoursTheWindowWithNoFragmentCap() {
        defaults.set("2", forKey: VoiceLive.ContextMode.defaultsKey)
        say(.user, words("old", 50), stepMs: 1_000)   // ends ~51 s
        clockMs += 120_000
        say(.user, words("new", 400), stepMs: 250)    // 100 s of talk, inside 2 min
        delegate()
        XCTAssertEqual(contexts[0], "User: \(words("new", 400).joined(separator: " "))")
        XCTAssertEqual(receivedContexts[0].count, 400)
        // Minutes mode doesn't depend on the previous request: asking again repeats the window.
        delegate()
        XCTAssertEqual(contexts[1], contexts[0])
    }

    func testChangingTheSettingMidSessionAppliesToTheNextRequest() {
        say(.user, words("a", 20), stepMs: 1_000)
        delegate()
        XCTAssertEqual(contexts[0], "User: \(words("a", 20).joined(separator: " "))")
        defaults.set("1", forKey: VoiceLive.ContextMode.defaultsKey)
        say(.user, words("b", 10), stepMs: 1_000)
        delegate()
        // 1 minute back from b10's end reaches into the a-turn (a-words end every second).
        XCTAssertTrue(contexts[1].hasPrefix("User: a"), contexts[1])
        XCTAssertTrue(contexts[1].hasSuffix("b10"))
        defaults.set("since", forKey: VoiceLive.ContextMode.defaultsKey)
        say(.user, words("c", 4))
        delegate()
        XCTAssertEqual(contexts[2], "User: c1 c2 c3 c4")
    }

    /// The 2,000 → 1,500 memory bound only removes fragments before the cut point (and outside
    /// the longest minutes window), so a since-last request never loses its start.
    func testTranscriptTrimNeverDropsFragmentsAfterTheCutPoint() {
        say(.user, words("x", 100), stepMs: 1_000)
        delegate()
        say(.user, words("y", 2_500), stepMs: 10)
        delegate()
        XCTAssertEqual(receivedContexts[1].count, 2_500, "every fragment after the previous request is still there")
        XCTAssertTrue(contexts[1].hasSuffix(" y2500"))
        XCTAssertEqual(events.transcript.first?.text, "x1", "nothing before the cut was trimmed either: it is inside the 10-minute window")
        say(.user, words("z", 2_100), stepMs: 1_000)   // 35 min of talk: x and y leave the 10-minute window
        XCTAssertEqual(events.trimmedFragments, 2_600, "everything before the cut point went, nothing after it")
        XCTAssertEqual(events.transcript.first?.text, "z1")
        delegate()
        XCTAssertEqual(receivedContexts[2].count, 2_100)
    }
}
