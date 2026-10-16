import Foundation

/// One chat turn: a user message and everything the agent did in reply.
///
/// A turn is built one of two ways and never by comparing text:
/// - live, by `ChatTurnLiveFold` from SSE events (ordered segments, keyed by
///   run seq and tool id);
/// - settled, by `ChatTurn.saved(from:run:)` / `ChatTurn.turns(from:)` from
///   saved messages (steps keyed by the server's integer message `id`, or by
///   absolute row position for rows saved without one).
/// `ChatTurnSettle` maps the first onto the second at turn end.
struct ChatTurn: Equatable {
    enum State: Equatable {
        /// Streaming, or saved mid-run (`ChatTurnSavedRun.inProgress`).
        case live(runID: String)
        /// Built from the saved rows of a finished run.
        case settled
        /// The run ended with cancel / error and no `done`: the saved turn is
        /// flattened (`_partial` + `_error`, no ids) and replaces this on reload.
        case interrupted(runID: String)
    }

    /// Saved integer `id` of the user row that opened the turn. Nil while live
    /// and for turns whose user row has no id.
    var userMessageID: Int?
    var state: State
    /// Saved turns only: one step per saved row (assistant model call or steer).
    var steps: [ChatTurnStep]
    /// Live turns: the ordered segments. Saved turns: `steps` flattened.
    var segments: [ChatTurnSegment]
    /// Saved turns: absolute index of the user row in the session, if any.
    var userRowIndex: Int? = nil
    /// Saved turns: the absolute session rows this turn spans.
    var rows: Range<Int>? = nil
    /// The item key this turn was drawn under before a settle re-keyed it
    /// (plan §4.3, commit E): its items keep that key. Nil = derived.
    var itemKey: String? = nil
    var promptUID: String? = nil
}

/// One saved row of a saved turn: an assistant model call (thinking, text,
/// tool calls) or a mid-turn steer.
struct ChatTurnStep: Equatable {
    /// The row's integer server `id`; nil for rows saved outside settlement.
    let messageID: Int?
    /// Absolute index of the row in the session.
    var rowIndex: Int? = nil
    var segments: [ChatTurnSegment]
    var uid: String? = nil
}

struct ChatTurnSegmentID: Hashable, CustomStringConvertible {
    let rawValue: String

    var description: String { rawValue }

    /// Live thinking/text: the segment's ordinal within its run.
    static func live(runID: String, ordinal: Int) -> ChatTurnSegmentID {
        ChatTurnSegmentID(rawValue: "live:\(runID):\(ordinal)")
    }

    /// Tools, live and settled alike.
    static func tool(_ toolID: String) -> ChatTurnSegmentID {
        ChatTurnSegmentID(rawValue: "tool:\(toolID)")
    }

    /// Settled rows: `part` is `thinking`, `text` or `steer`.
    static func message(_ uid: String, _ part: String) -> ChatTurnSegmentID {
        ChatTurnSegmentID(rawValue: "msg:\(uid):\(part)")
    }

    /// Saved rows without an id: keyed by absolute row index in the session.
    static func position(_ rowIndex: Int, _ part: String) -> ChatTurnSegmentID {
        ChatTurnSegmentID(rawValue: "pos:\(rowIndex):\(part)")
    }
}

/// Append-only text of one live segment. Only the fold appends; readers hold
/// `ChatTurnText` windows onto it, never the `String` itself, so appending
/// never copies what is already published (the buffer stays uniquely owned).
final class ChatTurnTextBuffer {
    private(set) var storage = ""

    func append(_ delta: String) { storage.append(delta) }

    var utf8Count: Int { storage.utf8.count }

    /// A fresh copy of the first `utf8Count` bytes: never shares `storage`.
    func prefix(utf8Count: Int) -> String {
        String(decoding: storage.utf8.prefix(utf8Count), as: UTF8.self)
    }

    func copy() -> ChatTurnTextBuffer {
        let clone = ChatTurnTextBuffer()
        clone.storage = String(decoding: storage.utf8, as: UTF8.self)
        return clone
    }
}

