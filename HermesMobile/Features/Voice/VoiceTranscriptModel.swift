import Foundation
import Observation

/// What the voice screen's transcript shows: the chat's saved rows, read and drawn the way the
/// chat reads a Hermes session (`HermesTranscriptHistory` pages, `HermesTranscriptProjection`),
/// then the voice turns the server has not saved (yet) as `VoiceTurn`s. `VoiceScreen` draws it
/// with the chat's `ChatTranscriptView`. A call runs one engine (Normal or GPT-Live) from
/// start to end; both write to this model the same way.
///
/// - Normal mode: `userSent` opens the turn with the user's words as its user row; gateway frames
///   build its reply as the chat's streaming turn does. When `message.complete` carries a receipt
///   for the whole turn (`persisted_turn`), the screen reads the newest rows again and `applySaved`
///   puts the saved rows in place of the turn, as `HermesChatTurnCoordinator.refreshHistory` does.
/// - GPT-Live: an exchange is the user's speech, the model's speech and its delegations to Hermes.
///   The dashboard saves none of the model's own words, so a finished exchange stays a local
///   turn for the rest of the call; a later call on the chat reads only what the server saved.
///   Any read of the newest rows (`loadHistory`, `applySaved`) drops the local turns too.
@MainActor @Observable final class VoiceTranscriptModel {
    enum Mode: String, CaseIterable { case full, current }

    /// The chat's saved rows, as REST pages bring them.
    private(set) var history = HermesTranscriptHistory()
    /// The saved rows as the chat draws them.
    private(set) var saved = HermesTranscriptProjection.Result()
    /// Finished turns the server has not saved: GPT-Live exchanges, and Normal turns that were
    /// interrupted or ended before their saved rows were read. Drawn after the saved rows.
    private(set) var localTurns: [VoiceTurn] = []
    /// The turn in flight; it stays after its end until the next turn or its saved rows.
    private(set) var live: VoiceTurn?
    /// The live user row is the recognizer's partial caption (no turn sent yet).
    private(set) var liveUserIsCaption = false
    /// The user's words while the user talks over a turn still in flight (shown under the
    /// transcript, they become the next turn's user row when sent).
    private(set) var pendingCaption: String?
    /// Bumped per applied event (the transcript's streaming scroll trigger).
    private(set) var liveRevision = 0
    /// Bumped whenever saved or local turns change (the transcript's relayout token).
    private(set) var settledRevision = 0
    private(set) var turnStartedAt: Date?
    var isLoadingHistory = false
    var hasOlder: Bool { history.hasOlder }

    /// Called when a Normal turn finished and its saved rows should be read (`applySaved`).
    var onTurnFinished: ((String) -> Void)?
    /// The rows the last finished Normal turn saved (`persisted_turn`); a read must hold them.
    private(set) var completedTurn: HermesChatTurnCoordinator.SavedTurn?

    private(set) var appendJournal = VoiceAppendJournal()
    private let now: () -> Date
    /// The projection root of the saved rows' ids (`<root>/row-<id>`).
    private let root: String
    private var runCounter = 0
    /// The user's words sent while a turn still ran: the user row of the next turn.
    private var queuedUserText: String?
    private var steerCounter = 0
    /// The run (exchange) that drew each card, by its stable id (a delegation, Hermes's tools).
    private var cardRuns: [String: String] = [:]

    static let localIDPrefix = "voice-local-"

    init(root: String = "voice", now: @escaping () -> Date = Date.init) {
        self.root = root
        self.now = now
    }

    // MARK: Read side

    /// The run the transcript treats as streaming: a live turn with no end yet.
    var activeRunID: String? {
        guard let live, live.ending == nil, !liveUserIsCaption else { return nil }
        return live.runID
    }
    var isEmpty: Bool { saved.messages.isEmpty && localTurns.isEmpty && live == nil }
    /// Start of the turn while it still runs (the chat's "Working for" row); nil after its end.
    /// GPT-Live exchanges have no "Working" row: the voice talks freely, and Hermes's work
    /// shows as its running delegation card.
    var workingSince: Date? {
        guard let live, live.ending == nil, !liveUserIsCaption, live.runID.hasPrefix("voice:") else { return nil }
        return turnStartedAt
    }
    /// The saved rows, then the local turns' user and reply rows: what was said so far.
    var messages: [ChatMessage] { saved.messages + localTurns.flatMap { $0.drawn(showsWork: false).rows } }
    var liveUserMessage: ChatMessage? { live?.user }

