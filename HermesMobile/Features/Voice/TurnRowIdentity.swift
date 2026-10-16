import Foundation

/// A durable row address translated at the backend boundary. Physical row IDs
/// are retained for receipts and actions, never substituted for a supplied UID.
struct TurnRowIdentity: Equatable {
    let uid: String
    let absorbed: [String]
    let rowID: Int?
    /// Persisted call UIDs in declaration order. A single response can share one UID.
    let toolCallUIDs: [String]
    let toolCallUID: String?

    static func hermes(_ message: ChatMessage, absoluteIndex: Int) -> TurnRowIdentity {
        let uid = message.messageUID ?? message.rowID.map { "r\($0)" } ?? message.serverID.map { "r\($0)" } ?? "pos:\(absoluteIndex)"
        var occurrences: [String: Int] = [:]
        let calls = message.savedToolCalls.enumerated().map { index, call in
            let ordinal = occurrences[call.id, default: 0]
            occurrences[call.id] = ordinal + 1
            guard let values = message.toolCallUIDs[call.id], ordinal < values.count,
                  !values[ordinal].isEmpty else { return "\(uid)#\(index)" }
            return values[ordinal]
        }
        return TurnRowIdentity(uid: uid, absorbed: message.absorbedMessageUIDs,
                               rowID: message.rowID ?? message.serverID,
                               toolCallUIDs: calls, toolCallUID: message.toolCallUID)
    }

    static func unsaved(_ message: ChatMessage, absoluteIndex: Int, positional: Bool) -> TurnRowIdentity {
        TurnRowIdentity(uid: (!positional ? message.serverID : nil).map(String.init) ?? "pos:\(absoluteIndex)",
                        absorbed: [], rowID: message.serverID,
                        toolCallUIDs: message.savedToolCalls.map(\.id), toolCallUID: message.toolCallId ?? message.toolUseId)
    }

    static func of(_ message: ChatMessage, absoluteIndex: Int, positional: Bool = false) -> TurnRowIdentity {
        message.isHermesRow ? hermes(message, absoluteIndex: absoluteIndex)
            : unsaved(message, absoluteIndex: absoluteIndex, positional: positional)
    }

    func resolves(_ candidate: String) -> Bool { uid == candidate || absorbed.contains(candidate) }

    func segment(_ part: String) -> ChatTurnSegmentID {
        if uid.hasPrefix("pos:") { return .init(rawValue: "\(uid):\(part)") }
        return .message(uid, part)
    }

    func toolOccurrence(at index: Int) -> Int {
        toolCallUIDs.prefix(index + 1).filter { $0 == toolCallUIDs[index] }.count
    }

    /// Tells apart declarations sharing one persisted UID;
    /// this is occurrence identity, not a missing-metadata fallback.
    func toolUID(at index: Int) -> String {
        let occurrence = toolOccurrence(at: index)
        return toolCallUIDs[index] + (occurrence > 1 ? "#\(occurrence)" : "")
    }
}

extension ChatMessage {
    // `rowID` is the existing Hermes projection marker; a metadata column
    // alone must not switch the unsaved-row adapter or its byte-identical IDs.
    var isHermesRow: Bool { rowID != nil }
}
