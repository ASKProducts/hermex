import Foundation
import Observation

/// dashboard, the turns built from them, the turn in flight (`ChatTurnLiveFold`) and the
/// user's own words for it. `VoiceScreen` draws it with the chat's `ChatTranscriptView`;
/// both engines (Normal, GPT-Live) write to the same model, so it survives a mode switch.
///
/// - Normal mode: `userSent` opens the turn with the user's words as its user row; gateway frames
///   go through `VoiceTurnMapper` into the fold; at `message.complete` the screen refetches
///   the chat's saved rows and `applySaved` settles the fold onto them (the chat's
///   `ChatTurnSettle`, so rows keep their identity).
/// - GPT-Live: an exchange is the user's speech, the model's speech and its delegations to Hermes.
///   The dashboard saves none of the model's own words, so a finished exchange becomes
///   LOCAL rows (`localRows`, kept here only) until a refetch at a mode switch or reopen
///   replaces them with what the server saved.
@MainActor @Observable final class VoiceTranscriptModel {
    enum Mode: String, CaseIterable { case full, current }

    /// Saved rows (server ids) plus, at the end, local rows of finished GPT-Live exchanges.
    private(set) var messages: [ChatMessage] = []
    /// Row indices are relative to the loaded window: an older page re-indexes every turn
    /// (turns keep their keys, which come from server ids), so the offset is always 0.
    let messagesOffset = 0
    private(set) var settledTurns: [ChatTurn] = []
    /// Bumped whenever `settledTurns` change (the transcript's settled-items cache key).
    private(set) var settledRevision = 0
    private(set) var fold: ChatTurnLiveFold?
    /// The user's words for the turn in flight: live while the user talks, then the turn's user row.
    private(set) var liveUserMessage: ChatMessage?
    /// Bumped per applied event (the transcript's streaming scroll trigger).
    private(set) var liveRevision = 0
    private(set) var turnStartedAt: Date?
    private(set) var hasOlder = false
    var isLoadingHistory = false

    /// Called when a Normal turn finished and its saved rows should be fetched (`applySaved`).
    var onTurnFinished: ((String) -> Void)?

    private let now: () -> Date
    private var runCounter = 0
    private var replyStreamed = false
    /// The user's words sent while a turn still ran: the user row of the next turn.
    private var queuedUserText: String?
    /// The live user row is the recognizer's partial caption (no turn sent yet).
    private var liveUserIsCaption = false
    private var steerCounter = 0
    /// The run (exchange) that drew each card, by its stable id (a delegation, Hermes's tools).
    private var cardRuns: [String: String] = [:]
    /// A finished Normal turn drawn as local rows while its saved rows are fetched (the next
    /// turn began first): `applySaved` still settles it, so its rows keep their identity.
    private var awaitingSaved: ChatTurnLiveFold?
    private var awaitingUserText: String?
    /// Every Normal turn drawn as local rows (interrupted, or ended before its saved rows were
    /// fetched), with its user words: the next refetch pairs each with its saved turn, as the
    /// chat pairs a settled turn by saved ids (`ChatViewModel.recordSettle`), so those rows keep
    /// the ids they were drawn under. Their local aliases are positional and are dropped then.
    private var locallyDrawn: [(fold: ChatTurnLiveFold, user: String)] = []
    private var drawnSegmentIDs: [ChatTurnSegmentID: ChatTurnSegmentID] = [:]
    private var drawnTurnKeys: [String: String] = [:]
    /// User words of turns that were cut off. The dashboard saves no "partial" mark, so the
    /// reply row of such a turn is marked here (`isPartial`), every time rows are loaded:
    /// the chat's footer then says "Interrupted" (CHAT-REQUEST R2).
    private var interruptedUserTexts: [String] = []

    static let localIDPrefix = "voice-local-"

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    // MARK: Read side (what the transcript draws)

