import XCTest
@testable import HermesMobile

@MainActor final class VoiceAppendCaptureTests: XCTestCase {
    func testObservesExactBytesForAllKindsAndEveryCommentaryChunkSynchronously() throws {
        var sent: [String] = []
        var observed: [VoiceAppendObservation] = []
        var callbackSendCounts: [Int] = []
        let events = VoiceLiveEvents { sent.append($0); return true }
        events.onAppend = { observed.append($0); callbackSendCounts.append(sent.count) }
        events.think("del_🌍", "  quoted \"text\"  \\ path\nnext  ")
        let sentence = String(repeating: "word ", count: 59) + "end."
        let long = Array(repeating: sentence, count: 10).joined(separator: "\n")
        events.speak("del_🌍", long)
        events.instruct("  Literal\n\"🌍\" \\ slash  ")
        XCTAssertEqual(observed.count, 5)
        XCTAssertEqual(observed.map(\.kind), [.thinking, .commentary, .commentary, .commentary, .instructions])
        XCTAssertEqual(observed.map(\.ordinal), [1, 2, 3, 4, 5])
        XCTAssertEqual(callbackSendCounts, [1, 2, 3, 4, 5])
        XCTAssertEqual(observed.map { Array($0.rawJSON.utf8) }, sent.map { Array($0.utf8) })
        for observation in observed {
            let json = try JSONDecoder().decode(BotJSON.self, from: Data(observation.rawJSON.utf8))
            XCTAssertEqual(observation.content, json["content"].text)
            XCTAssertEqual(observation.eventID, .value(json["event_id"].text!))
            XCTAssertTrue(observation.locallySent)
        }
        XCTAssertEqual(observed.last?.delegationID, .null)
        XCTAssertEqual(observed.first?.delegationID, .value("del_🌍"))
        XCTAssertEqual(observed.last?.content, "Literal\n\"🌍\" \\ slash")
    }

    func testFailedAttemptsRemainDistinctAndControlEventsAreExcluded() {
        var observed: [VoiceAppendObservation] = []
        let events = VoiceLiveEvents { _ in false }
        events.onAppend = { observed.append($0) }
        events.think(nil, " "); events.speak(nil, "\n "); events.instruct(" ")
        events.mute(true); events.mute(false)
        XCTAssertFalse(events.requestClose())
        XCTAssertTrue(observed.isEmpty)
        events.think(nil, "progress")
        events.speak(nil, "result")
        events.instruct("instruction")
        XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(observed.map(\.ordinal), [1, 2, 3])
        XCTAssertTrue(observed.allSatisfy { !$0.locallySent })
        XCTAssertEqual(Set(observed.map(\.id)).count, 3)
    }

    func testMixedLocalResultsPreserveEveryAttemptInSendOrder() {
        var attempts = 0
        var sent: [String] = []
        var observed: [VoiceAppendObservation] = []
        let events = VoiceLiveEvents {
            attempts += 1
            sent.append($0)
            return attempts != 2
        }
        events.onAppend = { observed.append($0) }
        events.think(nil, "first")
        events.speak(nil, "second")
        events.instruct("third")
        XCTAssertEqual(observed.map(\.ordinal), [1, 2, 3])
        XCTAssertEqual(observed.map(\.locallySent), [true, false, true])
        XCTAssertEqual(observed.map { Array($0.rawJSON.utf8) }, sent.map { Array($0.utf8) })
    }

    func testNewEventsCoreCannotCollideWhenEventIDsRestart() {
        var observed: [VoiceAppendObservation] = []
        let first = VoiceLiveEvents { _ in true }
        let second = VoiceLiveEvents { _ in true }
        first.onAppend = { observed.append($0) }
        second.onAppend = { observed.append($0) }
        first.speak(nil, "first")
        second.speak(nil, "second")
        XCTAssertEqual(observed.count, 2)
        guard observed.count == 2 else { return }
        XCTAssertEqual(observed[0].eventID, observed[1].eventID)
        XCTAssertEqual(observed[0].ordinal, observed[1].ordinal)
        XCTAssertNotEqual(observed[0].id, observed[1].id)
    }

    func testOutgoingContentNeverEntersSpeechContext() {
        let events = VoiceLiveEvents { _ in true }
        events.handle(#"{"type":"session.input_transcript.delta","delta":"user words","start_ms":0,"end_ms":1}"#)
        let speech = events.transcript
        events.think(nil, "private progress")
        events.speak(nil, "private result")
        events.instruct("private instructions")
        XCTAssertEqual(events.transcript, speech)
        XCTAssertEqual(events.contextWindow(.sinceLastRequest), speech)
        XCTAssertEqual(VoiceLive.delegationPrompt(events.takeContext()).context, "User: user words")
    }
}
