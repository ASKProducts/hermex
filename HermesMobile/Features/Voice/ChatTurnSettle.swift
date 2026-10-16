import Foundation

/// Maps a live turn onto its settled turn at turn end, so drawing can keep
/// row identity while content switches to the saved copy.
///
/// Pairing never compares text:
/// - tools pair by tool id, else by position in the ordered tool list (a
///   saved id can be secret-redacted, e.g. `toolu_01Sbmyy2***`);
/// - thinking / text segments pair by kind and position within the gap
///   between the same two paired tool anchors.
/// Content always comes from the settled turn. A run that ended without
/// `done` (cancel / error) has no settle: its saved turn is flattened and
/// replaces the live one on reload.
struct ChatTurnSettle: Equatable {
    /// The turn to draw from now on.
    let turn: ChatTurn
    /// Live segment id -> settled segment id, for every paired segment.
    let settledIDByLiveID: [ChatTurnSegmentID: ChatTurnSegmentID]
    /// Live tools that paired only by position (their saved id differed).
    let toolsPairedByPosition: [ChatTurnSegmentID]
    /// Live segments with no settled partner (their rows go away).
    let unpairedLive: [ChatTurnSegmentID]
    /// Settled segments with no live partner (their rows appear).
    let unpairedSettled: [ChatTurnSegmentID]

    /// Nil when the run did not end with `done`, or the saved messages hold
    /// no settled turn (e.g. an ephemeral run). `savedMessages` overrides
    /// `done.session.messages` (e.g. the session re-read after reattach).
    static func settle(_ fold: ChatTurnLiveFold, savedMessages: [ChatMessage]? = nil, receipt: HermesTurnReceipt? = nil) -> ChatTurnSettle? {
        guard fold.terminal == .done,
              let messages = savedMessages ?? fold.doneMessages,
              let settled = savedTurn(from: messages, live: fold.turn, receipt: receipt)
        else {
            return nil
        }
        return settle(live: fold.turn, onto: settled, receipt: receipt)
    }

    static func savedTurn(from messages: [ChatMessage], live: ChatTurn, receipt: HermesTurnReceipt?, firstIndex: Int = 0) -> ChatTurn? {
        guard let receipt else { return ChatTurn.saved(from: messages, run: .finished, firstIndex: firstIndex) }
        let turns = ChatTurn.turns(from: messages, firstIndex: firstIndex)
        if let row = receipt.finalAssistantRowID,
           let turn = turns.first(where: { $0.steps.contains { $0.messageID == row } }) { return turn }
        if let row = receipt.userRowID,
           let turn = turns.first(where: { $0.userMessageID == row }) { return turn }
        if let uid = live.promptUID {
            return turns.first { turn in
                guard let row = turn.userRowIndex, messages.indices.contains(row - firstIndex) else { return false }
                return TurnRowIdentity.of(messages[row - firstIndex], absoluteIndex: row).resolves(uid)
            }
        }
        // A receipt never authorizes the latest (possibly queued) user row.
        return nil
    }

