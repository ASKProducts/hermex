import Foundation

/// Where saved rows come from, which decides what an unanswered tool call means.
enum ChatTurnSavedRun: Equatable {
    /// The run is over (`done`, or a reload after it): a tool call with no
    /// result row failed.
    case finished
    /// The run is still going (reattach / relaunch mid-run): a tool call with
    /// no result row is still running, and the turn is live.
    case inProgress(runID: String)
}

/// How `ChatTurn.turns(from:)` treats one saved row. A row is skipped only
/// when ids (or the server-copied timestamp) prove it copies another row.
enum ChatTurnRowRule: Equatable {
    enum Reason: Equatable, CaseIterable {
        /// Id-less or repeated-id assistant row whose every tool-call id is on an id'd row.
        case toolCallIDs
        /// Id-less or repeated-id tool row whose `tool_call_id` is on an id'd tool row.
        case toolResultID
        /// Repeated-id user row with the same id AND timestamp as an earlier kept one.
        case userIDAndTimestamp
        /// Id-less user row with the exact timestamp of the id'd user row opening its turn.
        case userTimestampCopy
        case messageUID
    }

    case kept
    /// Skipped: the same content is on `ofRow` (index in the same window).
    case duplicate(ofRow: Int, reason: Reason)

    var isKept: Bool { self == .kept }
}

extension ChatTurn {
    /// The saved turn of the last run in `messages` (e.g. `done.session.messages`,
    /// or a session reloaded mid-run). `firstIndex` is the absolute index of
    /// `messages[0]` in the session, used for rows keyed by position.
    ///
    /// - `.finished`: the rows with an integer server `id` after the last user
    ///   row that has one and is not a steer. Rows without an id (cancel
    ///   `_partial`, `_error` markers, compression-era duplicates) are not part
    ///   of it. Nil when there is no such user row (an ephemeral run saves none).
    /// - `.inProgress`: the rows after the last row with an integer id (rows
    ///   saved mid-run have none), keyed by position. Nil when there are none.
    static func saved(from messages: [ChatMessage], run: ChatTurnSavedRun, firstIndex: Int = 0) -> ChatTurn? {
        switch run {
        case .finished:
            guard let userIndex = messages.lastIndex(where: \.isIdentifiedTurnStart) else { return nil }
            let rows = (userIndex + 1..<messages.count).filter { messages[$0].serverID != nil }
            var used: Set<ChatTurnSegmentID> = []
            return build(messages, user: userIndex, rows: rows, run: run, firstIndex: firstIndex, usedSegmentIDs: &used)
        case .inProgress:
            return inProgress(messages, start: inProgressStart(messages, runStartedAt: nil), run: run, firstIndex: firstIndex)
        }
    }

    /// Where the active run's saved rows begin. Without the run's start time: the
    /// rows after the last id'd row (rows saved mid-run have no id). With the run's
    /// `pending_started_at` (the server stamps the run's prompt row with it): the
    /// prompt row, else the first row stamped in the run, because neither "after
    /// the last id'd row" bound holds in real sessions:
    /// - between the server's writeback (ids minted into `messages`) and the moment
    ///   it clears `active_stream_id` / `pending_*`, a load sees the run's rows WITH
    ///   ids while the run is still active;
    /// - rows before the run can lack ids (cron sessions, imported or
    ///   compression-era rows), and were swallowed into the run.
    /// Either way the same segments were drawn twice (settled + caught-up live
    /// fold, or a user row in both), and the repeated transcript ids crashed the
    /// diffable snapshot (10-01 crashes).
    static func inProgressStart(_ messages: [ChatMessage], runStartedAt: Double?) -> Int {
        // The server's own marker on the run's prompt row (`_active_turn_user`).
        if let prompt = messages.indices.first(where: { messages[$0].isActiveTurnUser && messages[$0].startsTurn }) {
            return prompt
        }
        let afterIDs = (messages.lastIndex { $0.serverID != nil }).map { $0 + 1 } ?? 0
        guard let runStartedAt else { return afterIDs }
        let floor = runStartedAt - Self.runStartTolerance
        func stampedInRun(_ index: Int) -> Bool { (messages[index].timestamp ?? -.infinity) >= floor }
        // The prompt row; else (deferred save mode: the prompt is only in the
        // pending fields until the run ends) the run's first saved row. A steer
        // never starts a turn (`startsTurn`), so it is never taken for the prompt.
        // Rows before the run can lack ids too (cron sessions, compression-era rows),
        // so "after the last id'd row" would swallow them into the run.
        if let prompt = messages.indices.first(where: { messages[$0].startsTurn && stampedInRun($0) }) {
            return prompt
        }
        if let first = messages.indices.first(where: stampedInRun) { return first }
        return afterIDs
    }

