import Foundation

/// Plays reply PCM. Production: `VoiceAudioEngine`; tests record calls.
@MainActor protocol VoicePlayback: AnyObject {
    func beginSpeech(sampleRate: Int, channels: Int)
    func enqueue(pcm: Data)
    /// Called after the last PCM of a reply; `onDrained` fires when playback finishes.
    func finishSpeech(onDrained: @escaping () -> Void)
    /// Seconds of reply audio received and not yet played (0 = the player ran dry).
    var queuedSpeechSeconds: TimeInterval { get }
    func playClip(_ data: Data, onDrained: @escaping () -> Void)
    func stopSpeech(reason: String)
    /// Holds playback where it is (queue kept); anything that starts meanwhile is held too.
    func pauseSpeech()
    /// Ends a hold. `reason` "resumed" logs `voice-speech-stop`; the rest continues from where it paused.
    func resumeSpeech(reason: String)
    func earcon()
    /// A quiet tone while Hermes works ("While Hermes works: Soft sound").
    func softTone()
}

extension VoicePlayback {
    func softTone() { earcon() }
}

@MainActor @Observable final class VoiceSession {
    enum Phase: Equatable {
        case connecting, listening, hearing, sending, working(String?), speaking, ended(String?)

        /// The case's name only (its strings are spoken or shown text; they stay out of records).

    }

    struct Settings: Equatable {
        var interruptByTalking = true
        var progress: Progress = .spoken
        var pronunciations = VoiceText.defaultPronunciations
        var useServerTranscription = true
        enum Progress: String, CaseIterable { case spoken, tones, off }
    }

    private(set) var phase: Phase = .connecting

    /// What the user said last, and the reply as it is spoken.
    private(set) var caption = ""
    /// Everything said and done, in the chat's turn model (`VoiceTranscriptModel`, drawn by the
    /// chat's transcript UI). The screen hands in its own model so it survives a mode switch.
    var transcript = VoiceTranscriptModel()
    /// The latest line of our own (errors, prompts, approvals), shown above the dock.
    private(set) var notice: String?
    private(set) var replyText = ""
    private(set) var sessionProfile: String?
    private(set) var sessionKey: String?
    private(set) var runtime: String?
    private(set) var pendingApproval: BotApprovalRequest?
    private(set) var pendingQuestion: BotQuestionRequest?
    private(set) var pcmBytesReceived = 0
    private(set) var turnsSubmitted = 0
    private(set) var lastSubmitInterrupted = false
    private(set) var steersSent = 0
    /// On-device utterances the recognizer couldn't read, sent to the server instead.
    private(set) var usedServerFallback = 0

    var settings: Settings
    private let backend: any BotVoiceBackend
    private let player: any VoicePlayback
    private let now: () -> Date
    /// Called with the session key once the chat exists (Hermex keeps voice keys locally).
    private let resumeProfile: String?
    var onSessionCreated: ((String) -> Void)?
    /// Diagnostics: an utterance's transcript length and whether on-device recognition fell back to the server.
    var onTranscript: ((Int, Bool) -> Void)?
    /// Diagnostics: a failure the user hears about, as (where, error code).
    var onError: ((String, String) -> Void)?
    /// Called for requests that need the app (sudo, secret).
    var onNeedsApp: ((String) -> Void)?

    private var turnRunning = false
    /// The next submit tells Hermes its last reply was cut off.
    private var interruptedNext = false
    /// A turn the user talked over: `session.interrupt` sent, its remaining
    /// frames are dropped until its `message.complete`.
    private var rejectingTurn = false
    /// Words spoken over a rejected reply, submitted once that turn completes.
    private var queuedAfterReject: String?
    /// The rejected turn's `message.complete` is awaited at most this long
    /// (desktop `INTERRUPT_SETTLE_TIMEOUT_MS`), checked on `tick()`.
    static let rejectSettleTimeout: TimeInterval = 5
    private var rejectDeadline: Date?
    /// After a timed-out rejection the old turn may still send frames. Until the
    /// next `message.start` (a new server turn) they are its leftovers and are
    /// dropped, so a late `message.complete` can't end or replace the new turn.
    private var staleUntilStart = false
    /// What is playing: the reply, or one of our own lines (progress, prompts, errors).
    private enum Speaking { case reply, line }
    private var speaking: Speaking?
    private var speech: VoiceSpeakStream?
    private var replyStarted = false
    private var latestTool: String?
    private var pacer = VoiceProgressPacer()
    private var resumeKey: String?

