import Foundation

/// Folds one run's SSE events into a live `ChatTurn`.
///
/// Identity comes only from the server: the run `seq` (from the SSE event id
/// `<stream_id>:<seq>`) drops anything already applied, so a reconnect replay
/// (`after_seq=N`) or a full replay on top of an existing fold never
/// duplicates; tools are keyed by their `tid`. There is no model-call event
/// on the wire, so the live turn is an ordered list of segments, not steps.
///
/// Appending a delta is O(delta): text grows in place in the last entry's
/// buffer. `turn` is O(segments): each thinking/text segment is an O(1) window
/// onto its buffer, so reading `turn` per event copies no text, and appending
/// after a read copies nothing already published (plan §3.2, commit D).
///
/// A fold is a value: a copy that is then mutated first takes its own buffers
/// (O(text), only on a real struct copy; the view model mutates in place).
struct ChatTurnLiveFold {
    enum Terminal: Equatable {
        /// `done` arrived: the saved turn is ready to settle onto.
        case done
        /// `cancel`: no `done`; the saved turn is flattened.
        case cancelled
        /// `error` / `apperror`: no `done`; the saved turn is flattened.
        case failed
    }

    let runID: String
    private(set) var lastAppliedSeq = 0
    private(set) var terminal: Terminal?
    /// `done.session.messages` when the done payload carried them.
    private(set) var doneMessages: [ChatMessage]?

    private enum EntryKind { case thinking, text, tool, steer, append, delegation }

    private struct Entry {
        let id: ChatTurnSegmentID
        let kind: EntryKind
        var text: ChatTurnTextBuffer?
        var tool: ChatTurnTool?
        var append: VoiceAppendObservation? = nil
        var delegation: HermesDelegationCompletion? = nil
        var revealedUTF8Count = 0
        var heldPreviousTick = false
    }

    /// Held only by this fold (never by published windows): not uniquely
    /// referenced means the fold was copied, and the copy must own its buffers.
    private final class Owner {}
    private var owner = Owner()

    private var entries: [Entry] = []
    /// Text-buffer indices with unrevealed bytes; historical segments need no reveal work.
    private var pendingRevealIndices = IndexSet()
    private var nextOrdinal = 0
    private var toolIndexByID: [String: Int] = [:]
    private var toolOccurrences: [String: Int] = [:]
    /// Legacy tool events without `tid`: indices of still-running calls per name.
    private var runningLegacyToolsByName: [String: [Int]] = [:]

    init(runID: String) {
        self.runID = runID
    }

    /// Rebuilds the authoritative fold from durable pieces plus the uncovered live tail.
    /// Saved provider IDs populate the same lookup the next completion uses.
    init(runID: String, seeded segments: [ChatTurnSegment], lastAppliedSeq: Int = 0, reservedIDs: [ChatTurnSegmentID] = []) {
        self.runID = runID
        self.lastAppliedSeq = lastAppliedSeq
        for id in reservedIDs where id.rawValue.hasPrefix("live:\(runID):") {
            if let ordinal = Int(id.rawValue.split(separator: ":").last ?? "") { nextOrdinal = max(nextOrdinal, ordinal + 1) }
        }
        var providerCounts: [String: Int] = [:]
        for segment in segments {
            let kind: EntryKind
            let string: String?
            var tool: ChatTurnTool?
            var observation: VoiceAppendObservation?
            var delegation: HermesDelegationCompletion?
            switch segment.kind {
            case .thinking(let text): kind = .thinking; string = text.string
            case .text(let text): kind = .text; string = text.string
            case .steer(let text): kind = .steer; string = text
            case .tool(let value):
                kind = .tool; string = nil; tool = value
                toolIndexByID[value.providerID] = entries.count
                providerCounts[value.providerID, default: 0] += 1
                toolOccurrences[value.providerID] = max(toolOccurrences[value.providerID, default: 0],
                                                       max(value.occurrence, providerCounts[value.providerID, default: 0]))
            case .append(let value): kind = .append; string = nil; observation = value
            case .delegationCompletion(let value): kind = .delegation; string = nil; delegation = value
            }
            let buffer = string.map { value in
                let buffer = ChatTurnTextBuffer(); buffer.append(value); return buffer
            }
            entries.append(Entry(id: segment.id, kind: kind, text: buffer, tool: tool, append: observation, delegation: delegation,
                                 revealedUTF8Count: buffer?.utf8Count ?? 0))
            // Ordinals advance past seeded live identities; saved keys use a different namespace.
            if segment.id.rawValue.hasPrefix("live:\(runID):"),
               let ordinal = Int(segment.id.rawValue.split(separator: ":").last ?? "") {
                nextOrdinal = max(nextOrdinal, ordinal + 1)
            }
        }
    }

