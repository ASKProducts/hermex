import Foundation

/// GPT-Live listens and speaks; whenever it delegates, the request
/// becomes an ordinary Hermes turn (`prompt.submit {surface:"voice-live", voice_context}`) on
/// this conversation's dashboard chat, and the reply streams back as commentary the voice
/// paraphrases aloud.
///
/// Same observable shape as `VoiceSession` so the voice screen can mount either: `phase`
/// (`VoiceSession.Phase`), `caption`, `replyText`, `sessionKey`, `pendingApproval`, `muted`,
/// `isEnded`, `isSpeaking`, `start()`, `end()`, `toggleMute()`, `tapToInterrupt()`, `tick()`.
@MainActor @Observable final class VoiceLiveConversation {
    typealias Phase = VoiceSession.Phase

    /// Quiet after the last user transcript fragment before the utterance is judged as a whole
    /// ("stop" ends the chat; "stop the container" is a request).
    static let utteranceSettle: TimeInterval = 1.5
    static let submitFailedLine = "Sorry, I could not reach Hermes for that request."
    static let noSpokenResultLine = "Hermes finished that request without a spoken result."

    private(set) var phase: Phase = .connecting

    /// What the user said last (input transcript), and what the voice is saying (output transcript).
    private(set) var caption = ""
    private(set) var replyText = ""
    private(set) var muted = false
    private(set) var sessionKey: String?
    var sessionProfile: String? { chatProfile }
    private var chatProfile: String?
    private(set) var runtime: String?
    private(set) var pendingApproval: BotApprovalRequest?
    /// The delegation Hermes is answering; nil when idle.
    private(set) var activeDelegation: String?
    /// `session.closed` reason and `usage.seconds` once the session ended.
    private(set) var closedReason: String?
    private(set) var usageSeconds: Double?
    private(set) var delegations = 0

    private(set) var turnsSubmitted = 0
    private(set) var interruptsSent = 0

    private(set) var lastError: String?
    /// The voice screen's record: user lines (input transcript), the voice's lines (output
    /// transcript), one activity row per delegation (tool progress as its detail), approvals as notices.
    var transcript = VoiceTranscriptModel()
    /// The latest line of our own (approval prompts and answers), shown above the dock.
    private(set) var notice: String?
    /// Tap to interrupt cut the voice's audio on the device; restored for the next response.
    private(set) var playoutCut = false
    private(set) var playoutCuts = 0

    var isEnded: Bool { if case .ended = phase { return true }; return false }
    var isSpeaking: Bool { phase == .speaking }
    /// The status line: Hermes's own gateway events for this chat.
    private(set) var hermesStatus = VoiceHermesStatus()

    /// The mic's level for the meter (WebRTC stats), nil when the transport doesn't know.
    func inputLevel() async -> Double? { await transport?.inputLevel() }
    func outputLevel() async -> Double? { await transport?.outputLevel() }

    var onSessionCreated: ((String) -> Void)?
    /// A request that needs the app (sudo, secret, an approval without `once`).
    var onNeedsApp: ((String) -> Void)?
    /// A spoken stop phrase ended the session.
    var onStopWord: (() -> Void)?

    private let backend: any VoiceLiveBackend
    private let makeTransport: () -> any VoiceLiveTransport
    private let now: () -> Date
    private let resumeKey: String?
    private let resumeProfile: String?
    private let seedTurns: [(role: String, text: String)]
    private var transport: (any VoiceLiveTransport)?