    struct Display: Equatable {
        var messages: [ChatMessage] = []
        /// Rows before `messages` in the full transcript, so render ids keep across modes.
        var offset = 0
        var toolCallGroups: [ToolCallGroup] = []
        var reasoningGroups: [ReasoningGroup] = []
        /// The turn in flight's cards and thinking, on its last reply row (`liveAnchor`).
        var liveTools: [ToolCall] = []
        var liveThinking = ""
        var liveAnchor: String?
        /// Rows that draw cards, kept even with no text of their own.
        var activityAnchors: Set<String> = []
    }

    private struct Block {
        let key: String
        var rows: [ChatMessage]
        var userRowID: Int?
        var groups: [ToolCallGroup] = []
        var reasoning: [ReasoningGroup] = []
        var live: VoiceTurn.Drawn?
    }

    /// What the transcript shows for a mode. `.current`: the turn in flight only, or the last
    /// turn when nothing is in flight.
    func display(_ mode: Mode, _ filter: TranscriptSegmentFilter = .all) -> Display {
        var blocks = savedBlocks() + localTurns.map { turn in
            let drawn = turn.drawn(showsWork: filter.thinkingAndTools)
            var block = Block(key: turn.key, rows: drawn.rows)
            if let anchor = drawn.anchor {
                if !drawn.tools.isEmpty { block.groups = [ToolCallGroup(id: "\(turn.key)/tools", anchorMessageID: anchor, toolCalls: drawn.tools)] }
                if !drawn.thinking.isEmpty { block.reasoning = [ReasoningGroup(id: "\(turn.key)/reasoning", anchorMessageID: anchor, text: drawn.thinking)] }
            }
            return block
        }
        if let live {
            let drawn = live.drawn(showsWork: filter.thinkingAndTools)
            blocks.append(Block(key: live.key, rows: drawn.rows, live: drawn))
        }
        let keys = blocks.map(\.key)
        let savedKeys = Dictionary(blocks.compactMap { b in b.userRowID.map { ($0, b.key) } }, uniquingKeysWith: { a, _ in a })
        let drawnKeys = Set(keys)
        let journal = appendJournal
        let home: (VoiceAppendJournal.Entry) -> String? = { journal.home($0, drawnKeys: drawnKeys) { savedKeys[$0] } }
        // Appends sent in an exchange no longer drawn go into the saved turn of their delegation.
        if filter.appends {
            for index in blocks.indices where blocks[index].userRowID != nil {
                blocks[index].rows = journal.weave(into: blocks[index].rows, key: blocks[index].key, home: home)
            }
        } else {
            for index in blocks.indices { blocks[index].rows.removeAll { $0.voiceAppend != nil } }
        }
        var shownRange = blocks.indices
        if mode == .current, let last = blocks.indices.last { shownRange = last..<blocks.endIndex }
        let window: VoiceAppendJournal.ExchangeWindow = mode == .full ? .all : .only(keys.last)
        let between = journal.project(turnKeys: keys, visibleTurnKeys: shownRange.map { keys[$0] },
                                      showsAppends: filter.appends, currentExchange: window, home: home,
                                      savedTurnKey: { savedKeys[$0] })
        var display = Display()
        display.messages = between.filter { $0.afterTurnKey == nil }.map { Self.appendRow($0.observation) }
        for index in blocks.indices {
            let block = blocks[index]
            let after = between.filter { $0.afterTurnKey == block.key }.map { Self.appendRow($0.observation) }
            guard shownRange.contains(index) else {
                display.offset += block.rows.count + after.count
                continue
            }
            display.messages += block.rows + after
            display.toolCallGroups += block.groups
            display.reasoningGroups += block.reasoning
            if let drawn = block.live {
                display.liveTools = drawn.tools
                display.liveThinking = drawn.thinking
                display.liveAnchor = drawn.anchor
            }
        }
        if !filter.thinkingAndTools { display.toolCallGroups = []; display.reasoningGroups = [] }
        display.activityAnchors = Set(display.toolCallGroups.compactMap(\.anchorMessageID)
            + display.reasoningGroups.compactMap(\.anchorMessageID))
        if let anchor = display.liveAnchor, !display.liveTools.isEmpty || !display.liveThinking.isEmpty {
            display.activityAnchors.insert(anchor)
        }
        return display
    }

