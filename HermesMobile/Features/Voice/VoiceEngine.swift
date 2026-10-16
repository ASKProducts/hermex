import Foundation

/// One launch identity carries all call inputs into native item presentation.
/// The presented screen consumes this value, not independently updated parent state.
struct VoiceCallPresentation: Identifiable {
    let id = UUID()
    let server: URL
    let requestedMode: VoiceMode
    let resumeSessionKey: String?
    let resumeProfile: String?
    let connection: BotConnection?

    init(server: URL, requestedMode: VoiceMode, resumeSessionKey: String? = nil, resumeProfile: String? = nil, connection: BotConnection? = nil) {
        self.server = server
        self.requestedMode = requestedMode
        self.resumeSessionKey = resumeSessionKey
        self.resumeProfile = resumeProfile
        self.connection = connection
    }
}

/// The exact saved dashboard connection, scoped to its app server.
struct VoiceStartScope: Equatable {
    let server: URL
    let connection: BotConnection?

    @MainActor static func current(server: URL) -> Self {
        current(server: server, store: BotConnectionStore())
    }

    @MainActor static func current(server: URL, store: BotConnectionStore) -> Self {
        Self(server: server, connection: try? store.load(server: server))
    }
}

@MainActor @Observable final class VoiceStartAvailability {
    enum State: Equatable {
        case checking
        case available
        case unavailable(String)
        case failed

        var liveAvailable: Bool { self == .available }
        var reason: String? {
            switch self {
            case .checking: return String(localized: "Checking GPT-Live…")
            case .available: return nil
            case .unavailable(let reason): return reason
            case .failed: return String(localized: "Couldn't check GPT-Live.")
            }
        }
    }

    private(set) var state: State = .checking
    private(set) var scope: VoiceStartScope?
    private var requestID: UUID?

    func offersVoice(for scope: VoiceStartScope) -> Bool {
        self.scope == scope && scope.connection != nil
    }

    func state(for scope: VoiceStartScope) -> State { self.scope == scope ? state : .checking }

    /// SwiftUI owns cancellation. Request identity and the actual connection prevent an old
    /// completion from enabling GPT-Live on a different server or after credentials change.
    func refresh(scope: VoiceStartScope,
                 load: (VoiceStartScope) async throws -> VoiceLive.Status? = VoiceStartAvailability.fetch,
                 currentScope: () -> VoiceStartScope) async {
        let requestID = UUID()
        self.requestID = requestID
        self.scope = scope
        state = .checking
        do {
            guard !Task.isCancelled, self.requestID == requestID, currentScope() == scope else { return }
            guard offersVoice(for: scope) else { state = .unavailable(String(localized: "This Hermes has no GPT-Live.")); return }
            let status = try await load(scope)
            guard !Task.isCancelled, self.requestID == requestID, currentScope() == scope else { return }
            state = status?.unavailableReason.map(State.unavailable) ?? (status == nil ? .unavailable(String(localized: "This Hermes has no GPT-Live.")) : .available)
        } catch {
            guard !Task.isCancelled, self.requestID == requestID, currentScope() == scope else { return }
            state = .failed
        }
    }

    static func fetch(_ scope: VoiceStartScope) async throws -> VoiceLive.Status? {
        guard let connection = scope.connection else { throw BotFailure.missingChat }
        let client = BotClient(saved: connection, server: scope.server)
        defer { client.close() }
        try await client.connect()
        return try await client.voiceLiveStatus()
    }


}

/// The voice screen's one engine interface. `VoiceSession` (Normal: on-device endpointing,
/// Hermes STT/TTS) and `VoiceLiveConversation` (GPT-Live over WebRTC) both implement it, so
/// `VoiceScreen` renders the same header, transcript and dock for either.
@MainActor protocol VoiceEngine: AnyObject {
    var mode: VoiceMode { get }
    var phase: VoiceSession.Phase { get }
    /// The screen's transcript in the chat's turn model; the screen hands its own in.
    var transcript: VoiceTranscriptModel { get set }
    /// The user's words while they are still talking.
    var caption: String { get }
    /// The latest line of our own (errors, approval prompts), shown above the dock.
    var notice: String? { get }
    /// The dashboard chat this session talks in (nil until the first turn creates it).
    var sessionKey: String? { get }
    /// The Profile named by the host create/resume response.
    var sessionProfile: String? { get }
    var isEnded: Bool { get }
    var speechSlow: Bool { get }
    /// An approval Hermes is waiting on in this chat (answered by voice or in the app).
    var pendingApproval: BotApprovalRequest? { get }
    /// What Hermes is doing for this chat, from its own gateway events (the status line).
    var hermesStatus: VoiceHermesStatus { get }
    var debugLine: String { get }
    func tapToInterrupt()
    /// The screen's clock (Normal: every second; GPT-Live: every 200 ms, see `tickInterval`).
    func tick()
    var tickInterval: Duration { get }
    func end() async
    /// The saved chat End may open; nil when a new call's first message was not accepted.
    func chatForOpening() async -> String?
    /// end-of-call turn ("Voice call ended…" and its reply) completes after the call is gone.
    func awaitChatWorkSettled() async
}