    // Hermes turn state (the desktop's `busy`, `pendingResponse`, `activeToolLabel`).
    private var busy = false
    private var responseID = 0
    private var response: (id: Int, pending: Bool, text: String)?
    private var toolLabel: String?
    private var startsOwed = 0
    private var submittedFor: String?
    private var turnStarted = false
    private var submitting: Task<Void, Never>?
    // (`session.interrupt`) and holds the words until the stopped turn's `message.complete`:
    // submitted earlier, Hermes folds them into the dying turn (a steer during a tool call) and
    // they go unanswered. Delegations during the hold join the held words.
    private var held: (id: String, prompt: String, voiceContext: String, boundary: Int)?
    /// The interrupt went out and the stopped turn's `message.complete` has not arrived yet.
    private var awaitingStoppedTurn = false
    /// Resumed by the stopped turn's `message.complete` (true), or by the end of the call or
    /// the connection (false).
    private var stoppedTurnEnded: CheckedContinuation<Bool, Never>?
    /// Words are held until the stopped turn's `message.complete` (diagnostics, tests).
    var holdingFollowUp: Bool { stoppedTurnEnded != nil }
    /// One owner survives dismissal until the received tail is admitted and its work settles.
    private var finalization: Task<Void, Never>?
    /// Admission ends at the submit acknowledgement, not at the reply's completion.
    private var finalAdmission: Task<Void, Never>?
    private var chatSaved = false
    private var voiceClosed: CheckedContinuation<Void, Never>?
    private var workSettled: CheckedContinuation<Void, Never>?
    private var backendDisconnected = false
    // Delegation drive (the hook's refs).
    private var spokenLength = 0
    private var spokenResponseID: Int?
    private var lastToolLabel: String?
    private var speaking = false
    private var userUtterance = ""
    private var utteranceAt: Date?
    private var started = false
    /// read at each check so flipping it mid-call applies to the running call. It gates only
    /// jobs, Hermes's remarks) and when an unprompted update is due.
    private(set) var work = VoiceWorkLog()
    /// How many steps the silent context GPT-Live has names, so it is sent again only when
    /// the work moved on.
    private var contextSteps = 0
    /// A progress update went out and GPT-Live hasn't spoken since: it is still to be said.

    init(backend: any VoiceLiveBackend, makeTransport: @escaping () -> any VoiceLiveTransport,
         resumeSessionKey: String? = nil, resumeProfile: String? = nil,
         seedHistory: [(role: String, text: String)] = [], now: @escaping () -> Date = Date.init,
         reconnectDelay: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.backend = backend
        self.makeTransport = makeTransport
        self.resumeKey = resumeSessionKey
        self.resumeProfile = resumeProfile
        self.seedTurns = seedHistory
        self.now = now
        self.link = VoiceHermesLink(backend: backend, delay: reconnectDelay)
    }

    let link: VoiceHermesLink

    // MARK: Lifecycle

    func start() async {
        guard transport == nil, !isEnded else { return }
        backend.onEvent = { [weak self] frame in self?.handleHermes(frame) }
        backend.onDisconnect = { [weak self] error in
            guard let self else { return }
            // During the call the link reconnects and re-attaches the chat; after it ended
            // (the closing turn is settling) a lost socket ends that wait.
            guard self.isEnded else { self.link.lost(error); return }
            self.backendDisconnected = true
            self.workSettled?.resume(); self.workSettled = nil
        }
        link.reattach = { [weak self] in try await self?.reattachChat() }
        link.onLost = { [weak self] in
            guard let self else { return }
            HermesConnectionLog.logger.notice("voice-live: Hermes socket lost, reconnecting")
            self.transport?.events.think(self.activeDelegation, Self.reconnectingNote)
        }
        link.onRestored = { [weak self] in
            HermesConnectionLog.logger.notice("voice-live: Hermes chat re-attached")
            self?.transport?.events.think(self?.activeDelegation, Self.reconnectedNote)
        }
        link.onGaveUp = { [weak self] error in
            guard let self else { return }
            self.lastError = String(describing: error)
            self.backendDisconnected = true
            self.workSettled?.resume(); self.workSettled = nil
            self.endSession(String(localized: "Lost the connection to Hermes."))
        }
        do {
            try await backend.connect()
            if let resumeKey { try await resume(resumeKey) }
            else { _ = try await ensureChat() }
        } catch BotFailure.rejected(4009) {
            phase = .ended(String(localized: "That chat is busy right now.")); return
        } catch {
            phase = .ended(String(localized: "Couldn't connect to Hermes.")); return
        }
        let transport = makeTransport()
        self.transport = transport
        let events = transport.events

        events.onStarted = { [weak self] in self?.started = true; self?.refreshPhase() }
        events.onTranscript = { [weak self] fragment in self?.transcript(fragment) }
        events.onAppend = { [weak self, weak events] observation in
            guard let self else { return }
            events?.appendSent(observation, to: self.transcript)
        }
        events.onDelegation = { [weak self] id, context in self?.delegation(id, context) }
        events.onError = { [weak self] message in self?.lastError = message }
        events.onClosed = { [weak self] reason, seconds in self?.closed(reason, seconds) }
        transport.onSpeakingChange = { [weak self] value in self?.speakingChanged(value) }
        do {
            try await transport.start(history: VoiceLive.history(seedTurns), profile: resumeKey == nil ? nil : resumeProfile)
            refreshPhase()
        } catch {
            lastError = String(describing: error)
            transport.close()
            endSession(String(localized: "Couldn't start GPT-Live."))
        }
    }