/// Thinking/text of a segment: a saved string, or a live window (the first
/// `utf8Count` bytes of a fold's buffer, fixed when published). Equal when the
/// text is equal. Building a window is O(1); reading `string` copies, so read
/// it when drawing, not per event.
struct ChatTurnText: Equatable, ExpressibleByStringLiteral, CustomStringConvertible {
    private enum Storage {
        case owned(String)
        case window(ChatTurnTextBuffer, utf8Count: Int)
    }

    private let storage: Storage

    init(_ string: String) { storage = .owned(string) }
    init(stringLiteral value: String) { storage = .owned(value) }
    init(buffer: ChatTurnTextBuffer, utf8Count: Int? = nil) { storage = .window(buffer, utf8Count: utf8Count ?? buffer.utf8Count) }

    var string: String {
        switch storage {
        case .owned(let string): return string
        case .window(let buffer, let count): return buffer.prefix(utf8Count: count)
        }
    }

    var utf8Count: Int {
        switch storage {
        case .owned(let string): return string.utf8.count
        case .window(_, let count): return count
        }
    }

    var isEmpty: Bool { utf8Count == 0 }
    var description: String { string }

    static func == (lhs: ChatTurnText, rhs: ChatTurnText) -> Bool {
        if case let .window(a, countA) = lhs.storage, case let .window(b, countB) = rhs.storage, a === b {
            return countA == countB
        }
        guard lhs.utf8Count == rhs.utf8Count else { return false }
        return lhs.string == rhs.string
    }
}

struct ChatTurnSegment: Equatable, Identifiable {
    enum Kind: Equatable {
        case thinking(ChatTurnText)
        case text(ChatTurnText)
        case tool(ChatTurnTool)
        case steer(String)
        /// saved asynchronous delegation reports are standalone rendered cards.
        case delegationCompletion(HermesDelegationCompletion)
        /// position among the turn's segments. Never saved; never built from rows.
        case append(VoiceAppendObservation)
    }

    let id: ChatTurnSegmentID
    var kind: Kind

    var isTool: Bool {
        if case .tool = kind { return true }
        return false
    }
}

struct ChatTurnTool: Equatable {
    enum State: Equatable {
        case running
        case done
        case failed
    }

    /// Server tool id (`tid` == saved `tool_calls[].id` == `tool_call_id`), or
    /// `name#seq` for legacy tool events that carry no id.
    let id: String
    let name: String
    var state: State
    /// Call evidence from the live events or the matched durable declaration
    /// and receipt. Keeping it on the occurrence lets a running-history rebuild
    /// seed the same row without depending on the settled presentation cache.
    var preview: String? = nil
    var args: [String: JSONValue]? = nil
    var duration: Double? = nil
    let providerID: String
    let occurrence: Int

    init(id: String, name: String, state: State, preview: String? = nil,
         args: [String: JSONValue]? = nil, duration: Double? = nil,
         providerID: String? = nil, occurrence: Int = 1) {
        self.id = id
        self.name = name
        self.state = state
        self.preview = preview
        self.args = args
        self.duration = duration
        self.providerID = providerID ?? id
        self.occurrence = occurrence
    }

    /// A running-history rebuild replaces identity with the durable occurrence,
    /// not evidence already received for that occurrence. Persisted fields win
    /// when present; an unanswered declaration cannot undo a live completion.
    func retainingDetails(from earlier: ChatTurnTool) -> ChatTurnTool {
        guard providerID == earlier.providerID, occurrence == earlier.occurrence else { return self }
        var tool = self
        tool.args = args ?? earlier.args
        tool.preview = preview ?? earlier.preview
        tool.duration = duration ?? earlier.duration
        if state == .running { tool.state = earlier.state }
        return tool
    }

    /// The model owns the call's state and live evidence. Saved presentation
    /// fields supply only evidence absent from the model, for the same call.
    func presentation(saved: ToolCall?) -> ToolCall {
        let saved = saved.flatMap { $0.id == providerID ? $0 : nil }
        return ToolCall(
            id: providerID,
            presentationID: id,
            name: name.isEmpty ? saved?.name : name,
            preview: preview ?? saved?.preview,
            args: args ?? saved?.args,
            duration: duration ?? saved?.duration,
            isError: state == .failed ? true : saved?.isError,
            isCompleted: state != .running
        )
    }
}
