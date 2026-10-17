import XCTest
@testable import HermesMobile

final class VoiceAppendJournalTests: XCTestCase {
    private func observation(_ ordinal: Int, call: String = "call-a", sent: Bool = true) -> VoiceAppendObservation {
        VoiceAppendObservation(callID: call, ordinal: ordinal, kind: .commentary,
                               eventID: .value("say_1"), delegationID: .null,
                               content: "Quoted \"🌍\"\nnext", rawJSON: "{\"content\":\"🌍\\nnext\"}", locallySent: sent)
    }

    func testActivityOffRetainsAttemptsAndOnRestoresExactPayloads() {
        var journal = VoiceAppendJournal()
        let first = observation(1)
        journal.append(first, afterExchange: "run:a")
        XCTAssertTrue(journal.project(turnKeys: ["run:a"], showsAppends: false).isEmpty)
        let failed = observation(2, sent: false)
        journal.append(failed, afterExchange: "run:a")
        XCTAssertTrue(journal.project(turnKeys: ["run:a"], showsAppends: false).isEmpty)
        let shown = journal.project(turnKeys: ["run:a"], showsAppends: true)
        XCTAssertEqual(shown.map(\.observation), [first, failed])
        guard shown.count == 2 else { return }
        XCTAssertEqual(Array(shown[0].observation.rawJSON.utf8), Array(first.rawJSON.utf8))
        XCTAssertFalse(shown[1].observation.locallySent)
    }

    func testLostAndBackwardAnchorsCannotReverseAttemptOrder() {
        var journal = VoiceAppendJournal()
        for (ordinal, key) in [(1, "lost"), (2, "b"), (3, "lost"), (4, "a"), (5, "c")] {
            journal.append(observation(ordinal), afterExchange: key)
        }
        let shown = journal.project(turnKeys: ["a", "b", "c"], showsAppends: true)
        XCTAssertEqual(shown.map(\.afterTurnKey), [nil, "b", "b", "b", "c"])
        XCTAssertEqual(shown.map { $0.observation.ordinal }, [1, 2, 3, 4, 5])
    }

    func testSettlementAliasesAndCurrentWindowUseCapturedExchangeNotDelegation() {
        var journal = VoiceAppendJournal()
        journal.append(observation(1), afterExchange: "run:old")
        journal.append(observation(2), afterExchange: "run:new")
        let shown = journal.project(turnKeys: ["saved:old", "run:new"], showsAppends: true,
                                    aliases: ["run:old": "saved:old"], currentExchange: .only("run:new"))
        XCTAssertEqual(shown.map { $0.observation.ordinal }, [2])
        XCTAssertEqual(shown.map(\.afterTurnKey), ["run:new"])
        XCTAssertEqual(journal.project(turnKeys: ["prepended", "saved:old", "run:new"], showsAppends: true,
                                       aliases: ["run:old": "saved:old"]).map(\.afterTurnKey), ["saved:old", "run:new"])
    }

    func testCurrentWindowNeverReturnsAnOmittedPreviousAnchor() {
        var journal = VoiceAppendJournal()
        journal.append(observation(1), afterExchange: "previous")
        journal.append(observation(2), afterExchange: "removed")
        journal.append(observation(3), afterExchange: "current")
        let shown = journal.project(turnKeys: ["previous", "current"], visibleTurnKeys: ["current"],
                                    showsAppends: true, currentExchange: .only("current"))
        XCTAssertEqual(shown.map { $0.observation.ordinal }, [3])
        XCTAssertEqual(shown.map(\.afterTurnKey), ["current"])
        let missing = journal.project(turnKeys: ["previous", "current"], visibleTurnKeys: ["current"],
                                      showsAppends: true, currentExchange: .only("removed"))
        XCTAssertEqual(missing.map { $0.observation.ordinal }, [2])
        XCTAssertEqual(missing.map(\.afterTurnKey), [nil])
    }

    func testNoTurnInstructionsAndNewCallIdentity() {
        var journal = VoiceAppendJournal()
        journal.append(observation(1), afterExchange: nil)
        journal.append(observation(1, call: "call-b"), afterExchange: nil)
        let shown = journal.project(turnKeys: [], showsAppends: true, currentExchange: .only(nil))
        XCTAssertEqual(shown.count, 2)
        guard shown.count == 2 else { return }
        XCTAssertNil(shown[0].afterTurnKey)
        XCTAssertNotEqual(shown[0].observation.id, shown[1].observation.id)
        XCTAssertEqual(Set(shown.map { $0.observation.id }).count, shown.count)
        XCTAssertEqual(shown[0].observation.delegationID, .null)
        XCTAssertNotEqual(VoiceAppendObservation.Identifier.absent, .null)
    }
}
