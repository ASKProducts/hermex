import Foundation

/// One ordered declaration/result relation. A supplied Hermes UID addresses
/// its occurrences; legacy rows without it use the provider ID. Each result
/// consumes exactly one preceding declaration in that address's queue.
struct TurnToolResults {
    private enum Address: Hashable { case uid(String), provider(String) }
    var rowsByToolUID: [String: ChatMessage] = [:]
    var matchedResultIndices: Set<Int> = []

    init(messages: [ChatMessage], firstIndex: Int = 0, kept: [Bool]? = nil) {
        let kept = kept ?? ChatTurn.rowRules(for: messages).map(\.isKept)
        var declarations: [Address: [String]] = [:]
        var consumed: [Address: Int] = [:]
        for (index, row) in messages.enumerated() where kept[index] && row.isHermesRow {
            let identity = TurnRowIdentity.of(row, absoluteIndex: firstIndex + index)
            if row.role == "assistant" {
                var providerOccurrences: [String: Int] = [:]
                for (callIndex, call) in row.savedToolCalls.enumerated() {
                    let ordinal = providerOccurrences[call.id, default: 0]
                    providerOccurrences[call.id] = ordinal + 1
                    let supplied = row.toolCallUIDs[call.id].flatMap { $0.indices.contains(ordinal) ? $0[ordinal] : nil }
                    let address: Address = supplied.flatMap { $0.isEmpty ? nil : .uid($0) } ?? .provider(call.id)
                    declarations[address, default: []].append(identity.toolUID(at: callIndex))
                }
            } else if row.role == "tool" {
                let address: Address = row.toolCallUID.map(Address.uid) ?? .provider(row.toolCallId ?? "")
                let ordinal = consumed[address, default: 0]
                guard let calls = declarations[address], calls.indices.contains(ordinal) else { continue }
                consumed[address] = ordinal + 1
                rowsByToolUID[calls[ordinal]] = row
                matchedResultIndices.insert(index)
            }
        }
    }

    /// Parse one saved occurrence, not the legacy provider-ID-collapsed group.
    /// The wire ID stays the provider's; the presentation address is its UID.
    static func presentation(tool: ChatTurnTool, callIndex: Int, row: ChatMessage, result: ChatMessage?) -> ToolCall {
        var object: [String: JSONValue] = [:]
        if let calls = row.toolCalls, calls.indices.contains(callIndex), case .object(let value) = calls[callIndex] {
            object = value
        }
        var function: [String: JSONValue] = [:]
        if case .object(let value) = object["function"] { function = value }
        let argumentValue = function["arguments"] ?? object["arguments"] ?? object["args"] ?? object["input"]
        var arguments: [String: JSONValue]?
        switch argumentValue {
        case .object(let value): arguments = value
        case .string(let value): arguments = try? JSONDecoder().decode([String: JSONValue].self, from: Data(value.utf8))
        default: break
        }
        let snippet = nonEmpty(string(object["snippet"])) ?? nonEmpty(string(object["preview"]))
        return ToolCall(id: tool.providerID, presentationID: tool.id, name: nonEmpty(tool.name) ?? "tool",
                        preview: nonEmpty(result?.content) ?? snippet, args: arguments, isCompleted: true)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let value) = value { return value }
        return nil
    }
}