    init(backend: any BotVoiceBackend, player: any VoicePlayback,
         settings: Settings = Settings(), resumeSessionKey: String? = nil, resumeProfile: String? = nil, now: @escaping () -> Date = Date.init,
         reconnectDelay: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.resumeProfile = resumeProfile
        self.backend = backend
        self.player = player
        self.settings = settings
        self.resumeKey = resumeSessionKey
        self.now = now
        self.link = VoiceHermesLink(backend: backend, delay: reconnectDelay)
    }

    let link: VoiceHermesLink

    var isEnded: Bool { if case .ended = phase { return true }; return false }
    var isSpeaking: Bool { phase == .speaking }
    /// The status line: Hermes's own gateway events for this chat.
    private(set) var hermesStatus = VoiceHermesStatus()

    func start() async {
        backend.onEvent = { [weak self] frame in self?.handle(frame) }
        backend.onDisconnect = { [weak self] error in
            guard let self, !self.isEnded else { return }
            self.link.lost(error)
        }
        link.reattach = { [weak self] in try await self?.reattachChat() }
        link.onLost = { HermesConnectionLog.logger.notice("voice-normal: Hermes socket lost, reconnecting") }
        link.onRestored = { HermesConnectionLog.logger.notice("voice-normal: Hermes chat re-attached") }
        link.onGaveUp = { [weak self] error in
            guard let self, !self.isEnded else { return }
            self.onError?("reconnect", String(describing: error))
            self.stopSpeaking(reason: "disconnect")
            self.phase = .ended(String(localized: "Lost the connection to Hermes."))
        }
        do {
            try await backend.connect()
            if let key = resumeKey { try await resume(key) }
            phase = .listening
        } catch BotFailure.rejected(4009) {
            // The chat is running a turn (typed elsewhere); a second one must not start beside it.
            onError?("start", "rejected(4009)")
            phase = .ended(String(localized: "That chat is busy right now."))
        } catch {
            onError?("start", String(describing: error))
            phase = .ended(String(localized: "Couldn't connect to Hermes."))
        }
    }

    private func resume(_ key: String) async throws {
        // Cold resume from state.db so turns typed elsewhere are included.
        // A chat of another profile lives in that profile's state.db; the default profile's
        // chats (and new voice chats) resume in the dashboard's own.
        let reply: BotJSON
        do { reply = try await backend.call(.voiceSessionResume(sessionID: key, profile: resumeProfile)) } catch {
            // Why a resume failed (e.g. rejected(4007): no `profile` for another profile's chat).
            onError?("resume", String(describing: error)); throw error
        }
        guard let live = reply["session_id"].text else { throw BotFailure.unsupported }
        runtime = live
        // authoritative ownership survives the runtime's End.
        sessionProfile = reply["info"]["profile_name"].text ?? reply["info"]["profile"].text ?? resumeProfile
        sessionKey = key
    }

    /// socket, then what the chat sent during the gap, through the same handler as live
    /// frames. A different runtime means the host reaped the old one with its turn.
    private func reattachChat() async throws {
        guard let key = sessionKey else { return }
        let (live, missed) = try await link.resume(key: key, profile: resumeProfile, runtime: runtime)
        if live != runtime {
            runtime = live
            if turnRunning, !isEnded {
                turnRunning = false
                rejectingTurn = false
                announce(String(localized: "Hermes restarted while it was working on that, so it was lost. Please ask again."))
            }
            return
        }
        for frame in missed { handle(frame) }
    }

    // MARK: Listening

    /// The microphone heard speech start. Nothing is cut yet: our audio is held
    /// (a reply playing pauses where it is, one that becomes ready doesn't start)
    /// until the utterance is known to be words (`commitHold`) or noise (`releaseHold`).
    func speechStarted() {
        guard !isEnded else { return }
        speechOpen = true
        if let last = lastQueued, last.bargeIn, now().timeIntervalSince(last.endedAt) <= joinWindow { last.joinNext = true }
        if phase == .speaking, !settings.interruptByTalking { return }
        if settings.interruptByTalking {
            if phase == .speaking { lastSpeechWasBargeIn = true }
            if !holding {
                holding = true
                player.pauseSpeech()
            }
        }
        if phase == .listening || phase == .speaking { phase = .hearing }
    }

    /// Our audio is held for the user's speech.
    private var holding = false
    /// Between `speechStarted` and the end (or discard) of that utterance.
    private var speechOpen = false
    /// The current stream's audio has started (`start` frame).
    private var streamStarted = false
    /// A reply or line is held (paused, or ready and not started) for the user's speech.
    var replyHeld: Bool { holding && (speech != nil || pendingSpeech != nil) }