    /// "Continue by voice": cold resume with the chat's own profile, as Normal mode does.
    private func resume(_ key: String) async throws {
        let reply = try await backend.call(.voiceSessionResume(sessionID: key, profile: resumeProfile))
        guard let live = reply["session_id"].text else { throw BotFailure.unsupported }
        runtime = live
        sessionKey = key
        chatSaved = true
        chatProfile = reply["info"]["profile_name"].text ?? resumeProfile
    }

    /// socket, then what the chat sent during the gap, through the same handler as live
    /// frames. A different runtime means the host reaped the old one with its turn: a
    /// delegation waiting on that turn is told it got no answer.
    private func reattachChat() async throws {
        guard let key = sessionKey else { return }
        let (live, missed) = try await link.resume(key: key, profile: chatProfile ?? resumeProfile, runtime: runtime)
        if live != runtime {
            runtime = live
            let lostTurn = busy || startsOwed > 0
            busy = false; startsOwed = 0; turnStarted = false; response = nil; toolLabel = nil
            // The turn a held follow-up waited on went with the old runtime: the words go now.
            if awaitingStoppedTurn {
                awaitingStoppedTurn = false
                stoppedTurnEnded?.resume(returning: true); stoppedTurnEnded = nil
            }
            if lostTurn, held == nil, let delegation = activeDelegation, !isEnded {
                transport?.events.speak(delegation, Self.lostTurnLine)
                transcript.delegationFinished(id: delegation, failed: true)
                activeDelegation = nil
                refreshPhase()
            }
            return
        }
        for frame in missed { handleHermes(frame) }
    }

    /// Quiet context for GPT-Live while the call reconnects to Hermes, and once it is back.
    static let reconnectingNote = "Lost the connection to Hermes; reconnecting now. Requests wait and go once it is back. "
        + "If the user asks, say Hermes is reconnecting."
    static let reconnectedNote = "Reconnected to Hermes."
    static let lostTurnLine = "Hermes restarted while it was working on that request, so it was lost. Ask the user to ask again."

    /// Chat identity exists before input, including calls without any delegation.
    private func ensureChat() async throws -> String {
        if let runtime { return runtime }
        let reply = try await backend.call(.voiceSessionCreate)
        guard let live = reply["session_id"].text, let key = reply["stored_session_id"].text, !key.isEmpty
        else { throw BotFailure.unsupported }
        runtime = live
        sessionKey = key
        chatProfile = reply["info"]["profile_name"].text
        onSessionCreated?(key)
        return live
    }

    /// Ending the voice is synchronous; the single finalization task owns the backend afterwards.
    func end() async { endSession(nil) }

    /// The finalization task ends once the end-of-call turn's `message.complete` arrived (or the
    func awaitChatWorkSettled() async { await finalization?.value }

    /// An unused reserved key is not a saved chat. End waits only for the final note's
    /// admission; a resumed chat or an accepted delegation opens without this extra wait.
    func chatForOpening() async -> String? {
        if !chatSaved { await finalAdmission?.value }
        return chatSaved ? sessionKey : nil
    }

