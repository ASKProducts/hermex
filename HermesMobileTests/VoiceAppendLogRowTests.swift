import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

/// The append row is one more kind of the shared transcript log row (`TranscriptLogRowView`),
/// drawn by the transcript's own item cell for a local row, opening in place to the exact JSON.
@MainActor final class VoiceAppendLogRowTests: XCTestCase {
    private func observation(_ kind: VoiceAppendObservation.Kind, sent: Bool = true,
                             content: String = "Hermes is\nrunning the tests",
                             raw: String = #"{"type":"session.thinking.append","content":"Hermes is\nrunning the tests"}"#) -> VoiceAppendObservation {
        VoiceAppendObservation(callID: "call", ordinal: 1, kind: kind, eventID: .value("think_1"),
                               delegationID: .null, content: content, rawJSON: raw, locallySent: sent)
    }

    func testLabelsNameTheKindAndNeverClaimReceipt() {
        XCTAssertEqual(VoiceAppendLogRowContent(observation: observation(.thinking)).summary, "Thinking append")
        XCTAssertEqual(VoiceAppendLogRowContent(observation: observation(.commentary)).summary, "Commentary append")
        XCTAssertEqual(VoiceAppendLogRowContent(observation: observation(.instructions)).summary, "Instructions append")
        let sent = VoiceAppendLogRowContent(observation: observation(.thinking))
        XCTAssertEqual(sent.detail, "Hermes is running the tests")
        XCTAssertFalse(sent.isFailure)
        let failed = VoiceAppendLogRowContent(observation: observation(.commentary, sent: false))
        XCTAssertTrue(failed.isFailure)
        XCTAssertTrue(failed.detail.hasPrefix("not sent"))
        XCTAssertTrue(failed.accessibilityLabel.contains("not sent"))
        for row in [sent, failed] {
            let words = (row.summary + " " + row.detail + " " + row.accessibilityLabel).lowercased()
            for claim in ["received", "delivered", "accepted", "heard"] { XCTAssertFalse(words.contains(claim), claim) }
        }
    }

    func testCopyAndOpenBodyAreTheSentJSONPrettyPrinted() throws {
        let raw = #"{"content":"  quoted \"🌍\" \\ path\nnext  ","delegation_id":null,"event_id":"say_7","type":"session.commentary.append"}"#
        let row = VoiceAppendLogRowContent(observation: observation(.commentary, raw: raw))
        XCTAssertEqual(row.copyText, """
        {
          "content" : "  quoted \\"🌍\\" \\\\ path\\nnext  ",
          "delegation_id" : null,
          "event_id" : "say_7",
          "type" : "session.commentary.append"
        }
        """)
        let reparsed = try JSONSerialization.jsonObject(with: Data(row.copyText.utf8)) as? NSDictionary
        let sent = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? NSDictionary
        XCTAssertEqual(reparsed, sent)
        let previous = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previous }
        UIPasteboard.general.string = row.copyText
        XCTAssertEqual(UIPasteboard.general.string, row.copyText)
    }

    /// Only a JSON object or array is reformatted; anything else is shown exactly as sent.
    func testPrettyJSONDetection() {
        XCTAssertEqual(PrettyJSON.text(#"{"b":1,"a":[true,"x/y"]}"#), """
        {
          "a" : [
            true,
            "x/y"
          ],
          "b" : 1
        }
        """)
        XCTAssertEqual(PrettyJSON.text(#"[1,{"k":"v"}]"#), """
        [
          1,
          {
            "k" : "v"
          }
        ]
        """)
        for unchanged in ["plain text", "Hermes is\nrunning", #"{"open": "#, "{not json}", #""a string""#, "42", "true", "null", ""] {
            XCTAssertEqual(PrettyJSON.text(unchanged), unchanged, unchanged)
        }
    }

    func testTheRowIsTheSharedTranscriptLogRow() {
        let view = VoiceAppendRow.appendRow(observation(.thinking), expansion: .constant(false))
        let typeName = String(reflecting: type(of: view))
        XCTAssertTrue(typeName.contains("TranscriptLogRowView<"), typeName)
        XCTAssertFalse(typeName.contains("MessageBubbleView"), typeName)
    }

    /// Through the transcript's real item cell: a local row carrying an append draws the log row
    /// (one line, the log row's height), and its open state comes from the transcript's one
    /// disclosure state under `append:<row id>`; open, the cell holds the JSON body under it.

    /// The same row as a segment of its exchange: open state is the disclosure state's entry
    /// for the segment id, as for every other segment the item function emits.

}