    /// The prompt row's timestamp is `pending_started_at` itself; the slack only
    /// absorbs float round-trips.
    static let runStartTolerance: Double = 0.5

    private static func inProgress(_ messages: [ChatMessage], start: Int, run: ChatTurnSavedRun, firstIndex: Int) -> ChatTurn? {
        guard start < messages.count else { return nil }
        let user = (start..<messages.count).first { messages[$0].startsTurn }
        let rows = (start..<messages.count).filter { $0 != user }
        var used: Set<ChatTurnSegmentID> = []
        return build(messages, user: user, rows: rows, run: run, firstIndex: firstIndex, usedSegmentIDs: &used)
    }

    /// Every turn of a message window, in order. The turns' `rows` ranges
    /// partition `firstIndex ..< firstIndex + messages.count` exactly.
    ///
    /// Membership uses identity and server markers only (`rowRules(for:)`),
    /// never a row's position relative to other ids:
    /// - every non-steer user row that is not a duplicate starts a turn
    ///   (id'd or not; `_recovered` rows included);
    /// - rows before the first turn start (a window that begins mid-turn)
    ///   form a turn without a user row;
    /// - inside a turn, every non-duplicate assistant row and steer row is a
    ///   step: keyed by its server id, or by absolute position without one;
    /// - duplicates (`ChatTurnRowRule.duplicate`) are skipped.
    /// With `inProgressRunID`, the rows after the last id'd row are that
    /// run's in-progress turn (`saved(.inProgress)`). With
    /// `inProgressRunHasPendingUser` (the session's `pending_user_message` /
    /// `pending_attachments` for that run), the in-progress turn exists even
    /// before the server has written its prompt row: it draws that run's
    /// pending prompt (a user row with no row index, keyed by the run).
    static func turns(
        from messages: [ChatMessage],
        firstIndex: Int = 0,
        inProgressRunID: String? = nil,
        inProgressRunHasPendingUser: Bool = false,
        inProgressRunStartedAt: Double? = nil,
        inProgressPromptRowID: Int? = nil
    ) -> [ChatTurn] {
        var end = messages.count
        var tail: ChatTurn?
        if let runID = inProgressRunID {
            let addressedPrompt = inProgressPromptRowID.flatMap { id in messages.firstIndex { $0.rowID == id && $0.startsTurn } }
            // Hermes exports its proven prompt address. A missing address cannot
            // borrow an older prompt just because its timestamp follows the start.
            let start = messages.contains(where: \.isHermesRow) ? (addressedPrompt ?? messages.count)
                : inProgressStart(messages, runStartedAt: inProgressRunStartedAt)
            if start < messages.count {
                tail = inProgress(messages, start: start, run: .inProgress(runID: runID), firstIndex: firstIndex)
                end = start
            }
            if inProgressRunHasPendingUser, tail == nil {
                // The prompt is only in the run's pending fields so far: the
                // in-progress turn is that run's prompt, keyed by the run.
                tail = ChatTurn(userMessageID: nil, state: .live(runID: runID), steps: [], segments: [])
            }
        }

        let rules = rowRules(for: messages)
        let answered = Set(messages.compactMap { $0.role == "tool" ? ($0.toolCallId ?? $0.toolUseId) : nil })
        // Kept rows whose id repeats an earlier row's are other messages under
        // the same id (c46afc29fc0d 292/293): key them by position.
        var seenIDs: Set<Int> = []
        var positional: Set<Int> = []
        for (index, message) in messages.enumerated() {
            guard !message.isHermesRow else { continue }
            guard let id = message.serverID else { continue }
            if !seenIDs.insert(id).inserted, rules[index].isKept { positional.insert(index) }
        }
        var usedSegmentIDs: Set<ChatTurnSegmentID> = []
        let identities = messages.enumerated().map {
            TurnRowIdentity.of($0.element, absoluteIndex: firstIndex + $0.offset, positional: positional.contains($0.offset))
        }
        var starts: [Int] = []
        for index in 0..<end where rules[index].isKept && messages[index].startsTurn {
            starts.append(index)
        }
        if starts.first != 0, end > 0 { starts.insert(0, at: 0) }

        let declaredToolIDs = Set(messages.flatMap { $0.savedToolCalls.map(\.id) })
        let occurrenceResults = TurnToolResults(messages: messages, firstIndex: firstIndex, kept: rules.map(\.isKept))
        var result: [ChatTurn] = []
        for (ordinal, start) in starts.enumerated() {
            let stop = ordinal + 1 < starts.count ? starts[ordinal + 1] : end
            let user = rules[start].isKept && messages[start].startsTurn ? start : nil
            let rows = (start..<stop).filter { $0 != user && rules[$0].isKept }
            var turn = build(messages, user: user, rows: rows, run: .finished, firstIndex: firstIndex,
                             answered: answered, positional: positional, declaredToolIDs: declaredToolIDs,
                             occurrenceResults: occurrenceResults, rowIdentities: identities, usedSegmentIDs: &usedSegmentIDs)
            turn.rows = (firstIndex + start)..<(firstIndex + stop)
            result.append(turn)
        }
        if let tail { result.append(tail) }
        return result
    }