    /// The held speech turned out to be words: today's barge-in (stop, interrupt a reply).
    /// Speech that already started again keeps the hold.
    private func commitHold() {
        guard holding else { return }
        bargeIn()
        guard !speechOpen else { return }
        holding = false
        player.resumeSpeech(reason: "released")
    }

    /// The held speech was noise (too short, or an empty transcript): play on from where it paused.
    private func releaseHold() {
        guard holding, !speechOpen else { return }
        holding = false
        player.resumeSpeech(reason: speaking != nil ? "resumed" : "released")
        if speaking != nil, streamStarted { phase = .speaking } else { settle() }
    }

    /// The "Tap to interrupt" control: a barge-in that doesn't depend on detection.
    /// The reply stops and the mic keeps listening for what the user says next.
    func tapToInterrupt() {
        guard !isEnded, phase == .speaking || speech != nil || pendingSpeech != nil else { return }
        bargeIn()
        lastSpeechWasBargeIn = true
        if holding, !speechOpen { holding = false; player.resumeSpeech(reason: "released") }
    }

    /// Who the push relay reports this voice chat as, for `PushPresence`: hermex-push
    /// keys events by the agent session ID, which for a dashboard (`tui`) session is the
    /// stored session key `session.create` returned.
    func pushViewer(server: URL) -> PushPresence.Viewer? {
        sessionKey.map { PushPresence.Viewer(server: server, sessionID: $0) }
    }

    /// On-device partial text while the user is still talking.
    func showLiveCaption(_ text: String) {
        guard !isEnded, !text.isEmpty else { return }
        caption = text
        transcript.hearing(text)
    }

    func speechEnded() { speechOpen = false }

    /// Too-short speech: nothing is sent, so leave "Hearing you".
    func speechDiscarded() {
        speechOpen = false
        transcript.hearingEnded()
        releaseHeldWords()
        if !isEnded, phase == .hearing { phase = turnRunning ? .working(nil) : .listening }
        releaseHold()
    }

    /// Talking over speech. Over one of OUR lines (progress, prompts, errors):
    /// stop it; the words steer a running turn, `interrupted` untouched. Over the
    /// REPLY while its turn still runs: the user rejected it, so stop playback,
    /// `session.interrupt`, and submit the new words with `interrupted: true` once
    /// that turn's `message.complete` arrives (desktop `use-voice-conversation`).
    /// Over a reply whose turn already completed: the next submit is `interrupted`.
    func bargeIn() {
        guard speech != nil || pendingSpeech != nil || phase == .speaking else { return }
        let wasReply = speaking == .reply
        if wasReply { transcript.interrupt() }
        stopSpeaking(reason: "barge-in")
        if wasReply {
            interruptedNext = true
            if turnRunning, let runtime {
                rejectingTurn = true
                rejectDeadline = now().addingTimeInterval(Self.rejectSettleTimeout)
                Task { _ = try? await self.backend.call(.sessionInterrupt(sessionID: runtime)) }
            }
        }
        phase = turnRunning && !rejectingTurn ? .working(nil) : .listening
    }

    private func stopSpeaking(reason: String) {
        if speech != nil || pendingSpeech != nil {
            onTTS?("stopped", ["stream": streamIndex, "reason": reason, "ms": msSinceOpened(), "bytes": streamBytes])
        }
        pendingSpeech = nil
        queuedReply = nil
        speaking = nil
        speechSlow = false
        player.stopSpeech(reason: reason)
        speech?.stop()
        speech = nil
    }