    /// The live turn as drawn: aliased ids are not needed (a fold's own ids are stable).
    var liveTurn: ChatTurn? { fold?.turn }
    /// The run the transcript treats as streaming: only a fold with no terminal yet.
    var activeRunID: String? {
        guard let fold, fold.terminal == nil, !liveUserIsCaption else { return nil }
        return fold.runID
    }
    var isEmpty: Bool { messages.isEmpty && fold == nil && liveUserMessage == nil }
    /// Start of the turn while it still runs (the chat's "Working for" row); nil after its end.
    /// GPT-Live exchanges have no "Working" row: the voice talks freely, and Hermes's work
    /// shows as its running delegation card.
    var workingSince: Date? {
        guard let fold, fold.terminal == nil, !liveUserIsCaption, fold.runID.hasPrefix("voice:") else { return nil }
        return turnStartedAt
    }
    /// The user's words while the user talks over a turn still in flight (shown under the transcript,
    /// they become the next turn's user row when sent).
    private(set) var pendingCaption: String?

    /// What the transcript shows for a mode. `.current`: the turn in flight only, or the
    /// last settled turn when nothing is in flight; the rows are a slice and the offset
    /// moves with it, so every turn's `rows` / `userRowIndex` still index `messages`.
    struct Display: Equatable {
        var messages: [ChatMessage]
        var offset: Int
        var turns: [ChatTurn]
    }

    func display(_ mode: Mode) -> Display {
        guard mode == .current else { return Display(messages: messages, offset: messagesOffset, turns: settledTurns) }
        if fold != nil || liveUserMessage != nil { return Display(messages: [], offset: messagesOffset + messages.count, turns: []) }
        guard let last = settledTurns.last, let rows = last.rows else {
            return Display(messages: messages, offset: messagesOffset, turns: settledTurns)
        }
        let start = rows.lowerBound - messagesOffset
        guard messages.indices.contains(start) else { return Display(messages: messages, offset: messagesOffset, turns: settledTurns) }
        return Display(messages: Array(messages[start...]), offset: rows.lowerBound, turns: [last])
    }

    /// Outgoing GPT-Live appends, kept apart from messages, speech folds and the archive.
    private(set) var appendJournal = VoiceAppendJournal()

    // MARK: Outgoing GPT-Live appends

    /// One append the app handed to the transport. Sent during an exchange on screen, it is the
    /// next entry of that exchange's fold, after whatever the fold holds now (speech, the
    /// delegation card, Hermes's rows), and keeps that place once the exchange settles.
    /// Sent with no exchange on screen, it is drawn between turns, after the last one.
    /// Returns the journal entry (what the archive records).
    @discardableResult
    func recordAppend(_ observation: VoiceAppendObservation) -> VoiceAppendJournal.Entry {
        let entry: VoiceAppendJournal.Entry
        if fold != nil, !liveUserIsCaption, let live = liveTurn {
            entry = appendJournal.append(observation, inExchange: TranscriptItems.turnKey(live),
                                         preceding: live.segments.map(\.id))
            fold?.appendSent(observation)
        } else {
            entry = appendJournal.append(observation, afterExchange: settledTurns.last.map(TranscriptItems.turnKey),
                                         afterUserRow: settledTurns.last?.userMessageID)
        }
        liveRevision += 1
        return entry
    }

    /// The appends drawn between turns for `mode` (those sent with no exchange on screen, or
    /// that no drawn turn holds), each after the turn it was sent after; none when Activity is
    /// off (they are still recorded). Appends a drawn turn holds are its segments (`appendHome`).
    func appendEvents(_ mode: Mode, showsAppends: Bool) -> [VoiceAppendJournal.Projection] {
        let liveKeys = liveTurn.map { [TranscriptItems.turnKey($0)] } ?? []
        let allKeys = settledTurns.map(TranscriptItems.turnKey) + liveKeys
        let visibleKeys = display(mode).turns.map(TranscriptItems.turnKey) + liveKeys
        let window: VoiceAppendJournal.ExchangeWindow = mode == .full ? .all : .only(allKeys.last)
        let home = appendHome(turns: settledTurns)
        let savedKeys = savedTurnKeys(settledTurns)
        return appendJournal.project(turnKeys: allKeys, visibleTurnKeys: visibleKeys, showsAppends: showsAppends,
                                     aliases: drawnTurnKeys, currentExchange: window, home: home,
                                     savedTurnKey: { savedKeys[$0] })
    }