    /// Per row: kept, or a copy of an earlier row. A row is dropped only when
    /// ids (or the server's copied timestamp) prove it is a copy; turns follow
    /// the server's saved order and nothing is moved.
    /// - `.toolCallIDs`: an id-less or repeated-id assistant row whose every
    ///   tool-call id is on an id'd row.
    /// - `.toolResultID`: an id-less or repeated-id tool row whose
    ///   `tool_call_id` is on an id'd tool row.
    /// - `.userIDAndTimestamp`: a repeated-id user row whose id AND timestamp
    ///   equal an earlier kept user row's (same id, other timestamp: a different
    ///   message, kept).
    /// - `.userTimestampCopy`: an id-less user row whose timestamp equals the
    ///   id'd user row that opened the current turn (the server copies the
    ///   dict, so the float is exact).
    /// Content is never compared.
    static func rowRules(for messages: [ChatMessage]) -> [ChatTurnRowRule] {
        var firstRowByID: [Int: Int] = [:]
        var idCallRow: [String: Int] = [:]
        var idResultRow: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            guard let id = message.serverID else { continue }
            if firstRowByID[id] == nil { firstRowByID[id] = index }
            for call in message.savedToolCalls where idCallRow[call.id] == nil { idCallRow[call.id] = index }
            if message.role == "tool", let callID = message.toolCallId ?? message.toolUseId, idResultRow[callID] == nil {
                idResultRow[callID] = index
            }
        }
        var rules: [ChatTurnRowRule] = []
        rules.reserveCapacity(messages.count)
        var opener: Int?
        var keptUserRowsByID: [Int: [Int]] = [:]
        var firstRowByUID: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            if message.isHermesRow {
                if let uid = message.messageUID {
                    if let first = firstRowByUID[uid] {
                        rules.append(.duplicate(ofRow: first, reason: .messageUID))
                        continue
                    }
                    firstRowByUID[uid] = index
                }
                rules.append(.kept)
                continue
            }
            let repeated = message.serverID.map { firstRowByID[$0] != index } ?? false
            var rule = ChatTurnRowRule.kept
            if message.serverID == nil || repeated {
                rule = copyRule(message, index: index, repeated: repeated, opener: opener,
                                keptUserRowsByID: keptUserRowsByID, idCallRow: idCallRow,
                                idResultRow: idResultRow, messages: messages)
            }
            if rule.isKept, message.startsTurn {
                opener = index
                if let id = message.serverID { keptUserRowsByID[id, default: []].append(index) }
            }
            rules.append(rule)
        }
        return rules
    }

    private static func copyRule(
        _ message: ChatMessage,
        index: Int,
        repeated: Bool,
        opener: Int?,
        keptUserRowsByID: [Int: [Int]],
        idCallRow: [String: Int],
        idResultRow: [String: Int],
        messages: [ChatMessage]
    ) -> ChatTurnRowRule {
        if message.startsTurn {
            if repeated, let id = message.serverID {
                if let original = keptUserRowsByID[id]?.first(where: { messages[$0].timestamp == message.timestamp }) {
                    return .duplicate(ofRow: original, reason: .userIDAndTimestamp)
                }
            } else if let opener, messages[opener].serverID != nil,
                      let stamp = message.timestamp, messages[opener].timestamp == stamp {
                return .duplicate(ofRow: opener, reason: .userTimestampCopy)
            }
            return .kept
        }
        // Only real tool-call ids are identity (`#n` is a placeholder for a
        // call saved without an id).
        let calls = message.savedToolCalls
        if message.role == "assistant", !calls.isEmpty,
           calls.allSatisfy({ !$0.id.hasPrefix("#") && (idCallRow[$0.id].map { $0 != index } ?? false) }),
           let original = idCallRow[calls[0].id] {
            return .duplicate(ofRow: original, reason: .toolCallIDs)
        }
        if message.role == "tool", let callID = message.toolCallId ?? message.toolUseId,
           let original = idResultRow[callID], original != index {
            return .duplicate(ofRow: original, reason: .toolResultID)
        }
        return .kept
    }

    private static func build(
        _ messages: [ChatMessage],
        user: Int?,
        rows: [Int],
        run: ChatTurnSavedRun,
        firstIndex: Int,
        answered: Set<String>? = nil,
        positional: Set<Int> = [],
        declaredToolIDs: Set<String>? = nil,
        occurrenceResults: TurnToolResults? = nil,
        rowIdentities: [TurnRowIdentity]? = nil,
        usedSegmentIDs: inout Set<ChatTurnSegmentID>
    ) -> ChatTurn {
        let answeredToolIDs = answered ?? Set(rows.compactMap { index -> String? in
            messages[index].role == "tool" ? (messages[index].toolCallId ?? messages[index].toolUseId) : nil
        })
        let unanswered: ChatTurnTool.State
        let state: State
        switch run {
        case .finished:
            unanswered = .failed
            state = .settled
        case .inProgress(let runID):
            unanswered = .running
            state = .live(runID: runID)
        }

        let declarations = declaredToolIDs ?? Set(messages.flatMap { $0.savedToolCalls.map(\.id) })
        let identities = rowIdentities ?? messages.enumerated().map {
            TurnRowIdentity.of($0.element, absoluteIndex: firstIndex + $0.offset, positional: positional.contains($0.offset))
        }
        let occurrenceResults = occurrenceResults ?? TurnToolResults(messages: messages, firstIndex: firstIndex)
        var providerOccurrences: [String: Int] = [:]
        var steps: [ChatTurnStep] = []
        // The previous reasoning-bearing row's reasoning (trimmed) and its step.
        // The server sometimes stores one thought on two consecutive reasoning
        // rows of a turn; the live stream draws it once, on the later step, so
        // the earlier row's copy is dropped here. Text is compared nowhere else.
        var lastReasoning: (step: Int, text: String)?
        for index in rows {
            let row = messages[index]
            // A kept row whose id repeats an earlier row's (a different message
            // the server stored under the same id) is keyed by position.
            let identity = identities[index]
            let rowID = row.isHermesRow ? identity.rowID : (positional.contains(index) ? nil : row.serverID)
            let key: (String) -> ChatTurnSegmentID = identity.segment
            var segments: [ChatTurnSegment] = []
            switch row.role {
            case "user" where row.isSteerRow:
                segments = [ChatTurnSegment(id: key("steer"), kind: .steer(row.steerText))]
            case "delegation_completion":
                if let completion = HermesDelegationCompletion(row) {
                    segments = [ChatTurnSegment(id: key("delegation"), kind: .delegationCompletion(completion))]
                }
            case "tool":
                // Its loaded declaration already owns the rendered step; a receipt adds no empty step.
                guard let result = ToolCallGroup.fallbackToolResult(row) else { continue }
                if row.isHermesRow {
                    if occurrenceResults.matchedResultIndices.contains(index) { continue }
                } else if declarations.contains(result.id) { continue }
                let tool = ChatTurnTool(id: row.isHermesRow ? identity.uid : result.id, name: result.displayName,
                                       state: result.isError == true ? .failed : .done,
                                       preview: row.isHermesRow ? result.preview : nil,
                                       args: row.isHermesRow ? result.args : nil,
                                       duration: row.isHermesRow ? result.duration : nil, providerID: result.id)
                // receipt rows own identity; call ids can repeat across saved results.
                // Keep the server call id on the tool for declaration pairing and actions.
                segments = [ChatTurnSegment(id: key("tool-result"), kind: .tool(tool))]
            case "assistant":
                if let thinking = row.savedReasoning {
                    let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !row.isHermesRow, let last = lastReasoning, last.text == trimmed {
                        steps[last.step].segments.removeAll { segment in
                            if case .thinking = segment.kind { return true } else { return false }
                        }
                    }
                    lastReasoning = row.isHermesRow ? nil : (steps.count, trimmed)
                    segments.append(ChatTurnSegment(id: key("thinking"), kind: .thinking(ChatTurnText(thinking))))
                }
                if let text = row.content, !text.isEmpty {
                    segments.append(ChatTurnSegment(id: key("text"), kind: .text(ChatTurnText(text))))
                }
                for (callIndex, call) in row.savedToolCalls.enumerated() {
                    let uid = row.isHermesRow ? identity.toolUID(at: callIndex) : call.id
                    var segmentID = ChatTurnSegmentID.tool(uid)
                    if !row.isHermesRow, usedSegmentIDs.contains(segmentID) {
                        // Two redacted ids can collapse to the same text; keep rows distinct.
                        let owner = rowID.map(String.init) ?? "p\(firstIndex + index)"
                        segmentID = ChatTurnSegmentID(rawValue: "tool:\(call.id)@\(owner):\(callIndex)")
                    }
                    let occurrence = providerOccurrences[call.id, default: 0] + 1
                    providerOccurrences[call.id] = occurrence
                    let answered = row.isHermesRow
                        ? occurrenceResults.rowsByToolUID[uid] != nil
                        : answeredToolIDs.contains(call.id)
                    var tool = ChatTurnTool(
                        id: row.isHermesRow ? uid : call.id,
                        name: call.name,
                        state: answered ? .done : unanswered,
                        providerID: call.id, occurrence: row.isHermesRow ? occurrence : 1
                    )
                    if row.isHermesRow {
                        let details = TurnToolResults.presentation(tool: tool, callIndex: callIndex, row: row,
                                                                  result: occurrenceResults.rowsByToolUID[uid])
                        tool.args = details.args
                        tool.preview = details.preview
                        tool.duration = details.duration
                    }
                    segments.append(ChatTurnSegment(id: segmentID, kind: .tool(tool)))
                }
            default:
                continue
            }
            usedSegmentIDs.formUnion(segments.map(\.id))
            steps.append(ChatTurnStep(messageID: rowID, rowIndex: firstIndex + index, segments: segments,
                                      uid: row.isHermesRow ? identity.uid : nil))
        }

        return ChatTurn(
            userMessageID: user.flatMap { messages[$0].isHermesRow ? identities[$0].rowID : (positional.contains($0) ? nil : messages[$0].serverID) },
            state: state,
            steps: steps,
            segments: steps.flatMap(\.segments),
            userRowIndex: user.map { firstIndex + $0 },
            rows: (firstIndex + (user ?? rows.first ?? 0))..<(firstIndex + (rows.last.map { $0 + 1 } ?? (user ?? 0) + 1)),
            promptUID: user.flatMap { messages[$0].isHermesRow ? identities[$0].uid : nil }
        )
    }
}