    static func settle(live: ChatTurn, onto settled: ChatTurn, receipt: HermesTurnReceipt? = nil) -> ChatTurnSettle {
        let liveSegments = live.segments
        let settledSegments = settled.segments
        let liveTools = liveSegments.indices.filter { liveSegments[$0].isTool }
        let settledTools = settledSegments.indices.filter { settledSegments[$0].isTool }

        // 1. Tools: by id, then by position among the leftovers.
        var settledToolOrdinalsByID: [String: [Int]] = [:]
        for (ordinal, index) in settledTools.enumerated() {
            if case .tool(let tool) = settledSegments[index].kind {
                settledToolOrdinalsByID[tool.providerID, default: []].append(ordinal)
            }
        }
        var settledOrdinalByLiveOrdinal: [Int: Int] = [:]
        var takenSettledOrdinals: Set<Int> = []
        var liveOccurrences: [String: Int] = [:]
        for (liveOrdinal, index) in liveTools.enumerated() {
            guard case .tool(let tool) = liveSegments[index].kind else { continue }
            let occurrence = liveOccurrences[tool.providerID, default: 0]
            liveOccurrences[tool.providerID] = occurrence + 1
            guard let ordinals = settledToolOrdinalsByID[tool.providerID], occurrence < ordinals.count else { continue }
            let settledOrdinal = ordinals[occurrence]
            settledOrdinalByLiveOrdinal[liveOrdinal] = settledOrdinal
            takenSettledOrdinals.insert(settledOrdinal)
        }
        var byPosition: [ChatTurnSegmentID] = []
        for liveOrdinal in liveTools.indices where settledOrdinalByLiveOrdinal[liveOrdinal] == nil {
            guard liveOrdinal < settledTools.count, !takenSettledOrdinals.contains(liveOrdinal) else { continue }
            settledOrdinalByLiveOrdinal[liveOrdinal] = liveOrdinal
            takenSettledOrdinals.insert(liveOrdinal)
            byPosition.append(liveSegments[liveTools[liveOrdinal]].id)
        }

        // A seeded segment already names its durable source. Preserve that
        // relation before positional pairing or the final-response receipt:
        // an earlier saved text is not a streamed final response.
        let savedIDs = Set(settledSegments.map(\.id))
        var mapping = Dictionary(uniqueKeysWithValues: liveSegments.compactMap { segment in
            savedIDs.contains(segment.id) ? (segment.id, segment.id) : nil
        })
        for (liveOrdinal, settledOrdinal) in settledOrdinalByLiveOrdinal {
            let liveID = liveSegments[liveTools[liveOrdinal]].id
            let savedID = settledSegments[settledTools[settledOrdinal]].id
            if mapping[liveID] == nil, !mapping.values.contains(savedID) { mapping[liveID] = savedID }
        }

        // The receipt names the response after the last tool, not whichever
        // text happens to be last in the fold. A non-streamed final has no live
        // text in that response; its saved row therefore keeps its own identity.
        let lastToolIndex = liveSegments.lastIndex { if case .tool = $0.kind { return true }; return false }
        if let finalRow = receipt?.finalAssistantRowID,
           let finalIndex = liveSegments.lastIndex(where: { if case .text = $0.kind { return true } else { return false } }),
           finalIndex > (lastToolIndex ?? -1),
           mapping[liveSegments[finalIndex].id] == nil,
           let step = settled.steps.first(where: { $0.messageID == finalRow }),
           let savedFinal = step.segments.last(where: { if case .text = $0.kind { return true } else { return false } }),
           !mapping.values.contains(savedFinal.id) {
            mapping[liveSegments[finalIndex].id] = savedFinal.id
        }

        // 2. Thinking / text: by kind and position within the gap after the
        // same settled tool anchor (-1 = before the first tool). A gap after
        // an unpaired live tool has no anchor and pairs nothing.
        let liveGaps = gaps(of: liveSegments) { liveOrdinal in settledOrdinalByLiveOrdinal[liveOrdinal] }
        let settledGaps = gaps(of: settledSegments) { $0 }
        for (anchor, liveGap) in liveGaps {
            guard let anchor, let settledGap = settledGaps[anchor] else { continue }
            for (kind, liveIDs) in liveGap {
                let reserved = Set(mapping.values)
                let settledIDs = (settledGap[kind] ?? []).filter { !reserved.contains($0) }
                for (liveID, settledID) in zip(liveIDs.filter { mapping[$0] == nil }, settledIDs) {
                    mapping[liveID] = settledID
                }
            }
        }

        let pairedSettled = Set(mapping.values)
        return ChatTurnSettle(
            turn: settled,
            settledIDByLiveID: mapping,
            toolsPairedByPosition: byPosition,
            unpairedLive: liveSegments.map(\.id).filter { mapping[$0] == nil },
            unpairedSettled: settledSegments.map(\.id).filter { !pairedSettled.contains($0) }
        )
    }

    private enum GapKind: Hashable { case thinking, text, steer }

    /// Drawn id of each paired settled segment (settled -> live), for the
    /// item function (plan §4.3). `drawnLiveID` maps a live id to the id it
    /// is drawn under (itself, or a catch-up alias).
    func idAlias(drawnLiveID: (ChatTurnSegmentID) -> ChatTurnSegmentID = { $0 }) -> [ChatTurnSegmentID: ChatTurnSegmentID] {
        var alias: [ChatTurnSegmentID: ChatTurnSegmentID] = [:]
        for (live, settled) in settledIDByLiveID {
            let drawn = drawnLiveID(live)
            if drawn != settled { alias[settled] = drawn }
        }
        return alias
    }

    /// Non-tool segment ids grouped by (settled tool anchor, kind), in order.
    /// `anchor` maps a tool's ordinal in this list to its settled ordinal
    /// (nil when unpaired).
    private static func gaps(
        of segments: [ChatTurnSegment],
        anchor: (Int) -> Int?
    ) -> [Int?: [GapKind: [ChatTurnSegmentID]]] {
        var result: [Int?: [GapKind: [ChatTurnSegmentID]]] = [:]
        var current: Int? = -1
        var toolOrdinal = 0
        for segment in segments {
            let kind: GapKind
            switch segment.kind {
            case .tool:
                current = anchor(toolOrdinal)
                toolOrdinal += 1
                continue
            case .thinking: kind = .thinking
            case .text: kind = .text
            case .steer: kind = .steer
            case .append, .delegationCompletion: continue
            }
            result[current, default: [:]][kind, default: []].append(segment.id)
        }
        return result
    }
}

extension ChatTurn {
    /// This turn drawn under the ids its rows already have on screen (plan
    /// §4.3, commit E): every segment in `idAlias` takes the aliased id (in
    /// `segments` and `steps` alike), and the turn's items take `itemKey`.
    /// Content is untouched. O(segments); an empty alias returns self.
    func drawn(idAlias: [ChatTurnSegmentID: ChatTurnSegmentID], itemKey: String?) -> ChatTurn {
        guard !idAlias.isEmpty || itemKey != nil else { return self }
        func alias(_ segments: [ChatTurnSegment]) -> [ChatTurnSegment] {
            segments.map { segment in
                idAlias[segment.id].map { ChatTurnSegment(id: $0, kind: segment.kind) } ?? segment
            }
        }
        var turn = self
        if !idAlias.isEmpty {
            turn.segments = alias(segments)
            turn.steps = steps.map { step in
                var step = step
                step.segments = alias(step.segments)
                return step
            }
        }
        if let itemKey { turn.itemKey = itemKey }
        return turn
    }
}