    /// Hermes saved a delegation's turn: the row ids from its `message.complete` receipt
    /// (`persisted_turn`). Appends sent from now on go after those rows, and once a refetch
    /// replaces the exchange's local rows, its appends live in the saved turn opened by
    /// `userRowID`.
    func delegationSaved(id: String, userRowID: Int?, rowIDs: [Int]) {
        appendJournal.saved(delegation: id, userRowID: userRowID, rowIDs: rowIDs)
    }

    /// A voice screen opened on a chat: the appends its voice archive holds from earlier calls
    /// (`VoiceAppendJournal(restoring:)`), before anything of this screen's.


    /// Which drawn turn holds each append (`VoiceAppendJournal.home`): its exchange while that
    /// is drawn (settled `turns` or the live one), else the saved turn of its delegation.
    private func appendHome(turns: [ChatTurn]) -> (VoiceAppendJournal.Entry) -> String? {
        var drawnKeys = Set(turns.map(TranscriptItems.turnKey))
        if let live = liveTurn { drawnKeys.insert(TranscriptItems.turnKey(live)) }
        let savedKeys = savedTurnKeys(turns)
        let journal = appendJournal
        return { entry in journal.home(entry, drawnKeys: drawnKeys) { savedKeys[$0] } }
    }

    /// The key of each saved turn, by its saved user row id.
    private func savedTurnKeys(_ turns: [ChatTurn]) -> [Int: String] {
        var keys: [Int: String] = [:]
        for turn in turns { if let id = turn.userMessageID { keys[id] = TranscriptItems.turnKey(turn) } }
        return keys
    }

    // MARK: History

    /// Saved rows of the chat (Continue by voice, or after a refetch). Local rows are dropped:
    /// the server's rows are the truth. A fold in flight is kept.
    func loadHistory(_ rows: [ChatMessage], hasOlder: Bool) {
        messages = Self.markingInterrupted(rows, userTexts: interruptedUserTexts)
        forgetPositionalDrawing()
        self.hasOlder = hasOlder
        recompute()
    }

    /// An older page, prepended.
    func prependOlder(_ rows: [ChatMessage], hasOlder: Bool) {
        guard !rows.isEmpty else { self.hasOlder = hasOlder; return }
        messages = Self.markingInterrupted(rows, userTexts: interruptedUserTexts) + messages
        forgetPositionalDrawing()
        self.hasOlder = hasOlder
        recompute()
    }

    /// The finished Normal turn's saved rows arrived: settle the fold onto them. A result
    /// for an older run while a newer turn is in flight is ignored (its own end refetches).
    /// Returns false when the rows don't hold the turn yet (saved after its `message.complete`
    /// arrived); the caller retries, and finally keeps the turn as local rows (`finishLocally`).
    @discardableResult
    func applySaved(_ rows: [ChatMessage], hasOlder: Bool, runID: String, receipt: HermesTurnReceipt? = nil) -> Bool {
        if let fold, fold.runID != runID, fold.terminal == nil, !liveUserIsCaption { return true }
        let target: (fold: ChatTurnLiveFold, user: String?)?
        if let waiting = awaitingSaved, waiting.runID == runID {
            target = (waiting, awaitingUserText)
        } else if let fold, fold.runID == runID {
            target = (fold, liveUserMessage?.content)
        } else {
            target = nil
        }
        if let target {
            guard Self.rows(rows, holdTurnFrom: target.user) else { return false }
            if let settle = ChatTurnSettle.settle(target.fold, savedMessages: rows, receipt: receipt) {
                record(settle, itemKey: "run:\(runID)")
            }
            if awaitingSaved?.runID == runID { awaitingSaved = nil; awaitingUserText = nil }
            if fold?.runID == runID {
                fold = nil
                liveUserMessage = nil
                turnStartedAt = nil
            }
        }
        settleLocallyDrawn(onto: rows)
        loadHistory(rows, hasOlder: hasOlder)
        return true
    }

