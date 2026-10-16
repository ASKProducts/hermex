import XCTest
@testable import HermesMobile

@MainActor final class VoiceAppendModelTests: XCTestCase {
    private func append(_ ordinal: Int, call: String = "call") -> VoiceAppendObservation {
        VoiceAppendObservation(callID: call, ordinal: ordinal, kind: .instructions, eventID: .value("instr_1"),
                               delegationID: .null, content: "outgoing only", rawJSON: "{\"content\":\"outgoing only\"}", locallySent: true)
    }

    func testNoTurnAppendRemainsOutsideHistoryAndActivityToggleOnlyChangesVisibility() {
        let model = VoiceTranscriptModel()
        model.recordAppend(append(1))
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.fold)
        XCTAssertNil(model.liveUserMessage)
        XCTAssertTrue(model.appendEvents(.current, showsAppends: false).isEmpty)
        model.recordAppend(append(2))
        XCTAssertEqual(model.appendEvents(.current, showsAppends: true).map { $0.observation.ordinal }, [1, 2])
        XCTAssertEqual(model.appendEvents(.full, showsAppends: true).map { $0.observation.ordinal }, [1, 2])
        model.loadHistory([], hasOlder: false)
        XCTAssertEqual(model.appendEvents(.full, showsAppends: true).count, 2)
    }

    func testNewUtteranceCapturesCurrentExchangeEvenWhenEarlierDelegationStillFinishes() {
        let model = VoiceTranscriptModel()
        model.liveUserSpeech("old speech", startsSegment: true)
        model.delegationStarted(id: "old-delegation", prompt: "old request")
        model.recordAppend(append(1))
        let oldKey = TranscriptItems.turnKey(model.liveTurn!)
        model.liveUserSpeech("new speech", startsSegment: true)
        let currentKey = TranscriptItems.turnKey(model.liveTurn!)
        model.delegationFinished(id: "old-delegation")
        model.recordAppend(append(2))
        // Each append is a segment of the exchange on screen when it was sent, not a row between turns.
        XCTAssertTrue(model.appendEvents(.current, showsAppends: true).isEmpty)
        XCTAssertTrue(model.appendEvents(.full, showsAppends: true).isEmpty)
        func appendOrdinals(_ turn: ChatTurn?) -> [Int] {
            (turn?.segments ?? []).compactMap { if case .append(let a) = $0.kind { return a.ordinal }; return nil }
        }
        XCTAssertEqual(appendOrdinals(model.liveTurn), [2])
        XCTAssertEqual(TranscriptItems.turnKey(model.liveTurn!), currentKey)
        XCTAssertEqual(model.settledTurns.map(TranscriptItems.turnKey), [oldKey])
        XCTAssertEqual(model.settledTurns.map(appendOrdinals), [[1]])
        model.finishExchange()
        XCTAssertEqual(model.display(.current).turns.map(appendOrdinals), [[2]])
    }

    func testHistoryReplacementRetainsAllAttemptsWithoutSpeechOrDuplicateIDs() {
        let model = VoiceTranscriptModel()
        model.liveUserSpeech("speech", startsSegment: true)
        model.liveAssistantSpeech("answer")
        model.recordAppend(append(1))
        model.finishExchange()
        model.loadHistory([], hasOlder: false)
        model.recordAppend(append(1, call: "second-call"))
        let full = model.appendEvents(.full, showsAppends: true)
        XCTAssertEqual(full.count, 2)
        XCTAssertEqual(Set(full.map { $0.observation.id }).count, 2)
        XCTAssertTrue(full.allSatisfy { $0.afterTurnKey == nil })
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.fold)
    }
}
