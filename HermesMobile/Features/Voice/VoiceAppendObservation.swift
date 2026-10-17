import Foundation

/// An observation of one local append attempt, not received speech or remote acceptance.
/// `rawJSON` is the original string handed to the transport, never reconstructed for display.
struct VoiceAppendObservation: Equatable, Identifiable {
    enum Kind: String {
        case thinking = "session.thinking.append"
        case commentary = "session.commentary.append"
        case instructions = "session.instructions.append"
    }

    enum Identifier: Equatable {
        case absent
        case null
        case value(String)
    }

    let callID: String
    let ordinal: Int
    let kind: Kind
    let eventID: Identifier
    let delegationID: Identifier
    let content: String
    let rawJSON: String
    /// The transport's synchronous return value; says nothing about remote acceptance.
    let locallySent: Bool

    var id: String { "voice-append:\(callID):\(ordinal)" }
}

/// What the shared transcript log row shows for an append. English only (Hermex has one user);
/// the label says what the app did (sent / not sent), never that the voice model received it.
struct VoiceAppendLogRowContent: Equatable {
    let observation: VoiceAppendObservation

    var summary: String {
        switch observation.kind {
        case .thinking: "Thinking append"
        case .commentary: "Commentary append"
        case .instructions: "Instructions append"
        }
    }

    /// The content on one line; a failed send leads with "not sent".
    var detail: String {
        let line = observation.content.split(whereSeparator: \.isNewline).joined(separator: " ")
        return observation.locallySent ? line : "not sent · " + line
    }

    var isFailure: Bool { !observation.locallySent }

    var accessibilityLabel: String { summary + ", " + detail }

    /// What opening the row shows and Copy copies: the string handed to the transport,
    var copyText: String { PrettyJSON.text(observation.rawJSON) }
}

/// Indented, one-key-per-line JSON for event rows whose body is a JSON document.
enum PrettyJSON {
    /// `text` pretty-printed (sorted keys, two-space indent) when it parses as a JSON object
    /// or array; anything else (plain text, invalid JSON, a bare scalar) is returned unchanged.
    static func text(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] || value is [Any],
              let pretty = try? JSONSerialization.data(withJSONObject: value,
                                                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8)
        else { return text }
        return string
    }
}