    /// Pairs each locally drawn turn with its saved turn (latest one opened by the same user
    /// words), drawing the saved rows under the local rows' ids and key.
    private func settleLocallyDrawn(onto rows: [ChatMessage]) {
        guard !locallyDrawn.isEmpty else { return }
        let saved = ChatTurn.turns(from: rows, firstIndex: messagesOffset)
        func words(_ s: String?) -> String { s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        locallyDrawn.removeAll { local in
            guard let turn = saved.last(where: { turn in
                guard let index = turn.userRowIndex, rows.indices.contains(index - messagesOffset) else { return false }
                return words(rows[index - messagesOffset].content) == words(local.user)
            }) else { return false }
            record(ChatTurnSettle.settle(live: local.fold.turn, onto: turn), itemKey: "run:\(local.fold.runID)",
                   settledKey: TranscriptItems.turnKey(turn))
            return true
        }
    }

    /// The saved rows end with this turn: its user words are the last saved user row's.
    static func rows(_ rows: [ChatMessage], holdTurnFrom userText: String?) -> Bool {
        guard let userText = userText?.trimmingCharacters(in: .whitespacesAndNewlines), !userText.isEmpty else { return true }
        guard let last = rows.last(where: { $0.role == "user" && $0.serverID != nil && !$0.isSteerMessage }) else { return false }
        return last.content?.trimmingCharacters(in: .whitespacesAndNewlines) == userText
    }

    // MARK: Normal mode

    /// The user's words were sent to Hermes: they open the next turn as its user row.
    func userSent(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pendingCaption = nil
        if liveUserIsCaption, fold != nil {
            // The caption the user watched while talking becomes the turn's user row in place.
            liveUserIsCaption = false
            liveUserMessage = Self.userRow(text: text, id: liveUserMessage?.messageId, at: liveUserMessage?.timestamp)
            turnStartedAt = now()
            liveRevision += 1
            return
        }
        if let fold, fold.terminal == nil {
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
        if fold?.terminal != nil || (fold == nil && liveUserMessage != nil && !liveUserIsCaption) { finishLocally() }
        if fold == nil {
            begin(userText: text, prefix: "voice")
            liveUserIsCaption = true
            turnStartedAt = nil
            return
        }
        if liveUserIsCaption {
            liveUserMessage = Self.userRow(text: text, id: liveUserMessage?.messageId, at: liveUserMessage?.timestamp)
            liveRevision += 1
        } else {
            pendingCaption = text
        }
    }

    /// The user's speech was noise, or its words went elsewhere (an approval answer, a stop phrase, a
    /// steer): the caption row goes away.
    func hearingEnded() {
        pendingCaption = nil
        guard liveUserIsCaption else { return }
        liveUserIsCaption = false
        fold = nil
        liveUserMessage = nil
        turnStartedAt = nil
        liveRevision += 1
    }

    /// The user's words steered the running turn (called once the server took the steer): the
    /// chat's steer row inside it, drawn as delivered (as `appendLocalSteerEcho`).
    func steered(_ text: String) {
        guard fold?.terminal == nil, fold != nil, !liveUserIsCaption else { return }
        steerCounter += 1
        fold?.appendSteer(text, localID: "voice-\(steerCounter)")
        liveRevision += 1
    }

    /// One dashboard frame of the session's turn (already filtered for rejected turns).
    private(set) var completedReceipt: HermesTurnReceipt?

    func gatewayEvent(_ type: String, _ payload: BotJSON) {
        if type == "message.start" {
            if let fold, fold.terminal == nil, !liveUserIsCaption { return }
            if liveUserIsCaption { hearingEnded() }
            finishLocally()
            let user = queuedUserText
            queuedUserText = nil
            begin(userText: user, prefix: "voice")
            return
        }
        let events = VoiceTurnMapper.events(type: type, payload: payload, streamedReply: replyStreamed)
        guard !events.isEmpty, !liveUserIsCaption else { return }
        if fold?.terminal != nil, type != "message.complete" {
            // A new turn's frames after the last one ended (a server-started turn, no start seen).
            finishLocally()
        }
        if fold == nil {
            // Frames of a turn whose start this screen missed (resume mid-turn).
            begin(userText: nil, prefix: "voice")
        }
        apply(events)
        if type == "message.complete", let fold, fold.terminal == .done {
            completedReceipt = HermesTurnReceipt(messageComplete: payload)
            if completedReceipt?.complete == true { onTurnFinished?(fold.runID) }
            else { finishLocally() }
        }
    }

    /// The reply was interrupted (barge-in, Tap to interrupt): the turn ends now, its text kept.
    func interrupt() {
        guard let fold, fold.terminal == nil, !liveUserIsCaption else { return }
        apply([.cancelled])
    }

    // MARK: GPT-Live

    /// A piece of the user's speech. `startsSegment`: the user started talking again after a gap, which
    /// closes the previous exchange.
    func liveUserSpeech(_ piece: String, startsSegment: Bool) {
        if startsSegment || liveUserMessage == nil {
            finishLocally()
            begin(userText: piece, prefix: "live")
            return
        }
        guard let user = liveUserMessage else { return }
        liveUserMessage = Self.userRow(text: (user.content ?? "") + piece, id: user.messageId, at: user.timestamp)
        liveRevision += 1
    }

    /// A piece of the model's speech (its output transcript).
    func liveAssistantSpeech(_ piece: String) {
        guard !piece.isEmpty else { return }
        if fold == nil || fold?.terminal != nil { finishLocally(); begin(userText: nil, prefix: "live") }
        apply([.token(piece)])
    }

    /// GPT-Live handed a request to Hermes: one tool card named "Hermes" with the prompt.
    func delegationStarted(id: String, prompt: String?) {
        if fold == nil || fold?.terminal != nil { finishLocally(); begin(userText: nil, prefix: "live") }
        apply([.toolStarted(ToolStreamEvent(eventType: "tool.start", name: "Hermes", preview: prompt, args: nil,
                                            duration: nil, isError: nil, stableID: "delegation:\(id)"))])
    }

    func delegationFinished(id: String, failed: Bool = false) {
        guard fold != nil else { return }
        apply([.toolCompleted(ToolStreamEvent(eventType: "tool.complete", name: "Hermes", preview: nil, args: nil,
                                              duration: nil, isError: failed ? true : nil, stableID: "delegation:\(id)"))])
    }

    /// Hermes's own work while a delegation runs, inside the exchange: tool cards, and its
    /// Thinking and interim text, as Normal mode passes them (`VoiceSession`'s gateway switch).
    func delegatedEvent(_ type: String, _ payload: BotJSON) {
        guard fold != nil else { return }
        switch type {
        case "tool.start", "tool.complete", "reasoning.delta", "message.interim":
            apply(VoiceTurnMapper.events(type: type, payload: payload, streamedReply: true))
        default: return
        }
    }

    /// The exchange ended (the user's next utterance, Tap to interrupt, end of session).
    func finishExchange(interrupted: Bool = false) {
        guard fold != nil || liveUserMessage != nil else { return }
        if interrupted { interrupt() }
        finishLocally()
    }

    // MARK: Turns

    private func begin(userText: String?, prefix: String) {
        liveUserIsCaption = false
        runCounter += 1
        let runID = "\(prefix):\(runCounter)"
        fold = ChatTurnLiveFold(runID: runID)
        replyStreamed = false
        turnStartedAt = now()
        liveUserMessage = userText.map {
            Self.userRow(text: $0, id: "\(Self.localIDPrefix)\(runID)-user", at: now().timeIntervalSince1970)
        }
        liveRevision += 1
    }

    private func apply(_ events: [SSEEvent]) {
        guard let runID = fold?.runID else { return }
        for event in events {
            if case .token = event { replyStreamed = true }
            if let card = Self.cardID(event) {
                // A card is the exchange's that drew it. Its completion can arrive after that
                // exchange ended (the user spoke again, a newer request): the ended exchange's rows
                // already closed it (`finishLocally`), so the newer exchange gets nothing.
                if let owner = cardRuns[card], owner != runID { continue }
                cardRuns[card] = runID
            }
            fold?.apply(seq: nil, event: event)
        }
        liveRevision += 1
    }

    private static func cardID(_ event: SSEEvent) -> String? {
        switch event {
        case .toolStarted(let tool), .toolCompleted(let tool): return tool.stableID
        default: return nil
        }
    }

    /// Ends the turn in flight as local rows (GPT-Live exchanges, interrupted turns, a fold
    /// still unsettled when the next turn begins). The rows are drawn under the live turn's
    /// ids and key, so nothing redraws; a later refetch replaces them with the server's rows.
    func finishLocally() {
        if liveUserIsCaption { hearingEnded(); return }
        guard fold != nil || liveUserMessage != nil else { return }
        if fold?.terminal == nil { fold?.apply(seq: nil, event: .done(DoneStreamEvent())) }
        let wasInterrupted: Bool = { if case .interrupted = fold?.turn.state { return true }; return false }()
        if wasInterrupted, let user = liveUserMessage?.content?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            interruptedUserTexts.append(user)
        }
        if let fold, fold.runID.hasPrefix("voice:") {
            awaitingSaved = fold; awaitingUserText = liveUserMessage?.content
            if let user = liveUserMessage?.content { locallyDrawn.append((fold, user)) }
        }
        let live = fold?.turn
        let runID = fold?.runID ?? "voice:\(runCounter)"
        var rows = Self.localRows(user: liveUserMessage, turn: live, runID: runID, at: now().timeIntervalSince1970)
        if wasInterrupted, let last = rows.lastIndex(where: { $0.role == "assistant" }) { rows[last].isPartial = true }
        fold = nil
        liveUserMessage = nil
        turnStartedAt = nil
        guard !rows.isEmpty else { recompute(); return }
        let firstRow = messages.count
        messages += rows
        let turns = ChatTurn.turns(from: messages, firstIndex: messagesOffset)
        if let live, let index = turns.lastIndex(where: { ($0.rows?.lowerBound ?? -1) == messagesOffset + firstRow }) {
            record(ChatTurnSettle.settle(live: live, onto: turns[index]), itemKey: "run:\(runID)",
                   settledKey: TranscriptItems.turnKey(turns[index]))
        }
        recompute()
    }

    private func record(_ settle: ChatTurnSettle, itemKey: String, settledKey: String? = nil) {
        for (settled, drawn) in settle.idAlias() { drawnSegmentIDs[settled] = drawn }
        drawnTurnKeys[settledKey ?? TranscriptItems.turnKey(settle.turn)] = itemKey
    }

    /// Rows without server ids are keyed by position; once rows move (a page, a refetch)
    /// those keys name other rows, so their drawn aliases are dropped.
    private func forgetPositionalDrawing() {
        drawnTurnKeys = drawnTurnKeys.filter { !$0.key.hasPrefix("pos:") }
        drawnSegmentIDs = drawnSegmentIDs.filter { !$0.key.rawValue.hasPrefix("pos:") }
    }

    private func recompute() {
        var turns = ChatTurn.turns(from: messages, firstIndex: messagesOffset)
        if !drawnSegmentIDs.isEmpty || !drawnTurnKeys.isEmpty {
            turns = turns.map { $0.drawn(idAlias: drawnSegmentIDs, itemKey: drawnTurnKeys[TranscriptItems.turnKey($0)]) }
        }
        // Each drawn turn gets back the appends it holds: a finished exchange drawn under its
        // live ids, or (after a refetch) the saved turn of the appends' delegation.
        if appendJournal.entries.contains(where: \.placedInExchange) {
            let home = appendHome(turns: turns)
            turns = turns.map { appendJournal.weave(into: $0, key: TranscriptItems.turnKey($0), home: home) }
        }
        settledTurns = turns
        settledRevision += 1
    }

    // MARK: Rows

    /// Marks the last assistant row of each turn whose user words were cut off (latest match
    /// per text, newest first) as partial.
    static func markingInterrupted(_ rows: [ChatMessage], userTexts: [String]) -> [ChatMessage] {
        guard !userTexts.isEmpty else { return rows }
        var rows = rows
        var used = Set<Int>()
        for text in userTexts.reversed() {
            guard let u = rows.indices.last(where: { i in
                !used.contains(i) && rows[i].role == "user"
                    && rows[i].content?.trimmingCharacters(in: .whitespacesAndNewlines) == text
            }) else { continue }
            used.insert(u)
            let end = rows[(u + 1)...].firstIndex(where: { $0.role == "user" }) ?? rows.endIndex
            if let reply = rows[(u + 1)..<end].lastIndex(where: { $0.role == "assistant" }) { rows[reply].isPartial = true }
        }
        return rows
    }

    static func userRow(text: String, id: String?, at timestamp: Double?) -> ChatMessage {
        ChatMessage(role: "user", content: text, timestamp: timestamp, messageId: id)
    }

    /// A finished turn as chat rows, the way the server saves one: the user's words, then per step an
    /// assistant row (its thinking, text and tool calls, in that order, as the server saves a
    /// step) followed by one `tool` row per call, and a last assistant row for text after the
    /// last tool. No server ids: `ChatTurn.turns` keys them by position.
    static func localRows(user: ChatMessage?, turn: ChatTurn?, runID: String, at timestamp: Double) -> [ChatMessage] {
        var rows: [ChatMessage] = []
        if let user { rows.append(user) }
        guard let turn, !turn.segments.isEmpty else { return rows }
        var text = "", thinking = ""
        var calls: [JSONValue] = []
        var results: [ChatMessage] = []
        var step = 0
        func flush() {
            guard !text.isEmpty || !thinking.isEmpty || !calls.isEmpty else { return }
            rows.append(ChatMessage(role: "assistant", content: text, timestamp: timestamp,
                                    messageId: "\(localIDPrefix)\(runID)-step-\(step)",
                                    toolCalls: calls.isEmpty ? nil : calls,
                                    reasoning: thinking.isEmpty ? nil : thinking))
            rows += results
            step += 1
            text = ""; thinking = ""; calls = []; results = []
        }
        for segment in turn.segments {
            switch segment.kind {
            case .text(let t):
                if !calls.isEmpty { flush() }
                text += t.string
            case .thinking(let t):
                // A saved row draws its reasoning above its text and calls: thinking after
                // either opens the next row, so the rows keep the live order.
                if !calls.isEmpty || !text.isEmpty { flush() }
                thinking += t.string
            case .steer, .delegationCompletion: break // saved-only reports never enter this live fold
            case .append:
                // Not a row. The speech either side of it stays two rows, so the settled turn
                // keeps the two text segments the append sits between (`VoiceAppendJournal.weave`).
                flush()
            case .tool(let tool):
                var function: [String: JSONValue] = ["name": .string(tool.name)]
                if let args = tool.args, let data = try? JSONEncoder().encode(JSONValue.object(args)),
                   let json = String(data: data, encoding: .utf8) {
                    function["arguments"] = .string(json)
                }
                calls.append(.object(["id": .string(tool.id), "type": .string("function"), "function": .object(function)]))
                results.append(ChatMessage(role: "tool", content: tool.preview ?? "", timestamp: timestamp,
                                           messageId: "\(localIDPrefix)\(runID)-tool-\(tool.id)",
                                           name: tool.name, toolCallId: tool.id))
            }
        }
        flush()
        return rows
    }
}