    /// The saved rows as turns: each opens at a turn boundary (the chat's `isTurnBoundary`),
    /// with the cards anchored on its rows.
    private func savedBlocks() -> [Block] {
        var blocks: [Block] = []
        for message in saved.messages {
            if HermesTranscriptProjection.isTurnBoundary(message) || blocks.isEmpty {
                let isTurn = HermesTranscriptProjection.isTurnBoundary(message)
                let key = isTurn ? "msg:\(message.rowID ?? -1)" : "rows:\(message.rowID ?? -1)"
                blocks.append(Block(key: key, rows: [message], userRowID: isTurn ? message.rowID : nil))
            } else {
                blocks[blocks.count - 1].rows.append(message)
            }
        }
        guard !blocks.isEmpty else { return [] }
        for index in blocks.indices {
            let ids = Set(blocks[index].rows.compactMap(\.messageId))
            blocks[index].groups = saved.toolCallGroups.filter { $0.anchorMessageID.map(ids.contains) == true }
            blocks[index].reasoning = saved.reasoningGroups.filter { $0.anchorMessageID.map(ids.contains) == true }
        }
        blocks[blocks.count - 1].groups += saved.toolCallGroups.filter { $0.anchorMessageID == nil }
        blocks[blocks.count - 1].reasoning += saved.reasoningGroups.filter { $0.anchorMessageID == nil }
        return blocks
    }

    // MARK: Outgoing GPT-Live appends

    @discardableResult
    func recordAppend(_ observation: VoiceAppendObservation) -> VoiceAppendJournal.Entry {
        let entry: VoiceAppendJournal.Entry
        if let live, !liveUserIsCaption {
            entry = appendJournal.append(observation, inExchange: live.key, preceding: live.drawnIDs)
            self.live?.parts.append(.append(observation))
        } else {
            let last = savedBlocks().last
            let key = localTurns.last?.key ?? last?.key
            entry = appendJournal.append(observation, afterExchange: key,
                                         afterUserRow: localTurns.isEmpty ? last?.userRowID : nil)
        }
        liveRevision += 1
        return entry
    }

    /// Hermes saved a delegation's turn: the row ids from its `message.complete` receipt
    /// (`persisted_turn`). Appends sent from now on go after those rows, and once a refetch
    /// replaces the exchange's local turn, its appends go into the saved turn opened by `userRowID`.
    func delegationSaved(id: String, userRowID: Int?, rowIDs: [Int]) {
        appendJournal.saved(delegation: id, userRowID: userRowID, rowIDs: rowIDs)
    }

    // MARK: History

    /// The newest saved rows, read back from offset 0 (`HermesTranscriptHistory.mergeNewest`).
    /// The server's rows are the truth: local turns go, including GPT-Live exchanges the server
    /// never saved. The turn in flight (or the last one, ended) is kept.
    func loadHistory(_ rows: [BotJSON], reachedStart: Bool) {
        history.mergeNewest(rows, reachedStart: reachedStart)
        localTurns = []
        recompute()
    }

    /// An older page, put in front. Returns whether it added rows.
    @discardableResult
    func prependOlder(_ page: [BotJSON]) -> Bool {
        let added = history.prependOlder(page)
        recompute()
        return added
    }

    /// Whether newest rows read back from offset 0 reach the rows held (no hole between them).
    func reaches(_ rows: [BotJSON]) -> Bool { history.reaches(rows) }