    /// The last applied seq, parsed from an SSE event id `<stream_id>:<seq>`.
    static func seq(fromEventID eventID: String) -> Int? {
        guard let separator = eventID.lastIndex(of: ":") else { return nil }
        return Int(eventID[eventID.index(after: separator)...])
    }

    /// Applies one event. `seq` nil (no event id) is applied without dedup.
    mutating func apply(seq: Int?, event: SSEEvent) {
        ensureOwnedBuffers()
        if let seq {
            guard seq > lastAppliedSeq else { return }
            lastAppliedSeq = seq
        }

        switch event {
        case .token(let text):
            append(text, as: .text)
        case .reasoning(let text):
            append(text, as: .thinking)
        case .interimAssistant(let interim):
            // `already_streamed` repeats text that came as tokens.
            guard interim.alreadyStreamed != true else { return }
            append(interim.text ?? "", as: .text)
        case .toolStarted(let tool):
            startTool(tool, seq: seq)
        case .toolCompleted(let tool):
            completeTool(tool, seq: seq)
        case .done(let done):
            guard terminal == nil else { return }
            terminal = .done
            doneMessages = done.session?.messages
        case .cancelled:
            guard terminal == nil else { return }
            terminal = .cancelled
        case .error:
            guard terminal == nil else { return }
            terminal = .failed
        default:
            break
        }
    }

    /// Full reasoning replaces the current tool-delimited step only before its text.
    mutating func replaceReasoning(seq: Int?, text: String) {
        if let seq {
            guard seq > lastAppliedSeq else { return }
            lastAppliedSeq = seq
        }
        let boundary = entries.lastIndex { $0.kind == .tool || $0.kind == .steer }.map { $0 + 1 } ?? 0
        guard !entries.dropFirst(boundary).contains(where: { $0.kind == .text }), !text.isEmpty else { return }
        ensureOwnedBuffers()
        if let index = entries.indices.dropFirst(boundary).last(where: { entries[$0].kind == .thinking }) {
            let buffer = ChatTurnTextBuffer(); buffer.append(text)
            entries[index].text = buffer
            entries[index].revealedUTF8Count = buffer.utf8Count
        } else {
            append(text, as: .thinking)
            if let index = entries.indices.last { entries[index].revealedUTF8Count = entries[index].text?.utf8Count ?? 0 }
        }
    }

    /// The user's steer, drawn at once where it was sent in the run: the
    /// journal carries no steer event, so this is the phone's own echo (like
    /// the optimistic user row). The saved turn's steer row replaces it at
    /// settle / reload; nothing matches text.
    mutating func appendSteer(_ text: String, localID: String) {
        ensureOwnedBuffers()
        let buffer = ChatTurnTextBuffer()
        buffer.append(text)
        entries.append(Entry(id: ChatTurnSegmentID(rawValue: "steer:\(localID)"), kind: .steer, text: buffer, tool: nil))
    }

    /// sits after everything already folded and text that follows opens a new segment.
    mutating func appendSent(_ observation: VoiceAppendObservation) {
        ensureOwnedBuffers()
        entries.append(Entry(id: Self.appendSegmentID(observation), kind: .append, text: nil, tool: nil,
                             append: observation))
    }

    static func appendSegmentID(_ observation: VoiceAppendObservation) -> ChatTurnSegmentID {
        ChatTurnSegmentID(rawValue: "append:\(observation.id)")
    }

    private mutating func ensureOwnedBuffers() {
        guard !isKnownUniquelyReferenced(&owner) else { return }
        owner = Owner()
        for index in entries.indices { entries[index].text = entries[index].text?.copy() }
    }

    /// The live turn so far. O(segments), no text copied.
    var turn: ChatTurn {
        let interrupted = terminal == .cancelled || terminal == .failed
        return ChatTurn(
            userMessageID: nil,
            state: interrupted ? .interrupted(runID: runID) : .live(runID: runID),
            steps: [],
            segments: entries.lazy.map(Self.segment(for:))
        )
    }

    /// Presentation windows share the authoritative buffers; only their visible byte counts differ.
    var presentedTurn: ChatTurn {
        var result = turn
        result.segments = entries.map { entry in
            switch entry.kind {
            case .text:
                return ChatTurnSegment(id: entry.id, kind: .text(ChatTurnText(buffer: entry.text!, utf8Count: entry.revealedUTF8Count)))
            case .thinking:
                return ChatTurnSegment(id: entry.id, kind: .thinking(ChatTurnText(buffer: entry.text!, utf8Count: entry.revealedUTF8Count)))
            default: return Self.segment(for: entry)
            }
        }
        return result
    }

