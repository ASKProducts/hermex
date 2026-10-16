import SwiftUI
import XCTest
@testable import HermesMobile

@MainActor final class VoiceEngineTests: XCTestCase {
    private let live = VoiceLiveTests()

    private func liveConversation() async -> (VoiceLiveConversation, FakeVoiceBackend, FakeLiveTransport) {
        await live.makeConversation()
    }

    private func testConnection() -> BotConnection {
        BotConnection(id: UUID(), name: "Voice test", address: URL(string: "http://127.0.0.1:9")!, username: "u", password: "p")
    }

    // MARK: Per-call presentation payload

    func testPresentationCapturesExplicitModeAndResumeIdentityTogether() {
        let server = URL(string: "https://call.invalid")!
        let call = VoiceCallPresentation(server: server, requestedMode: .live, resumeSessionKey: "owned-chat", resumeProfile: "work")
        XCTAssertEqual(call.server, server)
        XCTAssertEqual(call.requestedMode, .live)
        XCTAssertEqual(call.resumeSessionKey, "owned-chat")
        XCTAssertEqual(call.resumeProfile, "work")
    }

    func testNewCallHasNoResumeIdentity() {
        let call = VoiceCallPresentation(server: URL(string: "https://call.invalid")!, requestedMode: .normal)
        XCTAssertEqual(call.requestedMode, .normal)
        XCTAssertNil(call.resumeSessionKey)
        XCTAssertNil(call.resumeProfile)
    }

    func testNextPresentationDoesNotChangePreviouslyCapturedCall() {
        let server = URL(string: "https://call.invalid")!
        let first = VoiceCallPresentation(server: server, requestedMode: .live, resumeSessionKey: "first", resumeProfile: "work")
        var presented: VoiceCallPresentation? = first
        presented = nil // native item dismissal clears the launch payload
        presented = VoiceCallPresentation(server: server, requestedMode: .normal, resumeSessionKey: "second", resumeProfile: "default")
        XCTAssertEqual(first.requestedMode, .live)
        XCTAssertEqual(first.resumeSessionKey, "first")
        XCTAssertEqual(first.resumeProfile, "work")
        XCTAssertEqual(presented?.requestedMode, .normal)
        XCTAssertEqual(presented?.resumeSessionKey, "second")
        XCTAssertEqual(presented?.resumeProfile, "default")
        XCTAssertNotEqual(first.id, presented?.id)
    }

