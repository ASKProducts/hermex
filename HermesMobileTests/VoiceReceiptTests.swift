import XCTest
@testable import HermesMobile

@MainActor final class VoiceReceiptTests: XCTestCase {
    func testCompleteReceiptAuthorizesSettlementWithoutATimer() throws {
        let transcript = VoiceTranscriptModel()
        var finished: [String] = []
        transcript.onTurnFinished = { finished.append($0) }
        transcript.userSent("Hello")
        let runID = try XCTUnwrap(transcript.activeRunID)
        transcript.gatewayEvent("message.delta", .object(["text": .string("Hi")]))
        transcript.gatewayEvent("message.complete", .object([
            "text": .string("Hi"), "status": .string("complete"),
            "persisted_turn": .object(["complete": .bool(true), "row_ids": .array([.number(11), .number(12)]),
                "user_row_id": .number(11), "final_assistant_row_id": .number(12)])
        ]))
        XCTAssertEqual(finished, [runID])
        let receipt = try XCTUnwrap(transcript.completedReceipt)
        XCTAssertEqual(receipt.rowIDs, [11, 12])
        var user = ChatMessage(role: "user", content: "Hello", timestamp: 1, messageId: "user-11")
        user.serverID = 11
        var reply = ChatMessage(role: "assistant", content: "Hi", timestamp: 2, messageId: "reply-12")
        reply.serverID = 12
        XCTAssertTrue(transcript.applySaved([user, reply], hasOlder: false, runID: runID, receipt: receipt))
        XCTAssertNil(transcript.fold)
        XCTAssertEqual(transcript.messages.compactMap(\.serverID), [11, 12])
    }

    func testMissingOrIncompleteReceiptKeepsTheLocalTurnWithoutAHistoryRetry() {
        let receipts: [BotJSON] = [.null, .object(["complete": .bool(false), "row_ids": .array([.number(11)])])]
        for receipt in receipts {
            let transcript = VoiceTranscriptModel()
            var finished = false
            transcript.onTurnFinished = { _ in finished = true }
            transcript.userSent("Hello")
            transcript.gatewayEvent("message.delta", .object(["text": .string("Hi")]))
            transcript.gatewayEvent("message.complete", .object([
                "text": .string("Hi"), "status": .string("complete"), "persisted_turn": receipt
            ]))
            XCTAssertFalse(finished)
            XCTAssertNil(transcript.fold)
            XCTAssertTrue(transcript.messages.contains { $0.content == "Hi" })
        }
    }
}
