import XCTest
@testable import HermesMobile

/// #115: spoken progress from the real work. Steps come from Hermes's gateway events with the
/// detail the tool cards already show; updates are paced on an injected clock.
@MainActor final class VoiceWorkStepsTests: XCTestCase {
    private func tool(_ name: String, _ args: [String: BotJSON] = [:]) -> BotJSON {
        .object(["tool_id": .string(UUID().uuidString), "name": .string(name), "args": .object(args)])
    }

    // MARK: Steps -> summary text

    /// Each step names the specific thing (file, query, site, command), as the tool card's
    /// detail does, and never the raw tool name.
    func testStepsCarryTheCardsDetailAndNoToolNames() {
        let steps = [
            VoiceWorkStep.tool(tool("read_file", ["path": .string("/Users/a/dev/HermesMobile/Features/Voice/VoiceOrb.swift")])),
            VoiceWorkStep.tool(tool("search_files", ["pattern": .string("closeForBackground")])),
            VoiceWorkStep.tool(tool("web_extract", ["url": .string("https://developer.apple.com/documentation/avfaudio")])),
            VoiceWorkStep.tool(tool("terminal", ["command": .string("bash -lc \"git status\"")])),
            VoiceWorkStep.tool(tool("patch", ["path": .string("Sources/App.swift")])),
            VoiceWorkStep.tool(tool("delegate_task", ["goal": .string("check the build logs")])),
            VoiceWorkStep.event("subagent.complete", .object(["goal": .string("check the build logs"), "status": .string("completed")])),
            VoiceWorkStep.event("background.complete", .object(["task_id": .string("t1"), "text": .string("done")])),
            VoiceWorkStep.remark("I'll look at the orb next."),
        ].compactMap { $0 }
        XCTAssertEqual(steps, [
            "reading VoiceOrb.swift",
            "searching for closeForBackground",
            "looking at https://developer.apple.com/documentation/avfaudio",
            "running git status",
            "editing App.swift",
            "asking a helper to check the build logs",
            "a helper finished check the build logs",
            "a background job finished",
            "Hermes said: I'll look at the orb next",
        ])
        let summary = VoiceWorkLog.summary(steps)
        for raw in ["read_file", "search_files", "web_extract", "terminal", "patch", "delegate_task"] {
            XCTAssertFalse(summary.contains(raw), "no raw tool name: \(raw)")
        }
        // Read ranges read as the card shows them.
        XCTAssertEqual(VoiceWorkStep.tool(tool("read_file", ["path": .string("a/VoiceOrb.swift"), "offset": .number(10), "limit": .number(20)])),
                       "reading L10-29 · VoiceOrb.swift")
        // A tool the formatter doesn't know is told by its detail, else not at all.
        XCTAssertEqual(VoiceWorkStep.tool(tool("mcp__linear__get_issue", ["query": .string("ARX-12")])), "working on ARX-12")
        XCTAssertNil(VoiceWorkStep.tool(tool("mcp__linear__get_issue")))
        XCTAssertNil(VoiceWorkStep.event("subagent.thinking", .object(["text": .string("hmm")])))
    }

    /// The silent context lists every step so far, newest last, capped to the newest few.
    func testContextListsTheStepsNewestLast() {
        var log = VoiceWorkLog()
        XCTAssertNil(log.context)
        log.begin(at: Date(timeIntervalSince1970: 0))
        log.add("reading VoiceOrb.swift")
        log.add("reading VoiceOrb.swift")
        log.add("running git status")
        XCTAssertEqual(log.steps, ["reading VoiceOrb.swift", "running git status"], "a repeat is the same step")
        XCTAssertTrue(log.context?.contains("reading VoiceOrb.swift; running git status") == true)
        for i in 0..<10 { log.add("step \(i)") }
        XCTAssertTrue(log.context?.contains("4 earlier steps; step 2;") == true, log.context ?? "")
    }

    // MARK: Timing (injected clock)





    // MARK: Through the GPT-Live call

    var clock = Date(timeIntervalSince1970: 1_000)

    private func call(progress on: Bool) async -> (VoiceLiveConversation, FakeVoiceBackend, FakeLiveTransport) {
        let backend = FakeVoiceBackend(), transport = FakeLiveTransport()
        let conversation = VoiceLiveConversation(backend: backend, makeTransport: { transport },
                                                 now: { [unowned self] in self.clock }, reconnectDelay: { _ in })
        await conversation.start()
        transport.events.handle(#"{"type":"session.started","session":{"id":"s"}}"#)
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Fix the orb","start_ms":0,"end_ms":900}"#)
        transport.events.handle(#"{"type":"session.delegation.created","delegation":{"id":"del_1"}}"#)
        await waitUntil { backend.calls.contains { $0.0 == "prompt.submit" } }
        backend.emit("message.start")
        return (conversation, backend, transport)
    }

    private func toolStart(_ backend: FakeVoiceBackend, _ name: String, _ args: [String: BotJSON]) {
        backend.emit("tool.start", ["tool_id": .string(UUID().uuidString), "name": .string(name), "args": .object(args)])
    }

    private func updates(_ transport: FakeLiveTransport) -> [String] {
        transport.commentary.filter { $0.hasPrefix("Progress update") }
    }

    private func thoughts(_ transport: FakeLiveTransport) -> [String] {
        transport.sent(type: "session.thinking.append").compactMap { $0["content"].text }
    }

    /// Switch off: nothing unprompted is said, and no step is pushed at GPT-Live on its own;
    /// when the user speaks while Hermes works, the step list reaches GPT-Live as silent context
    /// before it answers, so "what are you doing?" is answered from it.
    func testOnDemandContextIsPresentWithTheSwitchOff() async {
        let (conversation, backend, transport) = await call(progress: false)
        defer { withExtendedLifetime(conversation) {} }
        toolStart(backend, "read_file", ["path": .string("HermesMobile/Features/Voice/VoiceOrb.swift")])
        toolStart(backend, "terminal", ["command": .string("git status")])
        clock = clock.addingTimeInterval(60)
        conversation.tick()
        XCTAssertEqual(updates(transport), [])
        XCTAssertEqual(thoughts(transport), [], "nothing until the user speaks")
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"What are you doing","start_ms":5000,"end_ms":5600}"#)
        XCTAssertEqual(thoughts(transport).count, 1)
        let context = thoughts(transport).last ?? ""
        XCTAssertTrue(context.contains("reading VoiceOrb.swift; running git status"), context)
        XCTAssertTrue(context.contains("Only if the user asks what Hermes is doing"), context)
        XCTAssertTrue(context.contains("Do not mention these steps on your own"), context)
        XCTAssertFalse(thoughts(transport).contains { $0.contains("read_file") || $0.contains(": terminal") })
    }

    /// Switch on, no remarks at all: the first update comes after the delay with the steps,
    /// the next only once the work moved on and the interval passed, none while GPT-Live
    /// speaks, none once the answer started.

}