    func testSameModeCallsHaveIndependentNativePresentationIdentity() {
        let server = URL(string: "https://call.invalid")!
        let first = VoiceCallPresentation(server: server, requestedMode: .normal)
        let second = VoiceCallPresentation(server: server, requestedMode: .normal)
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: Engine interface

    func testBothEnginesImplementTheScreenInterface() async {
        let (conversation, _, _) = await liveConversation()
        let engines: [any VoiceEngine] = [VoiceSession(backend: FakeVoiceBackend(), player: FakePlayer()), conversation]
        XCTAssertEqual(engines.map(\.mode), [.normal, .live])
        XCTAssertEqual(engines.map(\.tickInterval), [.seconds(1), .milliseconds(200)])
        XCTAssertEqual(engines[1].phase, .listening)
        XCTAssertTrue(engines[1].transcript.isEmpty)
        XCTAssertFalse(engines[1].debugLine.isEmpty)
    }

    func testStartModeFallsBackToNormalWhenLiveUnavailable() {
        XCTAssertEqual(VoiceScreenModel.startMode(preferred: .live, liveAvailable: true), .live)
        XCTAssertEqual(VoiceScreenModel.startMode(preferred: .live, liveAvailable: false), .normal)
        XCTAssertEqual(VoiceScreenModel.startMode(preferred: .normal, liveAvailable: true), .normal)
    }

    // MARK: GPT-Live transcript rows

    func testLiveTranscriptRowsUserVoiceDelegationApproval() async {
        let (conversation, backend, transport) = await liveConversation()
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"What time","start_ms":0,"end_ms":400}"#)
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":" is it?","start_ms":400,"end_ms":900}"#)
        transport.events.handle(#"{"type":"session.output_transcript.delta","delta":"Checking","start_ms":1000,"end_ms":1300}"#)
        transport.events.handle(#"{"type":"session.output_transcript.delta","delta":" now.","start_ms":1300,"end_ms":1500}"#)
        transport.events.handle(#"{"type":"session.delegation.created","delegation":{"id":"del_9"}}"#)
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.emit("message.start")
        backend.emit("tool.start", ["name": .string("terminal")])
        backend.onEvent?(.object(["jsonrpc": .string("2.0"), "id": .string("srv-1"), "method": .string("approval"), "params": .object([
            "session_id": .string("rt-1"), "request_id": .string("req-1"), "command": .string("touch /tmp/x"),
            "choices": .array([.string("once"), .string("deny")])])]))
        // One exchange in the chat's turn model: the user's words as the user row, the voice's words as
        // the reply, the delegation as a running "Hermes" card holding Hermes's own tool card.
        let transcript = conversation.transcript
        XCTAssertEqual(transcript.liveUserMessage?.content, "What time is it?")
        XCTAssertEqual(Array(segments(transcript.liveTurn).prefix(2)), ["text:Checking now.", "tool:delegation:del_9:Hermes:running"])
        let rows = segments(transcript.liveTurn)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows[2].hasPrefix("tool:terminal#"), "Hermes's tool inside the exchange")
        XCTAssertEqual(Array(rows.suffix(1)), ["append:1"])
        XCTAssertEqual(transport.sent(type: "session.thinking.append").count, 0)
        XCTAssertEqual(transport.sent(type: "session.commentary.append").last?["content"].text,
                       "Hermes wants to touch /tmp/x. Ask the user to say approve or deny.")
        XCTAssertTrue(conversation.notice?.contains("touch /tmp/x") == true, "approval prompt above the dock")
        backend.emit("message.complete", ["text": .string("It is noon.")])
        XCTAssertEqual(Array(segments(conversation.transcript.liveTurn).prefix(2)), ["text:Checking now.", "tool:delegation:del_9:Hermes:done"])
    }

    func testDelegationReceiptAnchorsItsCommentaryInTheRefetchedTurn() async throws {
        let (conversation, backend, transport) = await liveConversation()
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"What time is it?","start_ms":0,"end_ms":400}"#)
        transport.events.handle(#"{"type":"session.delegation.created","delegation":{"id":"del_9"}}"#)
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.emit("message.start")
        backend.emit("message.complete", ["text": .string("It is noon."), "status": .string("complete"),
                                          "persisted_turn": .object(["user_row_id": .number(503),
                                                                     "row_ids": .array([.number(503), .number(504)]),
                                                                     "complete": .bool(true)])])
        conversation.tick()
        XCTAssertEqual(transport.sent(type: "session.commentary.append").last?["content"].text, "It is noon.")
        let transcript = conversation.transcript
        transcript.finishExchange()
        var asked = ChatMessage(role: "user", content: "What time is it?", timestamp: 1, messageId: nil)
        asked.serverID = 503
        var answered = ChatMessage(role: "assistant", content: "It is noon.", timestamp: 2, messageId: nil)
        answered.serverID = 504
        transcript.loadHistory([asked, answered], hasOlder: false)
        XCTAssertTrue(transcript.appendEvents(.full, showsAppends: true).isEmpty)
        let turn = try XCTUnwrap(transcript.settledTurns.last)
        XCTAssertEqual(turn.userMessageID, 503)
        XCTAssertEqual(segments(turn), ["text:It is noon.", "append:1"])
    }

    // MARK: Tap to interrupt

    func testTapCutsPlayoutImmediatelyThenRestoresForNextResponse() async {
        let (conversation, _, transport) = await liveConversation()
        transport.onSpeakingChange?(true)
        transport.events.handle(#"{"type":"session.output_transcript.delta","delta":"A long story about","start_ms":0,"end_ms":900}"#)
        XCTAssertEqual(conversation.phase, .speaking)
        conversation.tapToInterrupt()
        XCTAssertEqual(transport.cuts, [true], "audio is cut at the tap, before the model reacts")
        XCTAssertEqual(transport.sent(type: "session.instructions.append").last?["content"].text,
                       "The user tapped to interrupt you. Stop speaking now and listen.")
        XCTAssertEqual(conversation.phase, .listening)
        XCTAssertEqual(conversation.transcript.liveTurn?.state, .interrupted(runID: "live:1"))
        // Words of the cut response still arriving are not shown as said; the interrupt
        // instruction sent at the tap sits after the cut words.
        transport.events.handle(#"{"type":"session.output_transcript.delta","delta":" a lighthouse","start_ms":900,"end_ms":1200}"#)
        XCTAssertEqual(segments(conversation.transcript.liveTurn), ["text:A long story about", "append:1"])
        conversation.tapToInterrupt()
        XCTAssertEqual(transport.cuts, [true], "a second tap while cut does nothing")
        transport.onSpeakingChange?(false)
        XCTAssertEqual(transport.cuts, [true, false], "restored once the cut response ended")
    }

    func testUserSpeechRestoresPlayoutForTheAnswer() async {
        let (conversation, _, transport) = await liveConversation()
        transport.onSpeakingChange?(true)
        conversation.tapToInterrupt()
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Just the year","start_ms":0,"end_ms":900}"#)
        XCTAssertEqual(transport.cuts, [true, false])
    }

    // MARK: Initial history seed

    func testHandoffKeepsChatAndSpokenWords() {
        // The transcript's rows (saved and GPT-Live's local ones): user and assistant text, no
        // steers or tool rows, in order.
        func row(_ role: String, _ text: String?, kind: String? = nil) -> ChatMessage {
            ChatMessage(role: role, content: text, timestamp: nil, messageId: nil, displayKind: kind)
        }
        let messages = [row("user", "Earlier question"), row("assistant", nil), row("tool", "ok"),
                        row("user", "use UTC", kind: ChatMessage.steerDisplayKind),
                        row("assistant", "It is Thursday. ")]
        let handoff = VoiceHandoff(sessionKey: "chat-1", fallbackKey: "resume", messages: messages)
        XCTAssertEqual(handoff.resumeSessionKey, "chat-1")
        XCTAssertEqual(handoff.earlier, [.init(fromUser: true, text: "Earlier question"),
                                         .init(fromUser: false, text: "It is Thursday.")])
        XCTAssertEqual(VoiceHandoff(sessionKey: nil, fallbackKey: "resume", messages: messages).resumeSessionKey, "resume")
        XCTAssertEqual(handoff.seedTurns.map(\.role), ["user", "assistant"])
    }

    func testContinueByVoiceSeedsLiveHistoryWithWholeMessageCaps() async {
        // 30 turns of >1,500 bytes: the seed keeps the newest ten whole messages in 16,000 bytes.
        let lines = (0..<30).map { VoiceHandoff.Line(fromUser: $0 % 2 == 0, text: "turn \($0) " + String(repeating: "x", count: 1_500)) }
        let handoff = VoiceHandoff(resumeSessionKey: "chat-1", earlier: lines)
        let backend = FakeVoiceBackend()
        let transport = FakeLiveTransport()
        let conversation = VoiceLiveConversation(backend: backend, makeTransport: { transport }, resumeSessionKey: "chat-1",
                                                 seedHistory: handoff.seedTurns)
        await conversation.start()
        XCTAssertEqual(transport.startedHistory.count, 10)
        XCTAssertEqual(transport.startedHistory.compactMap { $0["content"].list?.first?["text"].text }, lines.suffix(10).map(\.text))
        // 24-turn cap with short turns.
        let short = (0..<30).map { VoiceHandoff.Line(fromUser: $0 % 2 == 0, text: "t\($0)") }
        XCTAssertEqual(VoiceLive.history(VoiceHandoff(resumeSessionKey: nil, earlier: short).seedTurns).count, 24)
        XCTAssertEqual(backend.calls.first?.0, "session.resume")
        XCTAssertEqual(conversation.sessionKey, "chat-1")
    }

    // MARK: Screen model

    func testCallSelectionDoesNotRereadSettingsAfterCapture() throws {
        let saved = UserDefaults.standard.object(forKey: "voice.defaultMode")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "voice.defaultMode") }
            else { UserDefaults.standard.removeObject(forKey: "voice.defaultMode") }
        }
        UserDefaults.standard.set(VoiceMode.normal.rawValue, forKey: "voice.defaultMode")
        let connection = BotConnection(id: UUID(), name: "t", address: try BotConnection.address("http://127.0.0.1:9"),
                                       username: "u", password: "p")
        let model = VoiceScreenModel(server: URL(string: "https://example.invalid")!, connection: connection, resumeSessionKey: nil, requestedMode: .normal)
        UserDefaults.standard.set(VoiceMode.live.rawValue, forKey: "voice.defaultMode")
        XCTAssertEqual(model.mode, .normal, "call mode must be captured, not reread during presentation or startup")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "voice.defaultMode"), VoiceMode.live.rawValue, "launch selection never writes the legacy preference")
    }

    func testExplicitModeOverridesOnlyThisCallAndNextLaunchUsesSettings() throws {
        let saved = UserDefaults.standard.object(forKey: "voice.defaultMode")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "voice.defaultMode") }
            else { UserDefaults.standard.removeObject(forKey: "voice.defaultMode") }
        }
        let connection = BotConnection(id: UUID(), name: "t", address: try BotConnection.address("http://127.0.0.1:9"),
                                       username: "u", password: "p")
        for preferred in VoiceMode.allCases {
            UserDefaults.standard.set(preferred.rawValue, forKey: "voice.defaultMode")
            for override in VoiceMode.allCases {
                let model = VoiceScreenModel(server: URL(string: "https://example.invalid")!, connection: connection,
                                             resumeSessionKey: "chat-1", requestedMode: override)
                XCTAssertEqual(model.mode, override)
                XCTAssertEqual(UserDefaults.standard.string(forKey: "voice.defaultMode"), preferred.rawValue)
                let next = VoiceScreenModel(server: URL(string: "https://example.invalid")!, connection: connection,
                                            resumeSessionKey: nil)
                next.applyLiveStatus(.init(mode: preferred.hostValue, available: true, reason: nil, model: nil, voice: nil))
                XCTAssertEqual(next.mode, preferred)
            }
        }
    }

    func testFixedCallClosesOnEngineEndUntilUserEndsIt() async throws {
        let connection = BotConnection(id: UUID(), name: "t", address: try BotConnection.address("http://127.0.0.1:9"),
                                       username: "u", password: "p")
        let model = VoiceScreenModel(server: URL(string: "https://example.invalid")!, connection: connection, resumeSessionKey: "chat-1", requestedMode: .normal)
        XCTAssertTrue(model.closesOnEngineEnd)
        await model.end()
        XCTAssertFalse(model.closesOnEngineEnd)
        XCTAssertEqual(model.mode, .normal)
    }

    func testDockHasOneEndAndNoOpenChat() throws {
        let host = UIHostingController(rootView: VoiceDock(muted: false, toggleMute: {}, end: {}))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        var labels: [String] = []
        var queue: [Any] = [host.view!]
        while let next = queue.popLast() {
            guard let object = next as? NSObject else { continue }
            if object.isAccessibilityElement, let label = object.accessibilityLabel { labels.append(label) }
            if let view = object as? UIView { queue += view.subviews }
            let count = object.accessibilityElementCount()
            if count != NSNotFound { for index in 0..<count { object.accessibilityElement(at: index).map { queue.append($0) } } }
        }
        XCTAssertEqual(Set(labels), ["Mute", "End"], "dock buttons: \(labels)")
        XCTAssertEqual(VoiceDock.buttonIdentifiers, ["voice-mute", "voice-end"])
    }

    func testEndReturnsTheCallsChatOrNilWhenNoneWasMade() async throws {
        let connection = BotConnection(id: UUID(), name: "t", address: try BotConnection.address("http://127.0.0.1:9"),
                                       username: "u", password: "p")
        let resumed = VoiceScreenModel(server: URL(string: "https://example.invalid")!, connection: connection,
                                       resumeSessionKey: "chat-1", requestedMode: .normal)
        let resumedChat = await resumed.endAndReturnChat()
        XCTAssertEqual(resumedChat, "chat-1")
        XCTAssertTrue(resumed.endedByUser)
        for mode in VoiceMode.allCases {
            let fresh = VoiceScreenModel(server: URL(string: "https://example.invalid")!, connection: connection,
                                         resumeSessionKey: nil, requestedMode: mode)
            let freshChat = await fresh.endAndReturnChat()
            XCTAssertNil(freshChat, "\(mode): no request was made, so there is no chat to open")
        }
    }

    func testAvailabilityRejectsOldServerCompletion() async {
        let first = VoiceStartScope(server: URL(string: "https://first.invalid")!, connection: testConnection())
        let second = VoiceStartScope(server: URL(string: "https://second.invalid")!, connection: testConnection())
        let availability = VoiceStartAvailability()
        let entered = expectation(description: "old request suspended")
        var reply: CheckedContinuation<VoiceLive.Status?, Never>?
        let task = Task {
            await availability.refresh(scope: first, load: { _ in
                await withCheckedContinuation { reply = $0; entered.fulfill() }
            }, currentScope: { first })
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(availability.state, .checking)
        await availability.refresh(scope: second, load: { _ in
            .init(mode: "gpt-live", available: false, reason: "No provider", model: nil, voice: nil)
        }, currentScope: { second })
        reply?.resume(returning: .init(mode: "gpt-live", available: true, reason: nil, model: nil, voice: nil))
        await task.value
        XCTAssertEqual(availability.scope, second)
        XCTAssertEqual(availability.state, .unavailable("No provider"), "old server must not enable the new server's Live choice")
    }

    func testAvailabilityRejectsCancelledCompletion() async {
        let scope = VoiceStartScope(server: URL(string: "https://first.invalid")!, connection: testConnection())
        let availability = VoiceStartAvailability()
        let entered = expectation(description: "request suspended")
        var reply: CheckedContinuation<VoiceLive.Status?, Never>?
        let task = Task {
            await availability.refresh(scope: scope, load: { _ in
                await withCheckedContinuation { reply = $0; entered.fulfill() }
            }, currentScope: { scope })
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        reply?.resume(returning: .init(mode: "gpt-live", available: true, reason: nil, model: nil, voice: nil))
        await task.value
        XCTAssertEqual(availability.state, .checking, "cancelled request must not publish availability")
    }

    func testAvailabilityRejectsChangedConnectionWithoutAnotherRequest() async throws {
        let server = URL(string: "https://first.invalid")!
        let first = BotConnection(id: UUID(), name: "t", address: try BotConnection.address("http://127.0.0.1:9"), username: "u", password: "p")
        var replaced = first
        replaced.password = "changed-test-password"
        let scope = VoiceStartScope(server: server, connection: first)
        let availability = VoiceStartAvailability()
        await availability.refresh(scope: scope, load: { _ in
            .init(mode: "gpt-live", available: true, reason: nil, model: nil, voice: nil)
        }, currentScope: { VoiceStartScope(server: server, connection: replaced) })
        XCTAssertEqual(availability.state, .checking)
    }

    func testAvailabilityCheckingFailureMissingRouteAndReason() async {
        let scope = VoiceStartScope(server: URL(string: "https://first.invalid")!, connection: testConnection())
        let availability = VoiceStartAvailability()
        XCTAssertFalse(availability.state.liveAvailable)
        XCTAssertNotNil(availability.state.reason)
        await availability.refresh(scope: scope, load: { _ in throw URLError(.notConnectedToInternet) }, currentScope: { scope })
        XCTAssertEqual(availability.state, .failed)
        XCTAssertFalse(availability.state.liveAvailable)
        await availability.refresh(scope: scope, load: { _ in nil }, currentScope: { scope })
        XCTAssertFalse(availability.state.liveAvailable)
        XCTAssertNotNil(availability.state.reason)
        await availability.refresh(scope: scope, load: { _ in
            .init(mode: "gpt-live", available: true, reason: nil, model: nil, voice: nil)
        }, currentScope: { scope })
        XCTAssertTrue(availability.state.liveAvailable)
        XCTAssertNil(availability.state.reason)
    }

    func testOutputItemsJoinWithASpaceButWordPiecesDoNot() async {
        let (conversation, _, transport) = await liveConversation()
        transport.onSpeakingChange?(true)
        for (start, delta) in [(11000, "Okay."), (12200, "Lighth"), (12400, "ouses"), (12600, " use"), (12800, " a"),
                               (13000, " powerful"), (13400, " light,")] {
            transport.events.handle(#"{"type":"session.output_transcript.delta","start_ms":\#(start),"end_ms":\#(start + 200),"delta":"\#(delta)"}"#)
        }
        XCTAssertEqual(conversation.replyText, "Okay. Lighthouses use a powerful light,")
        XCTAssertEqual(segments(conversation.transcript.liveTurn), ["text:Okay. Lighthouses use a powerful light,"])
    }

    func testInputSegmentsJoinWithASpace() async {
        let (conversation, _, transport) = await liveConversation()
        for (start, delta) in [(3400, "Say"), (3600, " the"), (3800, " word"), (4400, " okay"), (5000, ", then"), (5400, ", as a"),
                               (7800, " two"), (8400, "-sentence"), (10400, ". Don't")] {
            transport.events.handle(#"{"type":"session.input_transcript.delta","start_ms":\#(start),"end_ms":\#(start + 200),"delta":"\#(delta)"}"#)
        }
        XCTAssertEqual(conversation.caption, "Say the word okay, then, as a two-sentence. Don't")
        XCTAssertEqual(conversation.transcript.liveUserMessage?.content, "Say the word okay, then, as a two-sentence. Don't")
    }

    private func segments(_ turn: ChatTurn?) -> [String] {
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
}