    /// Advance windows with upstream's pure gate. Event folding and replay cursors never wait.
    /// Returns whether a held fragment needs one more reveal tick.
    mutating func revealStreamingContent(flush: Bool) -> Bool {
        var pending = false
        for index in pendingRevealIndices {
            guard let buffer = entries[index].text else { continue }
            let count = entries[index].revealedUTF8Count
            guard count < buffer.utf8Count else { continue }
            if flush || entries[index].kind != .text {
                entries[index].revealedUTF8Count = buffer.utf8Count
                entries[index].heldPreviousTick = false
            } else {
                let suffix = String(decoding: buffer.storage.utf8.dropFirst(count), as: UTF8.self)
                let cut = StreamingRevealGate.cut(suffix, heldPreviousTick: entries[index].heldPreviousTick)
                entries[index].revealedUTF8Count += cut.shown.utf8.count
                entries[index].heldPreviousTick = !cut.held.isEmpty
                pending = pending || !cut.held.isEmpty
            }
            if entries[index].revealedUTF8Count == buffer.utf8Count {
                pendingRevealIndices.remove(index)
            }
        }
        return pending
    }

    private static func segment(for entry: Entry) -> ChatTurnSegment {
        switch entry.kind {
        case .thinking:
            return ChatTurnSegment(id: entry.id, kind: .thinking(ChatTurnText(buffer: entry.text!)))
        case .text:
            return ChatTurnSegment(id: entry.id, kind: .text(ChatTurnText(buffer: entry.text!)))
        case .tool:
            return ChatTurnSegment(id: entry.id, kind: .tool(entry.tool!))
        case .steer:
            return ChatTurnSegment(id: entry.id, kind: .steer(ChatTurnText(buffer: entry.text!).string))
        case .append:
            return ChatTurnSegment(id: entry.id, kind: .append(entry.append!))
        case .delegation:
            return ChatTurnSegment(id: entry.id, kind: .delegationCompletion(entry.delegation!))
        }
    }

    private mutating func append(_ delta: String, as kind: EntryKind) {
        guard !delta.isEmpty else { return }
        if let last = entries.indices.last, entries[last].kind == kind, let buffer = entries[last].text {
            buffer.append(delta)
            pendingRevealIndices.insert(last)
            return
        }
        let buffer = ChatTurnTextBuffer()
        buffer.append(delta)
        entries.append(Entry(id: .live(runID: runID, ordinal: takeOrdinal()), kind: kind, text: buffer, tool: nil))
        pendingRevealIndices.insert(entries.count - 1)
    }

    private mutating func startTool(_ event: ToolStreamEvent, seq: Int?) {
        let name = event.name ?? ""
        let ordinal = takeOrdinal()
        let toolID: String
        let providerID: String
        let occurrence: Int
        if let stableID = event.stableID {
            // A provider ID addresses the currently running occurrence; a
            // subsequent start after completion is a new call, not a replay.
            if let index = toolIndexByID[stableID], entries[index].tool?.state == .running {
                updateToolDetails(event, at: index)
                return
            }
            occurrence = toolOccurrences[stableID, default: 0] + 1
            toolOccurrences[stableID] = occurrence
            providerID = stableID
            toolID = stableID + (occurrence > 1 ? "~\(occurrence)" : "")
        } else {
            toolID = "\(name)#\(seq ?? -ordinal)"
            providerID = toolID
            occurrence = 1
            runningLegacyToolsByName[name, default: []].append(entries.count)
        }
        toolIndexByID[providerID] = entries.count
        entries.append(Entry(
            id: .tool(toolID),
            kind: .tool,
            text: nil,
            tool: ChatTurnTool(id: toolID, name: name, state: .running,
                               preview: event.preview, args: event.args, providerID: providerID, occurrence: occurrence)
        ))
    }

    private mutating func completeTool(_ event: ToolStreamEvent, seq: Int?) {
        let state: ChatTurnTool.State = event.isError == true ? .failed : .done
        let index: Int
        if let stableID = event.stableID {
            if let known = toolIndexByID[stableID] {
                index = known
            } else {
                // Completion for a call whose start this fold never saw.
                startTool(event, seq: seq)
                guard let added = toolIndexByID[stableID] else { return }
                index = added
            }
        } else {
            guard let running = runningLegacyToolsByName[event.name ?? ""]?.popLast() else { return }
            index = running
        }
        entries[index].tool?.state = state
        updateToolDetails(event, at: index)
    }

    /// A start can enrich a seeded declaration, just as a completion can
    /// enrich its start. Both write evidence onto that addressed occurrence.
    private mutating func updateToolDetails(_ event: ToolStreamEvent, at index: Int) {
        if let preview = event.preview, !preview.isEmpty { entries[index].tool?.preview = preview }
        if let args = event.args, !args.isEmpty { entries[index].tool?.args = args }
        if let duration = event.duration { entries[index].tool?.duration = duration }
    }

    private mutating func takeOrdinal() -> Int {
        defer { nextOrdinal += 1 }
        return nextOrdinal
    }
}
