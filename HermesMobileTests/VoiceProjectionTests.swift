import XCTest
@testable import HermesMobile

@MainActor final class VoiceProjectionTests: XCTestCase {
    private let fixture = VoiceLiveTests()

    func testSentAppendStaysBetweenSpokenSegmentsAndCanBeHidden() async {
        let (conversation, _, transport) = await fixture.makeConversation()
        transport.events.handle(#"{"type":"session.input_transcript.delta","delta":"Question","start_ms":0,"end_ms":200}"#)
        transport.onSpeakingChange?(true)
        transport.events.handle(#"{"type":"session.output_transcript.delta","delta":"Answer","start_ms":250,"end_ms":500}"#)
        conversation.tapToInterrupt()
        let shown = VoiceTranscriptProjection.rows(conversation.transcript, mode: .full, filter: .all).all
        XCTAssertEqual(shown.filter { $0.role == "user" }.map(\.content), ["Question"])
        XCTAssertEqual(shown.filter { $0.role == "assistant" }.map(\.content), ["Answer"])
        XCTAssertEqual(shown.last?.voiceAppend?.kind, .instructions)
        XCTAssertEqual(shown.filter { $0.voiceAppend != nil }.count, 1)
        let hidden = VoiceTranscriptProjection.rows(conversation.transcript, mode: .full,
            filter: TranscriptSegmentFilter(appends: false, thinkingAndTools: true)).all
        XCTAssertTrue(hidden.allSatisfy { $0.voiceAppend == nil })
        XCTAssertEqual(hidden.map(\.content), ["Question", "Answer"])
    }

    func testHistoryAndLiveUserAreProjectedOnce() {
        let model = VoiceTranscriptModel()
        model.loadHistory([
            ChatMessage(role: "user", content: "Earlier", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: "Saved answer", timestamp: 2, messageId: "a1")], hasOlder: false)
        let rows = VoiceTranscriptProjection.rows(model, mode: .full, filter: .all).all
        XCTAssertEqual(rows.compactMap(\.content), ["Earlier", "Saved answer"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
}