    /// The finished Normal turn's saved rows were read: they replace it, as the chat's turn end
    /// does (`HermesChatTurnCoordinator.refreshHistory`). A result for an older run while a newer
    /// turn is in flight is ignored (its own end reads again). Returns false when the rows don't
    /// hold the turn's saved rows; the turn then stays a local turn.
    @discardableResult
    func applySaved(_ rows: [BotJSON], reachedStart: Bool, runID: String) -> Bool {
        if let live, live.runID != runID, live.ending == nil, !liveUserIsCaption { return true }
        var merged = history
        merged.mergeNewest(rows, reachedStart: reachedStart)
        if let turn = completedTurn {
            guard merged.holds(turn.replyRowID), turn.promptRowID.map(merged.holds) != false else { return false }
        }
        history = merged
        if live?.runID == runID {
            live = nil
            turnStartedAt = nil
        }
        localTurns = []
        recompute()
        return true
    }

    // MARK: Normal mode

    /// The user's words were sent to Hermes: they open the next turn as its user row.
    func userSent(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pendingCaption = nil
        if liveUserIsCaption, live != nil {
            // The caption the user watched while talking becomes the turn's user row in place.
            liveUserIsCaption = false
            live?.setUser(text)
            turnStartedAt = now()
            liveRevision += 1
            return
        }
        if let live, live.ending == nil {
            // A turn still runs (a steer or a rejected reply): the user's words open the next one.
            queuedUserText = queuedUserText.map { $0 + " " + text } ?? text
            return
        }
        finishLocally()
        begin(userText: text, prefix: "voice")
    }

    /// The recognizer's partial text while the user talks. With no turn in flight it is drawn as
    /// the next turn's user row right away (and stays: `userSent` keeps it in place).
    func hearing(_ partial: String) {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if live?.ending != nil { finishLocally() }
        if live == nil {
            begin(userText: text, prefix: "voice")
            liveUserIsCaption = true
            turnStartedAt = nil
            return
        }
        if liveUserIsCaption {
            live?.setUser(text)
            liveRevision += 1
        } else {
            pendingCaption = text
        }
    }

    /// The user's speech was noise, or its words went elsewhere (an approval answer, a stop
    /// phrase, a steer): the caption row goes away.
    func hearingEnded() {
        pendingCaption = nil
        guard liveUserIsCaption else { return }
        liveUserIsCaption = false
        live = nil
        turnStartedAt = nil
        liveRevision += 1
    }

    /// The user's words steered the running turn (called once the server took the steer): the
    /// chat's steer row inside it.
    func steered(_ text: String) {
        guard live?.ending == nil, live != nil, !liveUserIsCaption else { return }
        steerCounter += 1
        live?.parts.append(.steer(text, id: "\(Self.localIDPrefix)steer-\(steerCounter)"))
        liveRevision += 1
    }

    /// One dashboard frame of the session's turn (already filtered for rejected turns).
    func gatewayEvent(_ type: String, _ payload: BotJSON) {
        if type == "message.start" {
            if let live, live.ending == nil, !liveUserIsCaption { return }
            if liveUserIsCaption { hearingEnded() }
            finishLocally()
            let user = queuedUserText
            queuedUserText = nil
            begin(userText: user, prefix: "voice")
            return
        }
        guard Self.turnFrames.contains(type), !liveUserIsCaption else { return }
        if type == "message.complete" {
            guard let live, live.ending == nil else { return }
            complete(payload)
            return
        }
        if live?.ending != nil {
            // A new turn's frames after the last one ended (a server-started turn, no start seen).
            finishLocally()
        }
        if live == nil {
            // Frames of a turn whose start this screen missed (resume mid-turn).
            begin(userText: nil, prefix: "voice")
        }
        apply(type, payload)
    }

    private static let turnFrames: Set<String> = ["message.delta", "reasoning.delta", "message.interim",
                                                  "tool.start", "tool.complete", "message.complete"]

