import Foundation

/// starts until End or until the call ends on its own; the full voice screen and the floating
/// bubble are two views of it. Closing or minimizing either never ends it.
@MainActor @Observable final class VoiceCall: Identifiable {
    let id = UUID()
    let presentation: VoiceCallPresentation
    /// with its controls disabled from then until it has closed into the chat. A call never
    /// leaves this state, so its screen still reads "Ending…" while it slides away.
    fileprivate(set) var isEnding = false
    /// Nil when this server has no saved Hermes connection: the screen says so ("Connect to Hermes").
    let model: VoiceScreenModel?

    init(presentation: VoiceCallPresentation, model: VoiceScreenModel?) {
        self.presentation = presentation
        self.model = model
    }

    var server: URL { presentation.server }
    /// The chat the call talks in: the resumed one, or the one its first request created.
    var chatKey: String? { model?.sessionKey }
}

/// opens `chatKey`; the call's own chat reloads its transcript either way.
struct VoiceCallEnded: Equatable {
    let id = UUID()
    let server: URL
    let chatKey: String?
    /// End was tapped (not a dropped connection or error).
    let byUser: Bool
    /// The owning Profile reported by the host, never the list currently selected.
    let profile: String?

    init(server: URL, chatKey: String?, byUser: Bool, profile: String? = nil) {
        self.server = server; self.chatKey = chatKey; self.byUser = byUser; self.profile = profile
    }

    var hermesTarget: ConversationTarget? {
        guard let chatKey, let profile, !profile.isEmpty else { return nil }
        return .session(profile: profile, key: chatKey)
    }
}

/// entry point and released only by End, by the call ending on its own, or by a server switch.
@MainActor @Observable final class VoiceCallController {
    static let shared = VoiceCallController()

    private(set) var call: VoiceCall?
    /// The full voice screen is up (false = minimized to the floating bubble).
    private(set) var isExpanded = false
    /// Why the last call ended on its own (dropped connection, error); shown as a short banner.
    private(set) var endedBanner: String?
    /// The last call's release, observed by the chat list and the call's chat.
    private(set) var lastEnded: VoiceCallEnded?
    /// GPT-Live's end-of-call turn completes after the call is released, so its chat reloads
    /// a second time on this.
    private(set) var lastSettled: VoiceCallEnded?
    private var bannerTask: Task<Void, Never>?
    var isEnding: Bool { call?.isEnding == true }
    /// Opens the chat an ended call worked in (the chat list registers it). End awaits it
    /// while the voice screen is still up, so the screen closes straight into that chat.
    @ObservationIgnored var chatOpener: ((VoiceCallEnded) async -> Void)?
    @ObservationIgnored private var openingChat: String?
    @ObservationIgnored private var openingChatReady = false
    @ObservationIgnored private var openingChatWaiter: CheckedContinuation<Void, Never>?

    /// A call is running: every other voice entry point, the composer's dictation mic and
    /// "Listen" are disabled until it ends.
    var isRunning: Bool { call != nil }

    /// The running call's chat, as a conversation the user is in: its replies don't banner
    var pushViewer: PushPresence.Viewer? {
        guard let call else { return nil }
        return call.model?.engineSession?.pushViewer(server: call.server)
    }

    /// Starts a call from an entry point. Refused (false) while one runs.
    @discardableResult
    func start(_ presentation: VoiceCallPresentation) -> Bool {
        let connection = presentation.connection ?? (try? BotConnectionStore().load(server: presentation.server))
        let model = connection.map {
            VoiceScreenModel(server: presentation.server, connection: $0, resumeSessionKey: presentation.resumeSessionKey,
                             resumeProfile: presentation.resumeProfile, requestedMode: presentation.requestedMode)
        }
        return start(presentation, model: model, begin: { await $0.start() })
    }

    /// (never a second call), else a new call like the chat list's waveform button.
    func openOrStart(_ presentation: VoiceCallPresentation) {
        if call != nil { expand() } else { start(presentation) }
    }

    /// `begin` runs the model's startup (the network and audio path in the app; tests hand in
    /// an engine of their own).
    @discardableResult
    func start(_ presentation: VoiceCallPresentation, model: VoiceScreenModel?,
               begin: @escaping (VoiceScreenModel) async -> Void) -> Bool {
        guard call == nil else { return false }
        let call = VoiceCall(presentation: presentation, model: model)
        self.call = call
        isExpanded = true
        clearBanner()
        if let model {
            model.onEndedByItself = { [weak self, weak call] reason in
                guard let self, let call else { return }
                self.release(call, banner: reason.map { String(localized: "Voice call ended: \($0)") }
                             ?? String(localized: "Voice call ended."))
            }
            Task { await begin(model) }
        }
        return true
    }