    private func endSession(_ reason: String?) {
        guard !isEnded else { return }
        // Keep the event core before close callbacks detach the transport. Its transcript can still
        // receive graceful-close fragments, but the audio tracks are disabled at the user's action.
        let closingTransport = transport
        let events = closingTransport?.events
        phase = .ended(reason)
        closingTransport?.setMuted(true)
        closingTransport?.setPlayoutCut(true)
        muted = true
        playoutCut = true
        speaking = false
        userUtterance = ""
        utteranceAt = nil
        // Do not mark outstanding Hermes work finished merely because the voice ended.
        transcript.finishExchange()
        // A held follow-up is not sent after the call ended: its words were never accepted, so the
        // final tail below carries them.
        awaitingStoppedTurn = false
        stoppedTurnEnded?.resume(returning: false); stoppedTurnEnded = nil
        // A call ended while reconnecting has no socket to send its tail on or hear its work settle.
        if link.state != .connected { backendDisconnected = true }
        link.cancel()
        let pendingSubmit = submitting
        let admission = Task {
            if let events, !events.finalized {
                await withCheckedContinuation { voiceClosed = $0 }
            }
            await pendingSubmit?.value
            if let events, !backendDisconnected {
                let boundary = events.receivedFragments
                let context = VoiceLive.delegationContext(events.contextWindow(.sinceLastRequest)).context
                if !context.isEmpty {
                    do {
                        let runtime = try await ensureChat()
                        let text = Self.callEndedPrompt + "\n\n" + context
                        if busy || startsOwed > 0 {
                            let reply = try await backend.call(.sessionSteer(sessionID: runtime, text: text))
                            if reply["status"].text == "rejected" {
                                try await submitFinal(.promptSubmit(sessionID: runtime, text: text))
                            } else {
                                guard reply["status"].text == "queued" else { throw BotFailure.unsupported }
                            }
                        } else {
                            // The explicitly accepted idle→busy race keeps normal voice-live admission.
                            try await submitFinal(Self.submitCall(runtime: runtime, prompt: Self.callEndedPrompt, voiceContext: context))
                        }
                        chatSaved = true
                        events.acceptContext(through: boundary)
                    } catch { lastError = String(describing: error) }
                }
            }
        }
        finalAdmission = admission
        finalization = Task {
            await admission.value
            if !backendDisconnected, busy || startsOwed > 0 {
                await withCheckedContinuation { workSettled = $0 }
            }
            // Disconnect locally, not session.close: closing a runtime can cancel queued or active
            // server work. The detached runtime remains server-owned until its natural retirement.
            backend.onEvent = nil
            backend.onDisconnect = nil
            backend.close()
            finalAdmission = nil
            finalization = nil
        }
        closingTransport?.close()
    }

    private func submitFinal(_ call: HermesCall) async throws {
        startsOwed += 1
        do {
            let reply = try await backend.call(call)
            guard let status = reply["status"].text,
                  ["streaming", "queued", "redirected", "steered"].contains(status) else { throw BotFailure.unsupported }
            if status == "redirected" || status == "steered" { startsOwed -= 1 }
        } catch { startsOwed -= 1; throw error }
    }

    private func closed(_ reason: String, _ seconds: Double?) {
        closedReason = reason
        usageSeconds = seconds
        // Snapshot/retain the core in endSession before discarding the last transport reference.
        if !isEnded { endSession(reason == "close_requested" ? nil : Self.endedMessage(reason, seconds)) }
        transport = nil
        voiceClosed?.resume(); voiceClosed = nil
    }