extension ChatMessage {
    /// A steering hint: flagged `display_kind: "steer"`, or exactly the OOB
    /// wrapper (`isSteerMessage`; the state.db projection drops the flag).
    fileprivate var isSteerRow: Bool {
        role == "user" && isSteerMessage
    }

    /// A non-steer user row with an integer id: opens a settled turn.
    fileprivate var isIdentifiedTurnStart: Bool {
        role == "user" && !isSteerRow && serverID != nil
    }

    /// A non-steer user row: starts a turn unless it is a duplicate.
    fileprivate var startsTurn: Bool {
        role == "user" && !isSteerRow
    }

    /// Saved per-message reasoning: `reasoning_content`, else
    /// `reasoning_details[]`, else `reasoning` (which the server rewrites at
    /// settle and can land on the wrong step, so it is the last resort).
    var savedReasoning: String? {
        for candidate in [reasoningContent, reasoningDetailsText, reasoning] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// `tool_calls[]` as (id, function name), in saved order.
    var savedToolCalls: [(id: String, name: String)] {
        (toolCalls ?? []).enumerated().map { index, call in
            guard case .object(let object) = call else {
                return (id: "#\(index)", name: "")
            }
            var id = ""
            if case .string(let value)? = object["id"] { id = value }
            var name = ""
            if case .object(let function)? = object["function"], case .string(let value)? = function["name"] {
                name = value
            } else if case .string(let value)? = object["name"] {
                name = value
            }
            return (id: id.isEmpty ? "#\(index)" : id, name: name)
        }
    }
}