    /// Top edge, in window coordinates, of the bottom controls on screen (a chat's message
    /// follows them up when the keyboard lifts them. Reported by `voiceBubbleClearance()`.
    var composerTop: CGFloat? { bottomControls?.top }
    private var bottomControls: (owner: UUID, top: CGFloat)?

    /// The screen `owner` now on screen has bottom controls whose top edge is at `top`.
    func reportBottomControls(owner: UUID, top: CGFloat) {
        guard bottomControls?.owner != owner || bottomControls?.top != top else { return }
        bottomControls = (owner, top)
    }

    /// `owner` left the screen; a screen that has reported since keeps its value.
    func clearBottomControls(owner: UUID) {
        if bottomControls?.owner == owner { bottomControls = nil }
    }

    /// The voice header's chevron or a swipe down: the call keeps running behind the bubble.
    /// Not while it is ending: that screen closes into the chat.
    func minimize() {
        guard !isEnding else { return }
        isExpanded = false
    }

    /// The bubble, or opening the call's chat from anywhere.
    func expand() {
        guard call != nil else { return }
        isExpanded = true
    }

    /// True when `sessionID` on `server` is the running call's chat: opening it opens the voice
    func opensCall(sessionID: String?, server: URL) -> Bool {
        guard let call, !isEnding, call.server == server, let sessionID, !sessionID.isEmpty,
              call.chatKey == sessionID else { return false }
        expand()
        return true
    }

    /// ends (its work runs on), then the chat it worked in opens (`chatOpener`), and only then
    /// is the call released and the screen closed. Returns that chat; nil when there was no
    /// call, an End is already running, or the call made no chat.
    @discardableResult
    func end(opensChat: Bool = true) async -> String? {
        guard let call, !call.isEnding else { return nil }
        call.isEnding = true
        let profile = call.model?.sessionProfile
        let key = await call.model?.endAndReturnChat()
        let ended = VoiceCallEnded(server: call.server, chatKey: key, byUser: true, profile: profile)
        if opensChat, key != nil, let chatOpener { await chatOpener(ended) }
        self.call = nil
        isExpanded = false
        lastEnded = ended
        let model = call.model
        Task { [weak self] in await self?.settle(model, ended) }
        return key
    }

    /// Sets `lastSettled` to `ended` once `model`'s ended engine reports its chat work finished.
    /// Callers end the engine first: the work to wait for exists only after `end()`.
    private func settle(_ model: VoiceScreenModel?, _ ended: VoiceCallEnded) async {
        await model?.awaitChatWorkSettled()
        lastSettled = ended
    }

    /// and this returns once that chat's screen reported `chatScreenReady`, so "Ending…" stays
    /// up until the chat can show its messages and the cover never leaves a loading chat.
    func openChatAndAwaitReady(_ key: String, open: () -> Void) async {
        openingChat = key
        openingChatReady = false
        defer {
            openingChat = nil
            openingChatReady = false
        }
        open()
        if openingChatReady { return }
        await withCheckedContinuation { openingChatWaiter = $0 }
    }

    /// A chat screen can show its transcript: its messages are drawn (from the cache or the
    /// server) or its load finished (empty, or the load's own error state). Ends the wait of
    /// `openChatAndAwaitReady` for that chat; other chats are ignored.
    func chatScreenReady(sessionID: String) {
        guard sessionID == openingChat, !openingChatReady else { return }
        openingChatReady = true
        openingChatWaiter?.resume()
        openingChatWaiter = nil
    }

    /// The signed-in server changed (or signed out): a call on another server ends, without
    /// opening its chat (that chat belongs to the old server).
    func activeServerChanged(to server: URL?) {
        guard let call, call.server != server else { return }
        Task { await end(opensChat: false) }
    }

    func dismissBanner() { clearBanner() }

    private func release(_ ending: VoiceCall, banner: String) {
        guard call === ending else { return }
        call = nil
        isExpanded = false
        let model = ending.model
        let ended = VoiceCallEnded(server: ending.server, chatKey: ending.chatKey, byUser: false, profile: model?.sessionProfile)
        lastEnded = ended
        Task { [weak self] in
            await model?.end()
            await self?.settle(model, ended)
        }
        bannerTask?.cancel()
        endedBanner = banner
        // The banner's reading time: it goes by itself after 4 s (or on tap).
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.endedBanner = nil
        }
    }

    private func clearBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        endedBanner = nil
    }
}
