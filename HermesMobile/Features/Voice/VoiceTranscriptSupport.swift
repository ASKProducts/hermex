import Foundation

struct TranscriptLocalRow: Equatable {
    let id: String
    /// Drawn right after the turn with this key (the turn that was last when
    /// the row was added, by its item key, which survives settle);
    /// `beforeFirstTurn` draws it above every turn; `nil` or a key no turn has
    /// draws it at the end.
    let afterTurnKey: String?
    /// What the row draws (`local_assistant` / `local_notice`, through
    /// `MessageBubbleView`). Part of equality, so a `/btw` answer growing
    /// re-hosts its cell.
    var message: ChatMessage? = nil
    /// A GPT-Live append the app sent (voice transcript): drawn as a log row, never as speech.
    /// Part of equality.
    var rawAppend: VoiceAppendObservation? = nil

    /// Anchor of a row added while the chat had no turn yet.
    static let beforeFirstTurn = "^"
}

enum TranscriptItems {
static func turnKey(_ turn: ChatTurn) -> String {
        if let key = turn.itemKey { return key }
        if let uid = turn.promptUID { return uid.hasPrefix("pos:") ? uid : "msg:\(uid)" }
        if let id = turn.userMessageID { return "msg:\(id)" }
        if let row = turn.userRowIndex { return "pos:\(row)" }
        switch turn.state {
        case .live(let runID), .interrupted(let runID): return "run:\(runID)"
        case .settled: return "rows:\(turn.rows?.lowerBound ?? -1)"
        }
    }
}

struct TranscriptSegmentFilter: Equatable {
    var appends = true
    var thinkingAndTools = true

    static let all = TranscriptSegmentFilter()

    init(appends: Bool = true, thinkingAndTools: Bool = true) {
        self.appends = appends
        self.thinkingAndTools = thinkingAndTools
    }

    init(cards: Bool) {
        self.init(appends: cards, thinkingAndTools: cards)
    }

    func shows(_ segment: ChatTurnSegment) -> Bool {
        switch segment.kind {
        case .text, .steer, .delegationCompletion: return true
        case .thinking, .tool: return thinkingAndTools
        case .append: return appends
        }
    }
}