@MainActor extension VoiceEngine {
    var sessionProfile: String? { nil }
    func chatForOpening() async -> String? { sessionKey }
}

/// The voice screen's status line: what Hermes's gateway says it is doing for this chat, never
/// the voice model's record. `since` is when the current step began; the screen only counts up
/// from it (nothing decides "stalled" from elapsed time).
struct VoiceHermesStatus: Equatable {
    enum State: Equatable {
        /// No Hermes turn running.
        case idle
        /// A turn runs between steps (the model streams reasoning or text).
        case thinking
        /// A tool runs (its gateway `name`).
        case working(tool: String)
        /// A turn ended without a reply while the request it was answering was still open.
        case stopped
    }

    private(set) var state: State = .idle
    private(set) var since: Date?

    /// One gateway frame of this chat.
    mutating func apply(_ type: String, _ payload: BotJSON, at now: Date) {
        switch type {
        case "message.start":
            move(.thinking, at: now)
        case "tool.start":
            move(.working(tool: payload["name"].text ?? ""), at: now)
        case "tool.complete":
            move(.thinking, at: now)
        case "message.delta", "reasoning.delta", "message.interim":
            // A turn already running when the screen joined it: it streams, so it thinks.
            if state == .idle || state == .stopped { move(.thinking, at: now) }
        case "message.complete":
            move(.idle, at: nil)
        default:
            break
        }
    }

    /// The turn that was answering an open request ended without a reply.
    mutating func turnEndedWithoutReply() { move(.stopped, at: nil) }

    /// The state's name for the flight recorder (the tool's gateway name, no arguments).


    private mutating func move(_ next: State, at now: Date?) {
        state = next
        since = now
    }

    /// "Working: Running a command · 0:12", "Thinking · 0:03", "Idle", "Stopped: …".
    func label(now: Date) -> String {
        switch state {
        case .idle:
            return String(localized: "Idle")
        case .stopped:
            return String(localized: "Stopped: your last request got no answer")
        case .thinking:
            return String(localized: "Thinking · \(elapsed(now))")
        case .working(let tool):
            var step = VoiceText.progressPhrase(tool: tool)
            if step.hasSuffix(".") { step.removeLast() }
            return String(localized: "Working: \(step) · \(elapsed(now))")
        }
    }

    private func elapsed(_ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since ?? now).rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

enum VoiceMode: String, CaseIterable {
    case normal, live

    var title: String {
        switch self {
        case .normal: return String(localized: "Speech-to-text + Hermes voice")
        case .live: return String(localized: "GPT-Live")
        }
    }

    var systemImage: String {
        switch self {
        case .normal: return "waveform"
        case .live: return "bolt.horizontal.fill"
        }
    }

    /// The call's mode line in the voice settings sheet.
    var modeLine: String { String(localized: "Mode: \(title)") }
}

extension VoiceEngine {
    func pushViewer(server: URL) -> PushPresence.Viewer? {
        sessionKey.map { PushPresence.Viewer(server: server, sessionID: $0) }
    }
}

extension VoiceSession: VoiceEngine {
    var mode: VoiceMode { .normal }
    /// Normal's `end()` sends no turn of its own: nothing is left to settle.
    func awaitChatWorkSettled() async {}
    var tickInterval: Duration { .seconds(1) }
    var debugLine: String {
        "PCM \(pcmBytesReceived) B · turns \(turnsSubmitted) · steers \(steersSent) · fallback \(usedServerFallback) · interrupted \(lastSubmitInterrupted ? "yes" : "no")"
    }
}


/// Switching modes mid-session, or Continue by voice: the next engine continues in the same chat;
/// GPT-Live gets what was said so far as seed history (from the transcript's rows).
struct VoiceHandoff: Equatable {
    var resumeSessionKey: String?
    var earlier: [Line]

    struct Line: Equatable {
        var fromUser: Bool
        var text: String
    }

    /// From the transcript's rows (saved, and GPT-Live's local ones): user and assistant text, in order.
    init(sessionKey: String?, fallbackKey: String?, messages: [ChatMessage]) {
        resumeSessionKey = sessionKey ?? fallbackKey
        earlier = messages.compactMap { message in
            guard let role = message.role, role == "user" || role == "assistant", !message.isSteerMessage,
                  let text = message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return Line(fromUser: role == "user", text: text)
        }
    }

    init(resumeSessionKey: String?, earlier: [Line]) {
        self.resumeSessionKey = resumeSessionKey
        self.earlier = earlier
    }

    /// GPT-Live's seed (whole-message limits apply in `VoiceLive.history`).
    var seedTurns: [(role: String, text: String)] {
        earlier.map { ($0.fromUser ? "user" : "assistant", $0.text) }
    }
}
extension VoiceLiveConversation: VoiceEngine {
    var mode: VoiceMode { .live }
    var tickInterval: Duration { .milliseconds(200) }
    var speechSlow: Bool { false }
    var debugLine: String {
        "live · delegations \(delegations) · turns \(turnsSubmitted) · interrupts \(interruptsSent) · cuts \(playoutCuts)"
    }
}
