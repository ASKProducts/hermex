import XCTest
@testable import HermesMobile

final class ChatViewModelMergeDedupTests: XCTestCase {

    // #330 regression: a server-transcribed voice note sends the bare transcript
    // (no "[Attached files:]" marker). The server frequently returns the clip
    // attachment on reload as a bare filename (no path), while the optimistic
    // bubble holds the full upload path. Dedup must still match them so the
    // optimistic message isn't re-inserted as a duplicate user turn.
    func testVoiceNoteDedupesWhenServerReturnsBareFilenameAttachment() {
        let transcript = "The last chatted about this portable monstrosity"
        let optimistic = ChatMessage(
            role: "user",
            content: transcript,
            timestamp: 1000,
            messageId: "local-ABC123",
            attachments: [
                MessageAttachment(
                    name: "voice-note-7765a1e2.m4a",
                    path: "/Users/hermes/.hermes/webui/attachments/db9/voice-note-7765a1e2.m4a",
                    mime: "audio/mp4a-latm",
                    size: 116155,
                    isImage: false
                )
            ]
        )
        let reloaded = ChatMessage(
            role: "user",
            content: transcript,
            timestamp: 1000,
            messageId: "server-1",
            attachments: [MessageAttachment(name: "voice-note-7765a1e2.m4a", path: nil)]
        )

        let merged = ChatViewModel.mergingLoadedMessages(
            [reloaded],
            withLocalOptimisticMessages: [optimistic]
        )

        XCTAssertEqual(
            merged.filter { $0.role == "user" }.count, 1,
            "Optimistic voice note must dedupe against a bare-filename reload"
        )
    }

    // Guard: genuinely different attachment filenames must NOT be deduped away.
    func testDifferentAttachmentFilenamesAreNotDeduped() {
        let optimistic = ChatMessage(
            role: "user", content: "same text", timestamp: 3000, messageId: "local-1",
            attachments: [MessageAttachment(name: "alpha.m4a", path: "/tmp/alpha.m4a")]
        )
        let reloaded = ChatMessage(
            role: "user", content: "same text", timestamp: 3000, messageId: "server-3",
            attachments: [MessageAttachment(name: "beta.m4a", path: nil)]
        )
        let merged = ChatViewModel.mergingLoadedMessages([reloaded], withLocalOptimisticMessages: [optimistic])
        XCTAssertEqual(merged.filter { $0.role == "user" }.count, 2,
                       "Different attachment filenames are distinct messages")
    }

    func testMatchingNewServerIDStillRequiresNearbyTimestamp() {
        let optimistic = ChatMessage(
            role: "user", content: "Repeat", timestamp: 2000, messageId: "local-repeat"
        )
        let olderReloaded = ChatMessage(
            role: "user", content: "Repeat", timestamp: 1000, messageId: "newly-loaded-old-user"
        )

        let merged = ChatViewModel.mergingLoadedMessages(
            [olderReloaded],
            withLocalOptimisticMessages: [optimistic],
            knownMessageIDsBeforeLoad: []
        )

        XCTAssertEqual(merged.filter { $0.role == "user" }.count, 2)
    }

    // The server stores image sends as content parts whose text starts with
    // `[Workspace::v1: <escaped path>]`. Decoding a user row drops that tag,
    // including a path with escaped `]` and `\`.
    func testDecodingUserRowDropsLeadingWorkspaceTag() throws {
        let message = try decodeMessage(#"""
        {
          "role": "user",
          "content": [
            {"type": "text", "text": "[Workspace::v1: /tmp/a\\\\b [x\\]]\nDescribe this image"},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAAA"}}
          ]
        }
        """#)

        XCTAssertEqual(message.content, "Describe this image")
    }

    func testTaggedIndentedUserTextMatchesOptimisticRowWithoutChangingNormalization() throws {
        let text = "    first line\n        second line  \n"
        let payload: [String: Any] = [
            "role": "user", "message_id": "server-indented", "timestamp": 2001,
            "content": "[Workspace::v1: /tmp/images]\n" + text
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let loaded = try decodeMessage(String(decoding: data, as: UTF8.self))
        // Workspace display-prefix normalization trims outside whitespace;
        // indentation inside the user's text is not normalized away.
        XCTAssertEqual(loaded.content, "first line\n        second line")
        let optimistic = ChatMessage(
            role: "user", content: text, timestamp: 2000, messageId: "local-indented"
        )
        let merged = ChatViewModel.mergingLoadedMessages(
            [loaded], withLocalOptimisticMessages: [optimistic], knownMessageIDsBeforeLoad: []
        )
        XCTAssertEqual(merged.map(\.messageId), ["server-indented"])
        let untagged = try decodeMessage(String(decoding: JSONSerialization.data(withJSONObject: [
            "role": "user", "content": text
        ]), as: UTF8.self))
        XCTAssertEqual(untagged.content, text, "Untagged display text keeps its original whitespace")
    }

    // Only a tag at the very start is the server's; text that mentions it
    // elsewhere is the user's, and other roles are never rewritten.
    func testDecodingLeavesWorkspaceTagMentionsAndOtherRolesUntouched() throws {
        let mention = try decodeMessage(#"""
        {"role": "user", "content": "Why does [Workspace::v1: /tmp/a] show up?"}
        """#)
        XCTAssertEqual(mention.content, "Why does [Workspace::v1: /tmp/a] show up?")

        let assistant = try decodeMessage(#"""
        {"role": "assistant", "content": "[Workspace::v1: /tmp/a]\nhello"}
        """#)
        XCTAssertEqual(assistant.content, "[Workspace::v1: /tmp/a]\nhello")
    }

    private func decodeMessage(_ json: String) throws -> ChatMessage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }
}