    /// A finished utterance as recorded audio, with the on-device caption.
    /// `onDevice` nil: on-device recognition failed or heard nothing, so this
    /// utterance goes to the server even in On-device mode.
    /// Utterances are handled strictly one at a time, in the order spoken. One
    /// that followed a barge-in is held for `joinWindow`; speech starting within it is
    /// the same thought, so the two are joined into one utterance.
    func utterance(audio: Data, mimeType: String, caption onDevice: String?) async {
        guard !isEnded else { return }
        let item = QueuedUtterance(bargeIn: lastSpeechWasBargeIn, endedAt: now())
        lastSpeechWasBargeIn = false
        lastQueued = item
        let previous = utteranceChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.process(item, audio: audio, mimeType: mimeType, caption: onDevice)
        }
        utteranceChain = task
        await task.value
    }

    /// Extra speech within this long after a barge-in's utterance ends joins it.
    var joinWindow: TimeInterval = 1
    private final class QueuedUtterance {
        let bargeIn: Bool; let endedAt: Date; var joinNext = false
        init(bargeIn: Bool, endedAt: Date) { self.bargeIn = bargeIn; self.endedAt = endedAt }
    }
    private var utteranceChain: Task<Void, Never>?
    private var lastQueued: QueuedUtterance?
    private var lastSpeechWasBargeIn = false
    private var heldWords: String?
    private(set) var utterancesInFlight = 0
    private(set) var maxUtterancesInFlight = 0

    private func process(_ item: QueuedUtterance, audio: Data, mimeType: String, caption onDevice: String?) async {
        guard !isEnded else { return }
        utterancesInFlight += 1
        maxUtterancesInFlight = max(maxUtterancesInFlight, utterancesInFlight)
        defer { utterancesInFlight -= 1 }
        guard let heard = await transcribeUtterance(audio: audio, mimeType: mimeType, caption: onDevice) else {
            releaseHold()
            return
        }
        // Words commit a held barge-in; an empty transcript was noise, so the reply plays on.
        if heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { releaseHold() } else { commitHold() }
        if item.bargeIn, !item.joinNext {
            let left = joinWindow - now().timeIntervalSince(item.endedAt)
            if left > 0 { try? await Task.sleep(for: .milliseconds(Int(left * 1000))) }
        }
        let words = [heldWords, heard].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        heldWords = nil
        if item.joinNext { heldWords = words; return }
        await deliver(text: words)
    }

    /// Speech ended as noise: words held for a join are sent on their own.
    private func releaseHeldWords() {
        guard lastQueued?.joinNext == true else { return }
        lastQueued?.joinNext = false
        let previous = utteranceChain
        utteranceChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, let words = self.heldWords else { return }
            self.heldWords = nil
            await self.deliver(text: words)
        }
    }

    private func transcribeUtterance(audio: Data, mimeType: String, caption onDevice: String?) async -> String? {
        let text: String
        let fallback = !settings.useServerTranscription && onDevice == nil
        if settings.useServerTranscription || onDevice == nil {
            if !settings.useServerTranscription { usedServerFallback += 1 }
            let wasSpeaking = phase == .speaking
            if !wasSpeaking { phase = .sending }
            do {
                text = try await transcribe(audio: audio, mimeType: mimeType)
            } catch {
                // One failed upload (a proxy 502) isn't a lost connection: say so and keep
                // listening. Only `onDisconnect` ends the session.
                let ns = error as NSError
                onError?("transcribe", "\(ns.domain):\(ns.code)")
                guard !isEnded else { return nil }
                if !turnRunning, speaking == nil { phase = .listening }
                // A reply held for this speech plays on (`releaseHold`) rather than being cut by the line.
                let line = String(localized: "Sorry, I didn't catch that.")
                transcript.hearingEnded()
                notice = line
                if !(holding && speaking != nil) { say(line) }
                return nil
            }
        } else { text = onDevice ?? "" }
        onTranscript?(text.count, fallback)
        return text
    }

    /// How long to wait before the one retry of a failed transcribe.
    var transcribeRetryDelay: Duration = .seconds(1)

    /// Transcribes with one retry of the same audio. While the call reconnects to Hermes
    private func transcribe(audio: Data, mimeType: String) async throws -> String {
        guard await link.ready() else { throw BotFailure.transport }
        let key = try await ensureSession()
        do { return try await backend.transcribeVoice(sessionKey: key, audio: audio, mimeType: mimeType) } catch {
            let ns = error as NSError
            onError?("transcribe-retry", "\(ns.domain):\(ns.code)")
            try? await Task.sleep(for: transcribeRetryDelay)
            guard !isEnded else { throw error }
            return try await backend.transcribeVoice(sessionKey: key, audio: audio, mimeType: mimeType)
        }
    }

    /// A finished utterance as text (the speech that was going on has ended). Empty means no speech: keep listening.
    func utterance(text raw: String) async {
        await deliver(text: raw)
    }

    /// Words from the utterance queue; speech that started since then keeps its hold.
    private func deliver(text raw: String) async {
        guard !isEnded else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { transcript.hearingEnded(); releaseHold(); settle(); return }
        commitHold()
        caption = text
        if let approval = pendingApproval { transcript.hearingEnded(); await answerApproval(approval, text); return }
        if let question = pendingQuestion, await answerQuestion(question, text) { transcript.hearingEnded(); return }
        if VoiceText.isStopCommand(text) {
            transcript.hearingEnded()
            if turnRunning, !rejectingTurn, let runtime {
                // Stop this turn, stay in voice; its leftover frames are dropped.
                _ = try? await backend.call(.sessionInterrupt(sessionID: runtime))
                transcript.interrupt()
                stopSpeaking(reason: "stop-phrase")
                turnRunning = false
                rejectingTurn = true
                rejectDeadline = now().addingTimeInterval(Self.rejectSettleTimeout)
                queuedAfterReject = nil
                phase = .listening
            } else { await end() }
            return
        }
        if rejectingTurn {
            // Submitted when the rejected turn's `message.complete` arrives.
            queuedAfterReject = [queuedAfterReject, text].compactMap { $0 }.joined(separator: " ")
            transcript.userSent(text)
            player.earcon()
            phase = .sending
            return
        }
        do {
            guard await link.ready(), !isEnded else { return }
            _ = try await ensureSession()
            guard let runtime else { throw BotFailure.stale }
            player.earcon()
            if turnRunning {
                _ = try await backend.call(.sessionSteer(sessionID: runtime, text: text))
                transcript.hearingEnded()
                transcript.steered(text)
                steersSent += 1
                phase = .working(nil)
                return
            }
            transcript.userSent(text)
            try await submit(text, runtime: runtime)
        } catch {
            turnRunning = false
            announce(String(localized: "Sorry, I could not reach Hermes for that request."))
        }
    }

    private func submit(_ text: String, runtime: String) async throws {
        let interrupted = interruptedNext
        interruptedNext = false
        beginTurn()
        let reply = try await backend.call(.voicePromptSubmit(sessionID: runtime, text: text, interrupted: interrupted))
        turnsSubmitted += 1
        lastSubmitInterrupted = interrupted
        // Busy session (`_handle_busy_submit`): "redirected"/"steered" = the live
        // turn now carries these words, so its frames are the answer; "queued" =
        // a new turn starts (message.start) after the old one ends.
        if let status = reply["status"].text, status == "redirected" || status == "steered" { staleUntilStart = false }
    }

    private func beginTurn() {
        lastSoftTone = nil
        turnRunning = true
        replyStarted = false
        replyText = ""
        latestTool = nil
        pacer.reset(sentAt: now())
        phase = .working(nil)
    }

    private func ensureSession() async throws -> String {
        if let sessionKey { return sessionKey }
        let reply = try await backend.call(.voiceSessionCreate)
        guard let live = reply["session_id"].text, let key = reply["stored_session_id"].text, !key.isEmpty
        else { throw BotFailure.unsupported }
        runtime = live
        // authoritative ownership survives the runtime's End.
        sessionProfile = reply["info"]["profile_name"].text ?? reply["info"]["profile"].text ?? resumeProfile
        sessionKey = key
        onSessionCreated?(key)
        return key
    }

    // MARK: Events

    private func handle(_ frame: BotJSON) {
        link.saw(frame, runtime: runtime)
        if let request = BotServerRequest(frame) {
            guard request.sessionID == runtime else { return }
            handle(request)
            return
        }
        guard let runtime, frame["session_id"].text == runtime, let type = frame["type"].text else { return }
        let payload = frame["payload"]
        hermesStatus.apply(type, payload, at: now())
        switch type {
        case "message.start":
            guard !rejectingTurn else { return }
            staleUntilStart = false
            // Our own submit, or a turn the server started itself (a re-queued steer).
            if !turnRunning { beginTurn() }
            transcript.gatewayEvent(type, payload)
        case "message.delta":
            guard !rejectingTurn, !staleUntilStart, let text = payload["text"].text, !text.isEmpty else { return }
            if !turnRunning { beginTurn() }
            transcript.gatewayEvent(type, payload)
            startReply()
            replyText += text
            speak(VoiceText.applyPronunciations(text, settings.pronunciations))
        case "message.complete":
            if staleUntilStart { return }  // the timed-out rejected turn finishing late
            turnRunning = false
            if rejectingTurn {
                rejectingTurn = false
                rejectDeadline = nil
                guard let words = queuedAfterReject else { settle(); return }
                queuedAfterReject = nil
                Task {
                    do { try await self.submit(words, runtime: runtime) } catch {
                        self.turnRunning = false
                        self.announce(String(localized: "Sorry, I could not reach Hermes for that request."))
                    }
                }
                return
            }
            transcript.gatewayEvent(type, payload)
            if replyText.isEmpty, let text = payload["text"].text, !text.isEmpty {
                startReply()
                replyText = text
                speak(VoiceText.applyPronunciations(text, settings.pronunciations))
            }
            if speaking == .reply || queuedReply != nil { replyTextDone() }
            else if speech == nil, pendingSpeech == nil { settle() }
        case "tool.start":
            guard !rejectingTurn, !staleUntilStart else { return }
            if !turnRunning { beginTurn() }
            latestTool = payload["name"].text
            transcript.gatewayEvent(type, payload)
            tick()
        case "tool.complete", "reasoning.delta", "message.interim":
            guard !rejectingTurn, !staleUntilStart else { return }
            transcript.gatewayEvent(type, payload)
        default: return
        }
    }

    private func handle(_ request: BotServerRequest) {
        switch request.pending {
        case .approval(let approval)?:
            pendingApproval = approval
            let what = approval.command ?? approval.consequence ?? String(localized: "run an action")
            announce(String(localized: "Hermes wants to \(what). Say approve or deny."))
        case .question(let question)?:
            guard let first = question.questions.first, question.questions.count == 1 else {
                onNeedsApp?(String(localized: "Hermes has a question that needs the app."))
                announce(String(localized: "Hermes has a question that needs the app."))
                return
            }
            pendingQuestion = question
            var line = first.prompt
            for (index, choice) in first.choices.enumerated() { line += " \(index + 1): \(choice.label)." }
            announce(line)
        case .credential?:
            onNeedsApp?(String(localized: "Hermes needs a password or secret. That needs the app."))
            announce(String(localized: "That needs the app."))
        default: return
        }
    }

    private func answerApproval(_ approval: BotApprovalRequest, _ text: String) async {
        guard let answer = VoiceText.approvalAnswer(text), let runtime else {
            say(String(localized: "Say approve or deny."))
            return
        }
        // Voice approves once only, never for the session or always. A request
        // without `once` stays pending for the app instead of being denied.
        if answer == .approve, !approval.choices.contains(.once) {
            onNeedsApp?(String(localized: "Hermes is waiting for an approval that needs the app."))
            announce(String(localized: "That one needs the app."))
            return
        }
        let choice: BotApprovalRequest.Choice = answer == .approve ? .once : .deny
        pendingApproval = nil
        _ = try? await backend.call(.approvalRespond(sessionID: runtime, requestID: approval.requestID, choice: choice))
        phase = .working(nil)
    }

    private func answerQuestion(_ question: BotQuestionRequest, _ text: String) async -> Bool {
        guard let first = question.questions.first,
              let index = VoiceText.choiceIndex(text, choices: first.choices.map(\.label)) else { return false }
        pendingQuestion = nil
        _ = try? await backend.call(.requestAnswer(id: question.requestID, result: .answer(first.choices[index].wireLabel)))
        phase = .working(nil)
        return true
    }

    // MARK: Speaking

    /// The reply takes over the speaker: a progress line still playing is cut. A
    /// NEW turn's reply (the previous reply already got `done`) while the previous
    /// one still plays is queued and plays right after it, never into a finished stream.
    private func startReply() {
        if speaking == .reply {
            if replyDoneSent, queuedReply == nil {
                queuedReply = PendingSpeech()
            }
            return
        }
        if speaking == .line { stopSpeaking(reason: "reply") }
        replyStarted = true
        speaking = .reply
        replyDoneSent = false
        openSpeech()
    }

    private func speak(_ text: String) {
        if let queuedReply { queuedReply.texts.append(text); return }
        if let speech { speech.send(text: text) } else { pendingSpeech?.texts.append(text) }
        streamChars += text.count
    }

    private func openSpeech(_ placeholder: PendingSpeech = PendingSpeech()) {
        guard speech == nil, pendingSpeech == nil else { return }
        pendingSpeech = placeholder
        streamIndex += 1
        let index = streamIndex
        let kind = speaking == .line ? "line" : "reply"
        streamOpened = now()
        streamChars = placeholder.texts.reduce(0) { $0 + $1.count }
        streamBytes = 0
        streamFirstPCM = nil
        streamLastPCM = nil
        playerDrySince = nil
        streamStarted = false
        onTTS?("opened", ["stream": index, "kind": kind])
        Task { [weak self] in
            guard let self else { return }
            do {
                let socket = try await self.backend.openSpeakStream()
                guard self.pendingSpeech === placeholder, !self.isEnded else {
                    socket.cancel()
                    self.onTTS?("dropped", ["stream": index, "reason": "replaced-before-open"])
                    return
                }
                let stream = VoiceSpeakStream(socket: socket)
                stream.onEvent = { [weak self, weak stream] event in
                    guard let self, let stream, self.speech === stream else { return }
                    self.speechEvent(event)
                }
                self.speech = stream
                self.pendingSpeech = nil
                stream.start()
                for text in placeholder.texts { stream.send(text: text) }
                if placeholder.done { stream.done() }
                self.onTTS?("socket", ["stream": index, "open_ms": self.msSinceOpened(), "chars_sent": placeholder.texts.reduce(0) { $0 + $1.count },
                                       "done_sent": placeholder.done])
            } catch {
                guard self.pendingSpeech === placeholder else { return }
                self.onTTS?("failed", ["stream": index, "reason": "open", "open_ms": self.msSinceOpened()])
                self.pendingSpeech = nil
                self.speaking = nil
                self.speechFinished()
            }
        }
    }

    /// Sends `done` on the reply being spoken, or marks the queued/pending one done.
    private func replyTextDone() {
        if let queuedReply { queuedReply.done = true; return }
        guard speaking == .reply else { return }
        replyDoneSent = true
        if let speech { speech.done() } else { pendingSpeech?.done = true }
        onTTS?("done-sent", ["stream": streamIndex, "chars": streamChars, "ms": msSinceOpened()])
    }

    /// One stream ended: a queued reply plays next, else settle.
    private func speechFinished() {
        if let next = queuedReply, !isEnded {
            queuedReply = nil
            speaking = .reply
            replyDoneSent = next.done
            openSpeech(next)
            if let speech, next.done { speech.done() }
            return
        }
        settle()
    }

    /// Text that arrived while the speak-stream ticket and socket were opening.
    private final class PendingSpeech { var texts: [String] = []; var done = false }
    private var pendingSpeech: PendingSpeech?
    /// The next turn's reply, waiting for the current one to finish playing.
    private var queuedReply: PendingSpeech?
    private var replyDoneSent = false
    var hasQueuedReply: Bool { queuedReply != nil }

    var onTTS: ((String, [String: Any]) -> Void)?
    private var streamIndex = 0
    private var streamOpened = Date()
    private var streamChars = 0
    private var streamBytes = 0
    private var streamFirstPCM: Int?
    private var streamLastPCM: Date?
    private func msSinceOpened() -> Int { Int((now().timeIntervalSince(streamOpened) * 1000).rounded()) }

    private func speechEvent(_ event: VoiceSpeakStream.Event) {
        switch event {
        case .start(let rate, let channels):
            onTTS?("start", ["stream": streamIndex, "ms": msSinceOpened(), "rate": rate])
            player.beginSpeech(sampleRate: rate, channels: channels)
            streamStarted = true
            // Held for the user's speech: it starts when that utterance ends (`releaseHold`).
            if !holding { phase = .speaking }
        case .pcm(let data):
            if streamFirstPCM == nil {
                stallRetried = false
                speechSlow = false
                streamFirstPCM = msSinceOpened()
                onTTS?("first-pcm", ["stream": streamIndex, "ms": streamFirstPCM ?? 0])
            }
            streamBytes += data.count
            streamLastPCM = now()
            playerDrySince = nil
            pcmBytesReceived += data.count
            player.enqueue(pcm: data)
        case .end:
            let finished = speech
            onTTS?("end", ["stream": streamIndex, "ms": msSinceOpened(), "bytes": streamBytes, "chars": streamChars])
            player.finishSpeech { [weak self] in
                guard let self, self.speech === finished else { return }
                self.speech = nil
                self.speaking = nil
                self.speechFinished()
            }
        case .fallback:
            onTTS?("end", ["stream": streamIndex, "reason": "fallback", "bytes": streamBytes])
            let text = speech?.sentText ?? ""
            speech = nil
            Task { [weak self] in
                guard let self, !text.isEmpty, let clip = try? await self.backend.speakClip(text) else {
                    self?.speaking = nil; self?.speechFinished(); return
                }
                self.streamStarted = true
                if !self.holding { self.phase = .speaking }
                self.player.playClip(clip) { [weak self] in self?.speaking = nil; self?.speechFinished() }
            }
        case .failed:
            onTTS?("failed", ["stream": streamIndex, "reason": "socket", "ms": msSinceOpened(), "bytes": streamBytes])
            speech = nil
            speaking = nil
            speechFinished()
        }
    }

    /// A line the user should also see in the transcript (errors, prompts), then spoken.
    private func announce(_ line: String) {
        guard !isEnded, !line.isEmpty else { return }
        notice = line
        say(line)
    }

    /// Speaks a line of our own (approval prompts, progress, errors).
    func say(_ line: String) {
        guard !isEnded, !line.isEmpty else { return }
        stopSpeaking(reason: "line")
        speaking = .line
        openSpeech()
        speak(line)
        if let speech { speech.done() } else { pendingSpeech?.done = true }
    }

    private func settle() {
        guard !isEnded, speech == nil, pendingSpeech == nil else { return }
        speaking = nil
        phase = turnRunning ? .working(latestTool.map(VoiceText.progressPhrase)) : .listening
    }

    /// The rejected turn's complete didn't come within 5 s: stop waiting for it.
    /// Queued words are submitted now (the server takes a submit on a busy
    /// session: redirect or queue, never a refusal); without words, Listening.
    private func rejectTimedOut() {
        rejectingTurn = false
        rejectDeadline = nil
        staleUntilStart = true
        turnRunning = false
        guard let words = queuedAfterReject, let runtime else { settle(); return }
        queuedAfterReject = nil
        Task {
            do { try await self.submit(words, runtime: runtime) } catch {
                self.turnRunning = false
                self.announce(String(localized: "Sorry, I could not reach Hermes for that request."))
            }
        }
    }

    static let stallTimeout: TimeInterval = 20
    /// After this long without first audio the screen says the voice is slow.
    static let slowNoticeAfter: TimeInterval = 5
    /// True while a stream has been waiting for its first audio for `slowNoticeAfter`.
    private(set) var speechSlow = false
    private var stallRetried = false
    /// When a tick first saw the player with nothing left to play in this stream.
    private var playerDrySince: Date?
    private func stallCheck() {
        guard let speech, !speech.finished, speech.doneSent else { speechSlow = false; return }
        if streamFirstPCM != nil {
            speechSlow = false
            guard player.queuedSpeechSeconds <= 0 else { playerDrySince = nil; return }
            let dry = playerDrySince ?? now()
            playerDrySince = dry
            guard let last = streamLastPCM, now().timeIntervalSince(max(last, dry)) >= Self.stallTimeout else { return }
        } else {
            let waited = now().timeIntervalSince(streamOpened)
            speechSlow = waited >= Self.slowNoticeAfter
            guard waited >= Self.stallTimeout else { return }
        }
        let text = speech.sentText
        let wasSpeaking = speaking
        if streamFirstPCM != nil {
            // Mid-stream: the server stopped sending audio and never sent `end` (its TTS
            // request hung). Play what arrived, then move on instead of sitting in Speaking.
            onTTS?("stalled", ["stream": streamIndex, "ms": msSinceOpened(), "chars": text.count, "bytes": streamBytes, "mid": true])
            streamLastPCM = now()
            playerDrySince = nil
            let finished = speech
            speech.close()
            player.finishSpeech { [weak self] in
                guard let self, self.speech === finished else { return }
                self.speech = nil
                self.speaking = nil
                self.speechFinished()
            }
            return
        }
        onTTS?("stalled", ["stream": streamIndex, "ms": msSinceOpened(), "chars": text.count, "retry": !stallRetried])
        speech.close()
        self.speech = nil
        guard !stallRetried, !text.isEmpty, let wasSpeaking else {
            stallRetried = false
            speaking = nil
            speechFinished()
            return
        }
        stallRetried = true
        let again = PendingSpeech()
        again.texts = [text]
        again.done = true
        speaking = wasSpeaking
        openSpeech(again)
    }

    /// Progress cadence; the screen calls this every second.
    func tick() {
        if rejectingTurn, let deadline = rejectDeadline, now() >= deadline { rejectTimedOut() }
        stallCheck()
        if settings.progress == .tones, turnRunning, !replyStarted, speech == nil, pendingSpeech == nil {
            // Soft sound: a quiet tone every `softToneInterval` while Hermes works, nothing spoken.
            let t = now()
            if t.timeIntervalSince(lastSoftTone ?? pacer.sentAt ?? t) >= Self.softToneInterval {
                lastSoftTone = t
                player.softTone()
            }
        }
        guard turnRunning, speech == nil, pendingSpeech == nil else { return }
        guard let line = pacer.phrase(latestTool: latestTool, now: now(), replyStarted: replyStarted) else {
            if let tool = latestTool { phase = .working(VoiceText.progressPhrase(tool: tool)) }
            return
        }
        phase = .working(line)
        switch settings.progress {
        case .spoken: say(line)
        case .tones, .off: return
        }
    }

    static let softToneInterval: TimeInterval = 4
    private var lastSoftTone: Date?
    // MARK: Ending

    /// Ends the voice session: stop speech, clear the mark, and leave the socket. Never
    /// `session.close`: that tears the chat's runtime down on the server (interrupting its async
    /// delegations, killing its background processes, ending the chat's row), and the work the
    /// client disconnect; the server finishes its work and retires it on its own lifecycle.
    func end() async {
        guard !isEnded else { return }
        stopSpeaking(reason: "end")
        pendingSpeech = nil
        holding = false
        phase = .ended(nil)
        link.cancel()
        backend.close()
    }
}
