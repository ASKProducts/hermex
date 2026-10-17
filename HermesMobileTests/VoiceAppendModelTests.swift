import XCTest
@testable import HermesMobile

@MainActor final class VoiceAppendModelTests: XCTestCase {
    private func append(_ ordinal: Int, call: String = "call") -> VoiceAppendObservation {
        VoiceAppendObservation(callID: call, ordinal: ordinal, kind: .instructions, eventID: .value("instr_1"),
                               delegationID: .null, content: "outgoing only", rawJSON: "{\"content\":\"outgoing only\"}", locallySent: true)
    }

    private func appendOrdinals(_ rows: [ChatMessage]) -> [Int] { rows.compactMap { $0.voiceAppend?.ordinal } }

    func testNoTurnAppendRemainsOutsideHistoryAndActivityToggleOnlyChangesVisibility() {
        let model = VoiceTranscriptModel()
        model.recordAppend(append(1))
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.live)
        XCTAssertTrue(model.display(.current, TranscriptSegmentFilter(appends: false)).messages.isEmpty)
        model.recordAppend(append(2))
        XCTAssertEqual(appendOrdinals(model.display(.current).messages), [1, 2])
        XCTAssertEqual(appendOrdinals(model.display(.full).messages), [1, 2])
        model.loadHistory([], reachedStart: true)
        XCTAssertEqual(appendOrdinals(model.display(.full).messages), [1, 2])
    }

    func testNewUtteranceCapturesCurrentExchangeEvenWhenEarlierDelegationStillFinishes() {
        let model = VoiceTranscriptModel()
        model.liveUserSpeech("old speech", startsSegment: true)
        model.delegationStarted(id: "old-delegation", prompt: "old request")
        model.recordAppend(append(1))
        model.liveUserSpeech("new speech", startsSegment: true)
        model.delegationFinished(id: "old-delegation")
        model.recordAppend(append(2))
        // Each append is a part of the exchange on screen when it was sent, not a row between turns.
        XCTAssertEqual(model.localTurns.map(\.described), [["tool:delegation:old-delegation:Hermes:done", "append:1"]])
        XCTAssertEqual(model.live?.described, ["append:2"], "the old card's finish never lands in the new exchange")
        XCTAssertEqual(appendOrdinals(model.display(.current).messages), [2])
        XCTAssertEqual(appendOrdinals(model.display(.full).messages), [1, 2])
        model.finishExchange()
        XCTAssertEqual(appendOrdinals(model.display(.current).messages), [2])
    }

    func testHistoryReplacementRetainsAllAttemptsWithoutSpeechOrDuplicateIDs() {
        let model = VoiceTranscriptModel()
        model.liveUserSpeech("speech", startsSegment: true)
        model.liveAssistantSpeech("answer")
        model.recordAppend(append(1))
        model.finishExchange()
        model.loadHistory([], reachedStart: true)
        model.recordAppend(append(1, call: "second-call"))
        let full = model.display(.full).messages
        XCTAssertEqual(full.count, 2)
        XCTAssertTrue(full.allSatisfy { $0.voiceAppend != nil }, "the speech went with the local turn")
        XCTAssertEqual(Set(full.compactMap(\.messageId)).count, 2)
        XCTAssertNil(model.live)
    }
}