    /// `liveEndedMessage`: our machine reasons get copy; any other reason is the server's, verbatim.
    static func endedMessage(_ reason: String, _ seconds: Double?) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "connection_lost" { text = String(localized: "GPT-Live connection lost.") }
        else if text == "closed" || text.isEmpty { text = String(localized: "GPT-Live session ended.") }
        return seconds.map { "\(text) (\(Int($0.rounded()))s)" } ?? text
    }

    // MARK: Controls

    func toggleMute() {
        guard !isEnded else { return }
        muted.toggle()
        transport?.setMuted(muted)
    }

    /// No explicit turn boundary in full duplex; a nudge tells the voice to answer now (`stopTurn`).
    func stopTurn() {
        transport?.events.instruct("The user has finished speaking. Respond now to what they said.")
    }

    /// The "Tap to interrupt" control. GPT-Live has no client event that cuts its audio, so the
    /// tap tells the voice to stop and listen (talking over it works natively in full duplex).
    func tapToInterrupt() {
        guard !isEnded, speaking, !playoutCut, let transport else { return }
        // Silence first, on the device, at the tap; the model stops on the instruction ~1.5 s later.
        transport.setPlayoutCut(true)
        playoutCut = true
        playoutCuts += 1
        if activeDelegation == nil { transcript.interrupt() }
        refreshPhase()
        transport.events.instruct("The user tapped to interrupt you. Stop speaking now and listen.")
    }

    /// The cut lasts until the interrupted response has ended (no output for 1.2 s) or the user
    /// talks (the next response answers them).
    private func restorePlayout() {
        guard playoutCut else { return }
        playoutCut = false
        transport?.setPlayoutCut(false)
    }

    private func speakingChanged(_ value: Bool) {
        guard !isEnded else { return }
        speaking = value
        if !value { restorePlayout() }
        refreshPhase()
    }

    // MARK: Voice events

    private func transcript(_ fragment: VoiceLive.Fragment) {
        guard !isEnded else { return }
        if fragment.speaker == .assistant {
            let piece = fragment.joining(after: replyText)
            replyText += piece
            // Words of the response being cut still arrive; they aren't shown as said.
            if !playoutCut { transcript.liveAssistantSpeech(piece) }
            return
        }
        restorePlayout()
        if utteranceAt == nil {
            caption = ""
            transcript.liveUserSpeech(String(fragment.text.drop { $0.isWhitespace }), startsSegment: true)
            sendWorkContext()
        } else {
            transcript.liveUserSpeech(fragment.joining(after: caption), startsSegment: false)
        }
        let piece = fragment.joining(after: caption)
        userUtterance += piece
        caption += piece
        utteranceAt = now()
        refreshPhase()
    }

    /// The utterance settled (no user words for 1.5 s): a whole-utterance stop phrase ends the
    /// session; with an approval pending, approve/deny answers it.
    private func utteranceSettled() {
        let utterance = userUtterance
        userUtterance = ""
        utteranceAt = nil
        if VoiceText.isStopCommand(utterance) {
            Task { await end() }
            onStopWord?()
            return
        }
        if let approval = pendingApproval, VoiceText.approvalAnswer(utterance) != nil {
            Task { await answerApproval(approval, utterance) }
        }
        refreshPhase()

    }

    private func delegation(_ id: String, _ context: [VoiceLive.Fragment]) {
        guard !isEnded, let transport else { return }
        delegations += 1
        // The delegation consumes what the user said: the utterance is no longer in progress
        // (otherwise phase stays .hearing through the whole Hermes turn).
        userUtterance = ""
        utteranceAt = nil
        let (prompt, voiceContext) = VoiceLive.delegationPrompt(context)
        // A spoken stop command ends the conversation instead of becoming a turn.
        if !prompt.isEmpty, VoiceText.isStopCommand(prompt) {
            Task { await end() }
            onStopWord?()
            return
        }
        // An approval answer goes to the pending approval, not into a new turn.
        if let approval = pendingApproval, VoiceText.approvalAnswer(prompt) != nil {
            Task { await answerApproval(approval, prompt) }
            transport.events.think(id, "Passed the user's answer to Hermes's approval request.")
            return
        }
        if let previous = activeDelegation { transcript.delegationFinished(id: previous) }
        transcript.delegationStarted(id: id, prompt: prompt.isEmpty ? nil : prompt)
        activeDelegation = id
        spokenResponseID = nil
        spokenLength = 0
        lastToolLabel = nil
        work.begin(at: now())
        contextSteps = 0
        turnStarted = false
        response = nil
        refreshPhase()
        let deliveryBoundary = transport.events.receivedFragments
        // A stop is already waiting for its turn to end: these words join the held ones and go
        // out with them. Nothing was accepted since the held request, so this window holds both:
        // the prompt is every user turn in it, not only the last.
        if held != nil {
            held = (id, VoiceLive.userWords(context), voiceContext, deliveryBoundary)
            return
        }
        let previousSubmit = submitting
        submitting = Task {
            await previousSubmit?.value
            // the chat is attached again; if reconnecting gave up, the call has ended.
            guard await link.ready(), !isEnded else { return }
            var ownID = id
            do {
                let runtime = try await ensureChat()
                guard !isEnded else { return }
                var submitPrompt = prompt, submitContext = voiceContext, boundary = deliveryBoundary
                // A newer request supersedes an in-flight turn: stop it so the answer the voice
                // speaks is for what the user asked last. The words wait for the stopped turn's
                // `message.complete`; sent before it, Hermes steers them into the dying turn.
                if busy {
                    held = (id, prompt, voiceContext, deliveryBoundary)
                    awaitingStoppedTurn = true
                    interruptsSent += 1
                    _ = try? await backend.call(.sessionInterrupt(sessionID: runtime))
                    startsOwed = 0
                    if awaitingStoppedTurn {
                        let ended = await withCheckedContinuation { stoppedTurnEnded = $0 }
                        guard ended else { held = nil; return }
                    }
                    guard let words = held, !isEnded else { held = nil; return }
                    held = nil
                    (ownID, submitPrompt, submitContext, boundary) = words
                }
                submittedFor = ownID
                startsOwed += 1
                let reply: BotJSON
                do {
                    reply = try await backend.call(Self.submitCall(runtime: runtime, prompt: submitPrompt, voiceContext: submitContext))
                    guard let status = reply["status"].text,
                          ["streaming", "queued", "redirected", "steered"].contains(status) else { throw BotFailure.unsupported }
                } catch { startsOwed -= 1; throw error }
                chatSaved = true
                transport.events.acceptContext(through: boundary)
                turnsSubmitted += 1
                // The running turn now carries these words: its frames are this delegation's.
                if let status = reply["status"].text, status == "redirected" || status == "steered" {
                    startsOwed -= 1
                    if activeDelegation == ownID { turnStarted = true; response = nil }
                }
            } catch {
                guard !isEnded, activeDelegation == ownID else { return }
                transport.events.speak(ownID, Self.submitFailedLine)
                transcript.delegationFinished(id: ownID, failed: true)
                activeDelegation = nil
                refreshPhase()
            }
        }
    }

    /// without starting a turn (`prompt.submit` always runs one; `session.steer` only reaches a
    /// running turn and is rejected when idle), so this is wording, not a mechanism: it asks
    /// Hermes to record the closing words and act only on a request that is still open.
    nonisolated static let callEndedPrompt = "Voice call ended. This only records the end of the call; it is not a new question. "
        + "Don't answer it or repeat earlier answers. If the closing words below ask for something "
        + "that hasn't been done yet, do it; otherwise reply with just \"Noted.\""

    /// `prompt.submit` for a delegation; `voice_context` capped at Hermes's 6,000 characters.
    static func submitCall(runtime: String, prompt: String, voiceContext: String) -> HermesCall {
        .voiceLivePromptSubmit(sessionID: runtime, text: prompt, voiceContext: String(voiceContext.suffix(6_000)))
    }

    // MARK: Hermes events

    private func handleHermes(_ frame: BotJSON) {
        link.saw(frame, runtime: runtime)
        if isEnded {
            guard let runtime, frame["session_id"].text == runtime else { return }
            switch frame["type"].text {
            case "message.start":
                busy = true
                if startsOwed > 0 { startsOwed -= 1 }
            case "message.complete":
                busy = false
                if startsOwed == 0 { workSettled?.resume(); workSettled = nil }
            default: break
            }
            return
        }
        if let request = BotServerRequest(frame) {
            guard request.sessionID == runtime else { return }
            handleRequest(request)
            return
        }
        guard let runtime, frame["session_id"].text == runtime, let type = frame["type"].text else { return }
        let payload = frame["payload"]
        hermesStatus.apply(type, payload, at: now())
        // A delegation waits for its own turn: another turn's frames are not its work.
        let otherTurn = activeDelegation != nil && !turnStarted
        switch type {
        case "message.start":
            busy = true
            if startsOwed > 0 {
                startsOwed -= 1
                if startsOwed == 0, let activeDelegation, submittedFor == activeDelegation { turnStarted = true }
            }
            responseID += 1
            response = nil
        case "message.delta":
            guard let text = payload["text"].text, !text.isEmpty else { return }
            busy = true
            guard turnStarted else { return }  // another turn's text is never spoken
            if response == nil { responseID += 1; response = (responseID, true, "") }
            response?.text += text
        case "message.complete":
            busy = false
            // The turn our interrupt stopped has ended: the held words go out as a fresh turn.
            if awaitingStoppedTurn {
                awaitingStoppedTurn = false
                stoppedTurnEnded?.resume(returning: true); stoppedTurnEnded = nil
            }
            // Another turn ended (e.g. the one this delegation interrupted): this delegation's turn
            // is still to come. Elapsed time cannot establish turn ownership.
            guard turnStarted else { return }
            // The rows Hermes saved for this delegation's turn (its receipt), recorded before
            // anything below sends the reply as commentary.
            let receipt = payload["persisted_turn"]
            if let delegation = activeDelegation, let rows = receipt["row_ids"].list?.compactMap(\.integer), !rows.isEmpty {
                transcript.delegationSaved(id: delegation, userRowID: receipt["user_row_id"].integer, rowIDs: rows)
            }
            // The complete's text is the final reply and replaces what streamed. Offsets stay aligned
            // because speech is cut from the text with leading whitespace dropped (see tick()).
            if let text = payload["text"].text, !text.isEmpty {
                if response == nil { responseID += 1; response = (responseID, false, text) } else { response?.text = text }
            }
            response?.pending = false
        case "tool.start":
            busy = true
            guard !otherTurn else { return }
            toolLabel = payload["name"].text
            work.add(VoiceWorkStep.tool(payload))
            transcript.delegatedEvent(type, payload)
        case "tool.complete":
            guard !otherTurn else { return }
            toolLabel = nil
            transcript.delegatedEvent(type, payload)
        case "subagent.start", "subagent.complete", "background.complete":
            guard !otherTurn, activeDelegation != nil else { return }
            work.add(VoiceWorkStep.event(type, payload))
        case "reasoning.delta", "message.interim":
            guard !otherTurn else { return }
            transcript.delegatedEvent(type, payload)
            if type == "message.interim" { progressRemark(payload["text"].text ?? "") }
            return
        default: return
        }
        tick()
    }

    private func handleRequest(_ request: BotServerRequest) {
        switch request.pending {
        case .approval(let approval)?:
            pendingApproval = approval
            let what = approval.command ?? approval.consequence ?? String(localized: "run an action")
            notice = String(localized: "Approval needed: \(what). Say approve or deny.")
            transport?.events.speak(activeDelegation, "Hermes wants to \(what). Ask the user to say approve or deny.")
        case .credential?:
            onNeedsApp?(String(localized: "Hermes needs a password or secret. That needs the app."))
            transport?.events.speak(activeDelegation, "Hermes needs a password or secret. Tell the user that needs the app.")
        case .question?:
            onNeedsApp?(String(localized: "Hermes has a question that needs the app."))
            transport?.events.speak(activeDelegation, "Hermes has a question that needs the app. Tell the user.")
        default: return
        }
    }

    /// Voice approves once only, never for the session or always; a request without `once`
    /// stays pending for the app.
    private func answerApproval(_ approval: BotApprovalRequest, _ text: String) async {
        guard let answer = VoiceText.approvalAnswer(text), let runtime else { return }
        if answer == .approve, !approval.choices.contains(.once) {
            onNeedsApp?(String(localized: "Hermes is waiting for an approval that needs the app."))
            transport?.events.speak(activeDelegation, "That approval needs the app.")
            return
        }
        pendingApproval = nil
        let choice: BotApprovalRequest.Choice = answer == .approve ? .once : .deny
        notice = answer == .approve ? String(localized: "Approved once.") : String(localized: "Denied.")
        _ = try? await backend.call(.approvalRespond(sessionID: runtime, requestID: approval.requestID, choice: choice))
    }

    /// Hermes's own remark between steps (`message.interim`) in the active delegation's turn: a
    /// step like any tool. With streaming on, its words already arrived as `message.delta`s
    /// into `response`; the interim marks them as a remark, not the reply, so unspoken they
    /// leave `response`. Once the voice has started saying them they stay where they are.
    private func progressRemark(_ text: String) {
        guard activeDelegation != nil, turnStarted, let step = VoiceWorkStep.remark(text) else { return }
        if let response {
            if spokenResponseID == response.id, spokenLength > 0 { return }
            self.response = nil
        }
        work.add(step)

    }

    private func sendWorkContext() {
        guard let delegationID = activeDelegation, let transport, work.steps.count > contextSteps,
              let context = work.context else { return }
        contextSteps = work.steps.count
        transport.events.think(delegationID, context)
    }

    /// The commentary GPT-Live is handed for an update: the steps with their specific
    /// detail, to be said as such (measured: asked for only "a few plain words", GPT-Live
    /// said "still going through the sequence" for a run of terminal-command steps).

    // MARK: Drive (the hook's 200 ms reply effect)

    /// The screen calls this every 200 ms; Hermes events call it too.
    func tick() {
        guard !isEnded else { return }
        if let at = utteranceAt, now().timeIntervalSince(at) >= Self.utteranceSettle { utteranceSettled() }
        guard let transport, let delegationID = activeDelegation else { return }
        let events = transport.events
        if let tool = toolLabel, tool != lastToolLabel { lastToolLabel = tool }

        if let response {
            if spokenResponseID != response.id { spokenResponseID = response.id; spokenLength = 0 }
            // A reply after a tool call streams in starting "\n\n"; untrimmed, the paragraph-break rule
            // would speak it as a leading ". ".
            let spoken = VoiceLive.sanitizeForSpeech(String(response.text.drop { $0.isWhitespace }))
            let chars = Array(spoken)
            // Append only completed sentences while streaming; the tail lands on settle.
            if response.pending || busy {
                let boundary = Self.lastSentenceBoundary(chars)
                let cut = boundary > spokenLength ? boundary + 1 : spokenLength
                if cut > spokenLength {
                    events.speak(delegationID, String(chars[spokenLength..<cut]))
                    spokenLength = cut
                }
                return
            }
            if chars.count > spokenLength {
                events.speak(delegationID, String(chars[spokenLength...]))
                spokenLength = chars.count
            }
            self.response = nil
            transcript.delegationFinished(id: delegationID)
            activeDelegation = nil
            refreshPhase()
            return
        }
        // Only this delegation's own turn can settle it. A slow queued start is not completion.
        if !busy, turnStarted {
            // Settled without a speakable reply (tool-only, error, interrupted).
            if spokenLength == 0 {
                events.think(delegationID, Self.noSpokenResultLine)
                hermesStatus.turnEndedWithoutReply()
            }
            transcript.delegationFinished(id: delegationID)
            activeDelegation = nil
            refreshPhase()
        }
    }

    /// `spoken.lastIndexOf('. ', spoken.length - 2)`, -1 when none.
    static func lastSentenceBoundary(_ chars: [Character]) -> Int {
        guard chars.count >= 2 else { return -1 }
        var i = min(chars.count - 2, chars.count - 2)
        while i >= 0 {
            if chars[i] == ".", i + 1 < chars.count, chars[i + 1] == " " { return i }
            i -= 1
        }
        return -1
    }

    private func refreshPhase() {
        guard !isEnded else { return }
        if !started { phase = .connecting }
        else if speaking, !playoutCut { phase = .speaking }
        else if utteranceAt != nil { phase = .hearing }
        else if activeDelegation != nil { phase = .working(lastToolLabel.map(VoiceText.progressPhrase)) }
        else { phase = .listening }
    }
}