    /// `message.complete`: the turn's end. Its text is the reply when the deltas never carried
    /// it (the chat's `hermesTurnDidComplete`). Only a receipt for the whole turn
    /// (`persisted_turn`, as `HermesChatTurnCoordinator.complete` reads it) asks for its saved rows.
    private func complete(_ payload: BotJSON) {
        switch payload["status"].text {
        case "interrupted":
            live?.end(.interrupted)
        case "error":
            live?.end(.failed)
        default:
            if let reply = payload["text"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty,
               live?.replyText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(reply) != true {
                live?.interim(reply)
            }
            live?.end(.done)
        }
        liveRevision += 1
        guard let live, live.ending == .done else { return }
        let receipt = payload["persisted_turn"]
        if receipt["complete"].flag == true, let reply = receipt["final_assistant_row_id"].integer {
            completedTurn = HermesChatTurnCoordinator.SavedTurn(promptRowID: receipt["user_row_id"].integer, replyRowID: reply)
            onTurnFinished?(live.runID)
        } else {
            completedTurn = nil
            finishLocally()
        }
    }

    /// The reply was interrupted (barge-in, Tap to interrupt): the turn ends now, its text kept.
    func interrupt() {
        guard let live, live.ending == nil, !liveUserIsCaption else { return }
        self.live?.end(.interrupted)
        liveRevision += 1
    }

    // MARK: GPT-Live

    /// A piece of the user's speech. `startsSegment`: the user started talking again after a gap,
    /// which closes the previous exchange.
    func liveUserSpeech(_ piece: String, startsSegment: Bool) {
        guard !startsSegment, let user = live?.user else {
            finishLocally()
            begin(userText: piece, prefix: "live")
            return
        }
        live?.setUser((user.content ?? "") + piece)
        liveRevision += 1
    }

    /// A piece of the model's speech (its output transcript).
    func liveAssistantSpeech(_ piece: String) {
        guard !piece.isEmpty else { return }
        openExchangeIfNeeded()
        live?.text(piece)
        liveRevision += 1
    }

    /// GPT-Live handed a request to Hermes: one tool card named "Hermes" with the prompt.
    func delegationStarted(id: String, prompt: String?) {
        openExchangeIfNeeded()
        toolStarted(ToolStreamEvent(eventType: "tool.start", name: "Hermes", preview: prompt, args: nil,
                                    duration: nil, isError: nil, stableID: "delegation:\(id)"))
        liveRevision += 1
    }

    func delegationFinished(id: String, failed: Bool = false) {
        guard live != nil else { return }
        toolCompleted(ToolStreamEvent(eventType: "tool.complete", name: "Hermes", preview: nil, args: nil,
                                      duration: nil, isError: failed ? true : nil, stableID: "delegation:\(id)"))
        liveRevision += 1
    }

    /// Hermes's own work while a delegation runs, inside the exchange: tool cards, and its
    /// Thinking and interim text, as Normal mode takes them.
    func delegatedEvent(_ type: String, _ payload: BotJSON) {
        guard live != nil else { return }
        switch type {
        case "tool.start", "tool.complete", "reasoning.delta", "message.interim": apply(type, payload)
        default: return
        }
    }

    /// The exchange ended (the user's next utterance, Tap to interrupt, end of session).
    func finishExchange(interrupted: Bool = false) {
        guard live != nil else { return }
        if interrupted { interrupt() }
        finishLocally()
    }

    // MARK: Turns

    private func openExchangeIfNeeded() {
        if live == nil || live?.ending != nil { finishLocally(); begin(userText: nil, prefix: "live") }
    }

    private func begin(userText: String?, prefix: String) {
        liveUserIsCaption = false
        runCounter += 1
        let runID = "\(prefix):\(runCounter)"
        live = VoiceTurn(runID: runID, startedAt: now().timeIntervalSince1970)
        if let userText { live?.setUser(userText) }
        turnStartedAt = now()
        liveRevision += 1
    }

    /// One gateway frame of the turn in flight, as the chat's stream delegate takes it
    /// (`HermesChatTurnCoordinator.apply`).
    private func apply(_ type: String, _ payload: BotJSON) {
        switch type {
        case "message.delta":
            guard let text = payload["text"].text, !text.isEmpty else { return }
            live?.text(text)
        case "reasoning.delta":
            guard let text = payload["text"].text, !text.isEmpty else { return }
            live?.thinking(text)
        case "message.interim":
            guard payload["already_streamed"].flag != true,
                  let text = payload["text"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            live?.interim(text)
        case "tool.start":
            toolStarted(Self.toolEvent(payload, eventType: type))
        case "tool.complete":
            toolCompleted(Self.toolEvent(payload, eventType: type))
        default:
            return
        }
        liveRevision += 1
    }

    /// A card is the exchange's that drew it. Its completion can arrive after that exchange
    /// ended (the user spoke again, a newer request): the ended exchange closed it
    /// (`finishLocally`), so the newer exchange gets nothing.
    private func ownsCard(_ event: ToolStreamEvent) -> Bool {
        guard let id = event.stableID, let runID = live?.runID else { return live != nil }
        if let owner = cardRuns[id], owner != runID { return false }
        cardRuns[id] = runID
        return true
    }

    private func toolStarted(_ event: ToolStreamEvent) {
        guard ownsCard(event) else { return }
        live?.toolStarted(event)
    }

    private func toolCompleted(_ event: ToolStreamEvent) {
        guard ownsCard(event) else { return }
        live?.toolCompleted(event)
    }

    private static func toolEvent(_ payload: BotJSON, eventType: String) -> ToolStreamEvent {
        let preview = [payload["context"].text, payload["preview"].text, payload["summary"].text]
            .compactMap { $0 }.first { !$0.isEmpty }
        return ToolStreamEvent(
            eventType: eventType,
            name: payload["name"].text,
            preview: eventType == "tool.start" ? preview : nil,
            args: payload["args"].argumentDictionary,
            duration: payload["duration_s"].number,
            isError: payload["is_error"].flag ?? (payload["error"].text?.isEmpty == false ? true : nil),
            stableID: payload["tool_id"].text.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Ends the turn in flight as a local turn (GPT-Live exchanges, interrupted turns, a turn
    /// still unsettled when the next turn begins). It keeps its rows and their ids; a later read
    /// of the saved rows replaces it.
    func finishLocally() {
        if liveUserIsCaption { hearingEnded(); return }
        guard var turn = live else { return }
        if turn.ending == nil { turn.end(.done) }
        live = nil
        turnStartedAt = nil
        if !turn.isEmpty { localTurns.append(turn) }
        recompute()
        liveRevision += 1
    }

    private func recompute() {
        saved = HermesTranscriptProjection.project(history.rows, root: root)
        settledRevision += 1
    }

    nonisolated static func appendRow(_ append: VoiceAppendObservation) -> ChatMessage {
        var message = ChatMessage(role: "local_notice", content: append.rawJSON, timestamp: nil, messageId: append.id)
        message.voiceAppend = append
        return message
    }
}

/// One voice turn the server has not saved: what the chat's stream delegate builds for a
/// streaming turn (its streaming reply, `liveToolCalls`, `liveReasoningText`), with the reply's
/// text cut into rows where the voice's own appends and steers, a tool or Thinking sit between
/// its words, so each row stays where it was first drawn.
struct VoiceTurn: Equatable {
    enum Ending: Equatable { case done, interrupted, failed }
    enum Part: Equatable {
        case text(String)
        case thinking(String)
        case tool(String)
        case steer(String, id: String)
        case append(VoiceAppendObservation)
    }

    let runID: String
    let startedAt: Double
    private(set) var user: ChatMessage?
    var parts: [Part] = []
    private(set) var tools: [ToolCall] = []
    private(set) var ending: Ending?

    init(runID: String, startedAt: Double) {
        self.runID = runID
        self.startedAt = startedAt
    }

    var key: String { "run:\(runID)" }
    var isEmpty: Bool { user == nil && parts.isEmpty }
    private var idPrefix: String { "\(VoiceTranscriptModel.localIDPrefix)\(runID)" }

    /// The reply's text so far.
    var replyText: String {
        parts.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
    }

    mutating func setUser(_ text: String) {
        user = ChatMessage(role: "user", content: text, timestamp: user?.timestamp ?? startedAt, messageId: "\(idPrefix)-user")
    }

    mutating func text(_ text: String) {
        if case .text(let shown) = parts.last { parts[parts.count - 1] = .text(shown + text) } else { parts.append(.text(text)) }
    }

    /// A reply the deltas never carried: it joins the last row the way the chat joins an
    /// interim reply (`appendInterimAssistant`).
    mutating func interim(_ text: String) {
        if case .text(let shown) = parts.last {
            let separator = shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
            parts[parts.count - 1] = .text(shown + separator + text)
        } else {
            parts.append(.text(text))
        }
    }

    mutating func thinking(_ text: String) {
        if case .thinking(let shown) = parts.last { parts[parts.count - 1] = .thinking(shown + text) } else { parts.append(.thinking(text)) }
    }

    mutating func toolStarted(_ event: ToolStreamEvent) {
        let id = event.stableID ?? "\(idPrefix)-tool-\(tools.count)"
        tools.append(ToolCall(id: id, name: event.name, preview: event.preview, args: event.args, startedAt: startedAt))
        parts.append(.tool(id))
    }

    /// As the chat's `completeToolCall`: the running call with the same id, else the last
    /// running call of the same name, else a finished card of its own.
    mutating func toolCompleted(_ event: ToolStreamEvent) {
        let index = event.stableID.flatMap { id in tools.lastIndex { $0.id == id } }
            ?? tools.lastIndex { !$0.isCompleted && (event.name == nil || $0.name == event.name) }
        if let index {
            tools[index] = tools[index].applyingCompletionPayload(event)
            return
        }
        let id = event.stableID ?? "\(idPrefix)-tool-\(tools.count)"
        tools.append(ToolCall(id: id, name: event.name, preview: event.preview, args: event.args, duration: event.duration,
                              isError: event.isError, isCompleted: true, startedAt: startedAt))
        parts.append(.tool(id))
    }

    /// The turn ended; a card still running then is over.
    mutating func end(_ ending: Ending) {
        guard self.ending == nil else { return }
        self.ending = ending
        for index in tools.indices where !tools[index].isCompleted { tools[index].isCompleted = true }
    }

    /// The ids drawn so far, in order: rows, and each card as `tool:<id>`.
    var drawnIDs: [String] {
        parts.indices.compactMap { index in
            switch parts[index] {
            case .text: return "\(idPrefix)-\(index)"
            case .tool(let id): return "tool:\(id)"
            case .steer(_, let id): return id
            case .append(let observation): return observation.id
            case .thinking: return nil
            }
        }
    }

    struct Drawn: Equatable {
        var rows: [ChatMessage]
        var tools: [ToolCall]
        var thinking: String
        /// The row the cards and thinking draw on: the last reply row.
        var anchor: String?
    }

    /// The turn as chat rows: its user row, one reply row per run of text, the steers and appends
    /// between them; its cards and thinking on its last reply row (an empty one when it has no
    /// text yet). `showsWork` false draws no cards, so no empty row either.
    func drawn(showsWork: Bool) -> Drawn {
        var rows = user.map { [$0] } ?? []
        var thoughts: [String] = []
        var anchor: String?
        for (index, part) in parts.enumerated() {
            switch part {
            case .text(let text):
                let id = "\(idPrefix)-\(index)"
                rows.append(ChatMessage(role: "assistant", content: text, timestamp: startedAt, messageId: id))
                anchor = id
            case .thinking(let text):
                thoughts.append(text)
            case .tool:
                break
            case .steer(let text, let id):
                rows.append(ChatMessage(role: "user", content: text, timestamp: startedAt, messageId: id,
                                        displayKind: ChatMessage.steerDisplayKind))
            case .append(let observation):
                rows.append(VoiceTranscriptModel.appendRow(observation))
            }
        }
        let thinking = thoughts.joined(separator: "\n\n")
        guard showsWork, !tools.isEmpty || !thinking.isEmpty else { return Drawn(rows: rows, tools: [], thinking: "", anchor: anchor) }
        if anchor == nil {
            let id = "\(idPrefix)-work"
            rows.append(ChatMessage(role: "assistant", content: "", timestamp: startedAt, messageId: id))
            anchor = id
        }
        return Drawn(rows: rows, tools: tools, thinking: thinking, anchor: anchor)
    }
}
