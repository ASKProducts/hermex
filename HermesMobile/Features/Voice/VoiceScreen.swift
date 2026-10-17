import WebRTC
import AVFoundation
import SwiftUI

/// Display and audio preferences. The engine choice belongs to the Hermes Profile.
enum VoicePreferences {
    static let silenceKey = "voice.pauseBeforeSending"
    static let interruptKey = "voice.interruptByTalking"
    static let progressKey = "voice.progressUpdates"
    static let recognitionKey = "voice.serverTranscription"
    static let pronunciationsKey = "voice.pronunciations"
    /// "On screen": the whole session's transcript or only the current exchange.
    static let transcriptModeKey = "voice.transcriptMode"
    /// The old single "Show Hermes's activity" switch. Only read once, by `migrateShowActivity`.
    static let legacyShowActivityKey = "voice.showActivity"
    /// (delegations are tool calls) and GPT-Live's appends. Settings → Voice → Screen edits the
    /// same keys. Display only: nothing is deleted and the regular chat view ignores them.
    static let showsThinkingAndToolsKey = "voice.show.thinkingAndTools"
    static let showsAppendsKey = "voice.show.appends"
    /// delegation runs. Off by default; off sends nothing new.
    /// The voice transcript's row filter from the two display keys (absent = shown).
    static func segmentFilter(_ defaults: UserDefaults = .standard) -> TranscriptSegmentFilter {
        func shows(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        return TranscriptSegmentFilter(appends: shows(showsAppendsKey), thinkingAndTools: shows(showsThinkingAndToolsKey))
    }

    /// The old switch becomes the two keys, once: its stored value is written to each key not
    /// set yet (off → both off), then removed. Called at launch.
    static func migrateShowActivity(_ defaults: UserDefaults = .standard) {
        guard let old = defaults.object(forKey: legacyShowActivityKey) as? Bool else { return }
        for key in [showsThinkingAndToolsKey, showsAppendsKey]
        where defaults.object(forKey: key) == nil {
            defaults.set(old, forKey: key)
        }
        defaults.removeObject(forKey: legacyShowActivityKey)
    }
    /// Settings → Voice → Default mode: `VoiceMode` raw value.

    static var settings: VoiceSession.Settings {
        let d = UserDefaults.standard
        var s = VoiceSession.Settings()
        if d.object(forKey: interruptKey) != nil { s.interruptByTalking = d.bool(forKey: interruptKey) }
        if d.object(forKey: recognitionKey) != nil { s.useServerTranscription = d.bool(forKey: recognitionKey) }
        if let raw = d.string(forKey: progressKey), let p = VoiceSession.Settings.Progress(rawValue: raw) { s.progress = p }
        s.pronunciations = pronunciations
        return s
    }

    static var silence: TimeInterval {
        let v = UserDefaults.standard.double(forKey: silenceKey)
        return v == 0 ? 1.5 : min(3, max(0.8, v))
    }

    static var pronunciations: [VoiceText.Pronunciation] {
        guard let data = UserDefaults.standard.data(forKey: pronunciationsKey),
              let list = try? JSONDecoder().decode([VoiceText.Pronunciation].self, from: data) else { return VoiceText.defaultPronunciations }
        return list
    }

    static func savePronunciations(_ list: [VoiceText.Pronunciation]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: pronunciationsKey)
    }

    /// A chat list row gets the mic glyph and "Continue by voice" when true.

    /// What "Continue by voice" offers for a chat in its toolbar menu.
    enum ContinueByVoice: Equatable {
        /// Not offered: cached data, read-only/subagent views, messaging-platform chats
        /// (the reply would never post back there), or a chat whose profile is unknown.
        case hidden
        /// Offered but disabled: the chat is running a turn; a second one would run beside it.
        case busy
        /// `profile`: the chat's profile, sent with `session.resume`.
        case available(profile: String?)
    }

    /// `isBusy`: the caller's live view of the chat (ChatView's stream); nil falls back to
    /// the row's `isStreaming`/`hasPendingUserMessage`/`activeStreamId`.
    static func canContinueByVoice(_ session: SessionSummary, isViewingCachedData: Bool, isBusy: Bool? = nil) -> ContinueByVoice {
        guard !isViewingCachedData, let key = session.sessionId, BotVoiceRPC.isValidSessionKey(key),
              !session.isSessionReadOnly, !session.isMessagingPlatformSession else { return .hidden }
        // Unknown profile: resuming without one could open the wrong profile's state.db.
        guard let profile = session.profile?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty,
              BotVoiceRPC.isValidSessionKey(profile) else { return .hidden }
        let busy = isBusy ?? (session.isStreaming == true || session.hasPendingUserMessage == true
                              || session.activeStreamId?.isEmpty == false)
        if busy { return .busy }
        // Always named: the dashboard may run under another launch profile than the web UI's
        // default, and the host resolves its own profile's name to its own state.db.
        return .available(profile: profile)
    }

}

/// Native menu actions shared by the new-call button and the chat toolbar.
/// No launch occurs until a menu action fires; SwiftUI arbitrates the button/context-menu gestures.
struct VoiceStartMenu: View {
    let availability: VoiceStartAvailability
    let scope: VoiceStartScope
    let start: (VoiceMode) -> Void

    var body: some View {
        Button { start(.normal) } label: {
            Label(VoiceMode.normal.title, systemImage: VoiceMode.normal.systemImage)
        }
        .accessibilityIdentifier("voice-start-normal")
        Button { start(.live) } label: {
            Label(VoiceMode.live.title, systemImage: VoiceMode.live.systemImage)
        }
        .disabled(!availability.state(for: scope).liveAvailable)
        .accessibilityIdentifier("voice-start-live")
        if let reason = availability.state(for: scope).reason {
            Text(reason)
                .accessibilityIdentifier("voice-start-live-reason")
        }
    }
}

/// The Chat options menu's one "Voice" entry: a submenu with the two modes. Inside an open
/// menu a nested menu opens on tap and on hold alike (iOS runs no primary action there).
struct VoiceStartSubmenu: View {
    let availability: VoiceStartAvailability
    let scope: VoiceStartScope
    let start: (VoiceMode) -> Void

    var body: some View {
        if availability.offersVoice(for: scope) {
        Menu {
            VoiceStartMenu(availability: availability, scope: scope, start: start)
        } label: {
            Label("Voice", systemImage: "waveform")
        }
        .accessibilityIdentifier("chat-voice")
        }
    }
}

/// `VoiceScreenModel`, engine and audio) belongs to `VoiceCallController`: this screen only
/// draws it. Minimize (the header's chevron, or a swipe down on the header or dock) leaves the
/// call running behind the floating bubble; End ends it.
/// Layout: a compact status header on top, the session's transcript in the middle, a glass
/// control dock at the bottom.
struct VoiceScreen: View {
    let call: VoiceCall
    let controller: VoiceCallController
    /// Where the call's orb is now (`VoiceCallLayer` draws it); this screen lays out its slot.
    let orbSlot: VoiceOrbSlot
    let orbSpace: Namespace.ID
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(VoicePreferences.transcriptModeKey) private var transcriptMode = VoiceTranscriptModel.Mode.full.rawValue
    @AppStorage(VoicePreferences.showsThinkingAndToolsKey) private var showsThinkingAndTools = true
    @AppStorage(VoicePreferences.showsAppendsKey) private var showsAppends = true
    @AppStorage(AppHaptics.isEnabledKey) private var hapticsEnabled = true
    @AppStorage(HeaderLogoColor.storageKey) private var themeHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @State private var bottomHeight: CGFloat = 0
    @State private var showsSettings = false

    private var model: VoiceScreenModel? { call.model }
    private var connectionMissing: Bool { call.model == nil }
    private var server: URL { call.server }
    private var requestedMode: VoiceMode { call.presentation.requestedMode ?? .normal }

    var body: some View {
        VStack(spacing: 0) {
            if connectionMissing {
                Spacer()
                ContentUnavailableView {
                    Label(String(localized: "Connect to Hermes"), systemImage: "waveform.badge.exclamationmark")
                } description: {
                    Text("Voice uses your Hermes connection. Add it under Bots or Settings, then try again.")
                }
                Spacer()
                dock
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            } else if let model {
                Group {
                    if VoiceScreen.showsEmptyHint(model.transcript, mode: transcriptModeValue, showsAppends: showsAppends) {
                        // Nothing to draw yet: the waveform and one line, in place of the chat's
                        // own empty state ("Send a message to start the conversation.").
                        emptyHint(model.engineSession)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // The native scroll view keeps the safe area reserved by the header.
                        // Its bottom inset clears the overlaid notices and dock.
                        VoiceChatTranscript(model: model.transcript,
                                            mode: transcriptModeValue,
                                            filter: segmentFilter,
                                            bottomInset: bottomHeight,
                                            namespace: "voice:\(server.host() ?? ""):\(model.sessionKey ?? "new")",
                                            onLoadOlder: { await model.loadOlder() })
                    }
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        notices
                        dock
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
                }
            } else {
                Spacer()
                ProgressView()
                Spacer()
                notices
                dock
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
        }
        // Reserve the header for every state through the container's native safe area.
        // Cap chrome at accessibility2, leaving room for the transcript at larger sizes.
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
        .tint(accent)
        .background(Color(.systemBackground).ignoresSafeArea())
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: model?.engineSession?.phase)
        .sensoryFeedback(trigger: model?.engineSession?.phase) { _, new in
            guard hapticsEnabled else { return nil }
            switch new {
            case .speaking?: return .impact(weight: .light)
            case .sending?: return .selection
            case .ended?: return .success
            default: return nil
            }
        }
        // Keep the screen awake only while the call is expanded and active.
        .onChange(of: keepAwake, initial: true) { _, awake in UIApplication.shared.isIdleTimerDisabled = awake }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// drag there scrolls to older rows.
    private var minimizeSwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard value.translation.height > abs(value.translation.width),
                      value.predictedEndTranslation.height > 120 else { return }
                controller.minimize()
            }
    }

    /// The theme color when the user tints primary actions with it, else the app's accent.
    private var accent: Color {
        tintsPrimaryActions ? HeaderLogoColor.color(for: themeHex) : .accentColor
    }

    // MARK: Top

    private var segmentFilter: TranscriptSegmentFilter {
        TranscriptSegmentFilter(appends: showsAppends, thinkingAndTools: showsThinkingAndTools)
    }

    private var callMode: VoiceMode { model?.mode ?? requestedMode }

    private var transcriptModeValue: VoiceTranscriptModel.Mode {
        VoiceTranscriptModel.Mode(rawValue: transcriptMode) ?? .full
    }

    /// and no saved history loading (that shows the chat's loading rows). The screen shows the
    /// voice hint instead of the transcript until the first message.
    static func showsEmptyHint(_ transcript: VoiceTranscriptModel, mode: VoiceTranscriptModel.Mode, showsAppends: Bool) -> Bool {
        transcript.isEmpty
            && transcript.display(mode, TranscriptSegmentFilter(appends: showsAppends)).messages.isEmpty
            && !transcript.isLoadingHistory
    }

    /// engine is listening (also before it is attached, while GPT-Live is checked), then
    /// "Go ahead, I'm listening." until the first message.
    static func emptyHintText(phase: VoiceSession.Phase?) -> String {
        switch phase {
        case nil, .connecting?: return String(localized: "Connecting to Hermes…")
        default: return String(localized: "Go ahead, I'm listening.")
        }
    }

    /// one line.
    private func emptyHint(_ session: (any VoiceEngine)?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion && session?.phase == .listening)
            Text(Self.emptyHintText(phase: session?.phase))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voice-empty-hint")
    }
    private var topBar: some View {
        VoiceTopBar(orb: headerOrb, disabled: call.isEnding,
                    minimize: { controller.minimize() }, settings: { showsSettings = true })
            .sheet(isPresented: $showsSettings) {
                VoiceCallSettingsSheet(mode: callMode)
                    .presentationDetents([VoiceCallSettingsSheet.detent])
                    .presentationDragIndicator(.visible)
            }
    }

    /// The header's orb slot: a clear square the call's one orb is drawn at (`VoiceCallLayer`),
    /// at the top left. It carries the call's status for VoiceOver (the orb drawn on it is
    /// hidden from it). The row up to the buttons takes the swipe down that minimizes.
    private var headerOrb: some View {
        Color.clear
            .frame(width: VoiceOrbMetrics.headerSize, height: VoiceOrbMetrics.headerSize)
            .voiceOrbSource(orbSlot == .header, in: orbSpace)
            .accessibilityElement()
            .accessibilityLabel(orbStatus)
            .accessibilityHidden(model?.engineSession == nil)
            .accessibilityIdentifier("voice-state")
            .frame(maxWidth: .infinity, minHeight: VoiceHeaderButton.size, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(minimizeSwipe)
    }

    private var orbStatus: String {
        guard let session = model?.engineSession else { return "" }
        return VoiceStatusText.orb(phase: session.phase, status: session.hermesStatus,
                                   muted: model?.muted == true, ending: call.isEnding)
    }

    // MARK: Bottom

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 8) {
            if let reason = model?.fallbackReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("voice-start-fallback")
            }
            if let session = model?.engineSession,
               let reason = VoiceStatusText.endedReason(phase: session.phase, ending: call.isEnding) {
                Text(reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("voice-ended-reason")
            }
            if let problem = model?.micProblem {
                Button { model?.restartMic() } label: {
                    Label(problem, systemImage: "mic.badge.xmark")
                        .font(.callout.weight(.semibold)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.bordered).tint(.red)
                .accessibilityIdentifier("voice-mic-problem")
            }
            if let caption = model?.transcript.pendingCaption {
                // The user's words while the user talks over a running turn (a steer or the next turn).
                Text(caption).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .adaptiveGlass(in: Capsule())
                    .accessibilityIdentifier("voice-caption")
            }
            if let notice = model?.engineSession?.notice ?? model?.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .adaptiveGlass(in: Capsule())
                    .accessibilityIdentifier("voice-notice")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var dock: some View {
        VoiceDock(muted: model?.muted == true, toggleMute: { model?.toggleMute() }) {
            // chat the call worked in opens and the screen closes into it.
            Task { await controller.end() }
        }
        .disabled(call.isEnding)
        .contentShape(Rectangle())
        .gesture(minimizeSwipe)
    }

    private var keepAwake: Bool {
        guard scenePhase == .active, controller.isExpanded, let session = model?.engineSession else { return false }
        return !session.isEnded && model?.endedByUser == false
    }
}

/// on screen, and this text is the orb's VoiceOver label. While the phase is Working it says
/// what Hermes is doing in one word ("Thinking" while its turn streams, else "Working"); every
/// other phase says the phase's word. An ended call's reason is a sentence shown in the notices
/// above the dock (`endedReason`), not a status word.
enum VoiceStatusText {
    static func orb(phase: VoiceSession.Phase, status: VoiceHermesStatus, muted: Bool, ending: Bool) -> String {
        if ending { return String(localized: "Ending…") }
        switch phase {
        case .connecting: return String(localized: "Connecting")
        case .listening, .hearing: return muted ? String(localized: "Paused, muted") : String(localized: "Listening")
        case .sending: return String(localized: "Sending")
        case .working: return status.state == .thinking ? String(localized: "Thinking") : String(localized: "Working")
        case .speaking: return String(localized: "Speaking")
        case .ended: return String(localized: "Ended")
        }
    }

    /// The sentence an ended call gives for why it ended ("Connection lost.", "Couldn't connect
    static func endedReason(phase: VoiceSession.Phase, ending: Bool) -> String? {
        guard !ending, case .ended(let reason?) = phase else { return nil }
        return reason
    }
}

@MainActor @Observable final class VoiceScreenModel {
    /// The running engine: `VoiceSession` (Normal) or `VoiceLiveConversation` (GPT-Live).
    private(set) var engineSession: (any VoiceEngine)?
    private(set) var muted = false
    private(set) var endedByUser = false
    /// Shown on the screen, e.g. when on-device recognition isn't available.
    private(set) var notice: String?
    func showNotice(_ text: String) { notice = text }
    /// This startup decision remains visible even while mic/engine notices change.
    private(set) var fallbackReason: String?
    /// The call's transcript (`VoiceTranscriptModel`); either engine feeds the same interface.
    let transcript = VoiceTranscriptModel()
    /// The chat's key once known (Continue by voice, or the engine's new session).
    var sessionKey: String? { engineSession?.sessionKey ?? resumeSessionKey }
    var sessionProfile: String? { engineSession?.sessionProfile ?? resumeProfile }
    /// A plain line when the mic isn't working (\"Microphone stopped. Tap to restart.\"); tapping restarts it.
    private(set) var micProblem: String?
    /// Live mic level and the endpointer's current speech threshold (RMS), read by the orb. GPT-Live has
    private(set) var level: Float = 0
    private(set) var threshold: Float?
    /// two readings.
    private(set) var outputLevel: Float = 0
    private(set) var outputLevelInterval: TimeInterval = 0
    /// followed by an envelope (fast rise, slower fall) so syllables read as one pulse, not a
    /// flicker; `outputGlide` is the same value as the orb draws it between readings.
    private(set) var outputPulse: CGFloat = 0
    private(set) var outputGlide = VoiceOrbGlide()
    private var outputLevelAt: Date?
    func noteOutputLevel(_ value: Float, at now: Date = Date()) {
        let interval = outputLevelAt.map { min(0.5, now.timeIntervalSince($0)) } ?? 0
        if outputLevelAt != nil { outputLevelInterval = interval }
        outputLevelAt = now
        outputLevel = value
        outputPulse = VoiceOrbEnvelope.follow(outputPulse, toward: VoiceOrbLevelScale.output(mode).fraction(value), over: interval)
        outputGlide = outputGlide.next(outputPulse, at: now, interval: interval)
    }
    /// through the same envelope, the seconds between its last two readings, and the glide.
    private(set) var inputPulse: CGFloat = 0
    private(set) var inputLevelInterval: TimeInterval = 0
    private(set) var inputGlide = VoiceOrbGlide()
    private var inputLevelAt: Date?
    func noteInputLevel(_ value: Float, at now: Date = Date()) {
        let interval = inputLevelAt.map { min(0.5, now.timeIntervalSince($0)) } ?? 0
        if inputLevelAt != nil { inputLevelInterval = interval }
        inputLevelAt = now
        level = value
        inputPulse = VoiceOrbEnvelope.follow(inputPulse, toward: VoiceOrbLevelScale.input(mode).fraction(value), over: interval)
        inputGlide = inputGlide.next(inputPulse, at: now, interval: interval)
    }
    private(set) var micActive = false
    /// GPT-Live's availability from `voice-live/status`: nil = still checking; `.some(nil)` = available.
    private(set) var liveUnavailableReason: String?? = nil
    /// Normal's audio engine; shut down when the call ends.
    let engine = VoiceAudioEngine()
    let recognizer = VoiceRecognizer()
    private let server: URL
    private let connection: BotConnection
    private let resumeSessionKey: String?
    private let resumeProfile: String?
    private var ticker: Task<Void, Never>?

    private let requestedMode: VoiceMode?
    private(set) var hostPreferredMode = VoiceMode.normal

    /// `dashboard`: the client history pages go out on; nil makes one on the server's shared
    /// connection at the first page (tests pass a scripted host's).
    init(server: URL, connection: BotConnection, resumeSessionKey: String?, resumeProfile: String? = nil,
         requestedMode: VoiceMode? = nil, dashboard: BotDashboardClient? = nil) {
        self.requestedMode = requestedMode
        self.server = server
        self.connection = connection
        self.resumeSessionKey = resumeSessionKey
        self.resumeProfile = resumeProfile
        self.dashboard = dashboard
    }

    var mode: VoiceMode { engineSession?.mode ?? requestedMode ?? hostPreferredMode }
    var liveAvailable: Bool { liveUnavailableReason == .some(nil) }
    /// The engine ended by itself (stop phrase, lost connection): the call is released.
    var closesOnEngineEnd: Bool { !endedByUser }
    /// owner releases the call and shows the reason. Not called after `end()`.
    var onEndedByItself: ((String?) -> Void)?
    /// Hermes's status for this chat when it last asked for the user (an approval arrived, or
    /// it said something needs the app). The request is open while that status holds: Hermes
    /// waits on it, and an answer (by voice or in the app) moves the turn on.
    private var attentionAt: VoiceHermesStatus?
    private var lastPhase: VoiceSession.Phase?
    private var lastApprovalID: String?

    /// Hermes waits on this call's user: an approval or a request that needs the app is still
    var needsAttention: Bool {
        guard let session = engineSession, !session.isEnded, let attentionAt else { return false }
        return session.hermesStatus == attentionAt
    }

    /// Hermes is working for this call: a request is being sent or runs, or Hermes reports a step.
    var hermesWorking: Bool {
        guard let session = engineSession else { return false }
        switch session.phase {
        case .sending, .working: return true
        default: break
        }
        switch session.hermesStatus.state {
        case .thinking, .working: return true
        case .idle, .stopped: return false
        }
    }

    private func needsApp(_ line: String) {
        notice = line
        attentionAt = engineSession?.hermesStatus
    }

    func attach(_ session: any VoiceEngine) {
        engineSession = session
        lastPhase = nil
        lastApprovalID = nil
        attentionAt = nil
        engineChanged()
    }

    /// One observation per change, re-armed after each (Observation's own change tracking).
    private func followEngine(_ session: any VoiceEngine) {
        withObservationTracking {
            _ = session.phase
            _ = session.pendingApproval
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.engineChanged() }
        }
    }

    private func engineChanged() {
        guard let session = engineSession else { return }
        let phase = session.phase
        if phase != lastPhase {
            lastPhase = phase
        }
        let approvalID = session.pendingApproval?.requestID
        if approvalID != lastApprovalID {
            if approvalID != nil { attentionAt = session.hermesStatus }
            else if lastApprovalID != nil { attentionAt = nil }   // answered by voice
            lastApprovalID = approvalID
        }
        if case .ended(let reason) = phase {
            guard closesOnEngineEnd else { return }
            let report = onEndedByItself
            onEndedByItself = nil
            report?(reason)
            return
        }
        followEngine(session)
    }

    /// Opens the screen: checks GPT-Live, then starts the captured mode (Normal when GPT-Live
    /// isn't available).
    func start() async {
        transcript.onTurnFinished = { [weak self] runID in self?.fetchSaved(runID: runID) }
        if let key = resumeSessionKey {
            // Continue by voice: the chat's saved history, over the dashboard, above the voice turns.
            transcript.isLoadingHistory = true
            async let live: Void = checkLive()
            let newest = await newestRows(key)
            await live
            transcript.isLoadingHistory = false
            if let newest { transcript.loadHistory(newest.rows, reachedStart: newest.reachedStart) }
        } else {
            await checkLive()
        }
        guard !Task.isCancelled, !endedByUser else { return }
        let preferred = requestedMode ?? hostPreferredMode
        let mode = VoiceScreenModel.startMode(preferred: preferred, liveAvailable: liveAvailable)
        if preferred == .live, mode == .normal {
            fallbackReason = Self.fallbackLine(reason: liveUnavailableReason ?? nil)
        }
        let handoff = VoiceHandoff(sessionKey: nil, fallbackKey: resumeSessionKey, messages: transcript.messages)
        await startEngine(mode, seed: handoff.seedTurns)
    }

    // MARK: History (dashboard REST, `BotDashboardClient`)

    private var dashboard: BotDashboardClient?
    private var historyFetch: Task<Void, Never>?

    private func page(_ key: String, offset: Int) async -> [BotJSON]? {
        // The server's shared connection: its sign-in and cookie jar, as the voice socket's.
        let client = dashboard ?? BotDashboardClient(saved: connection, server: server)
        dashboard = client
        return try? await client.sessionRows(sessionID: key, profile: resumeProfile, offset: offset)
    }

    /// The newest rows, oldest first, as the chat reads them (`HermesChatTurnCoordinator.newestRows`):
    /// pages back from the newest until one reaches the rows held or the first row, at most
    /// `newestPageLimit` of them.
    private func newestRows(_ key: String) async -> (rows: [BotJSON], reachedStart: Bool)? {
        var rows: [BotJSON] = []
        for _ in 0..<Self.newestPageLimit {
            guard let page = await page(key, offset: rows.count) else { return nil }
            rows = page + rows
            if page.count < HermesREST.transcriptPageSize { return (rows, true) }
            if transcript.reaches(page) { break }
        }
        return (rows, false)
    }

    private static let newestPageLimit = 5

    /// A Normal turn ended with a receipt for its saved rows: the newest rows are read again and
    /// take its place (the chat's `refreshHistory`). Rows that don't hold the receipt's leave the
    /// turn drawn as it is, ended, until the next turn begins.
    private func fetchSaved(runID: String) {
        guard let key = sessionKey else { return }
        historyFetch = Task { [weak self] in
            guard let self, let newest = await self.newestRows(key), !Task.isCancelled else { return }
            self.transcript.applySaved(newest.rows, reachedStart: newest.reachedStart, runID: runID)
        }
    }

    func loadOlder() async -> Bool {
        guard let key = sessionKey, transcript.hasOlder,
              let page = await page(key, offset: transcript.history.nextOffset) else { return false }
        return transcript.prependOlder(page)
    }

    /// The mode a new screen starts in.
    static func startMode(preferred: VoiceMode, liveAvailable: Bool) -> VoiceMode {
        preferred == .live && liveAvailable ? .live : .normal
    }

    /// The line under the transcript when GPT-Live was asked for and Speech-to-text + Hermes voice started.
    static func fallbackLine(reason: String?) -> String {
        String(localized: "Using Speech-to-text + Hermes voice.") + " " + (reason ?? String(localized: "Couldn't check GPT-Live."))
    }

    func checkLive() async {
        do {
            let status = try await VoiceStartAvailability.fetch(VoiceStartScope(server: server, connection: connection, profile: resumeProfile))
            guard !Task.isCancelled, !endedByUser else { return }
            applyLiveStatus(status)
        } catch {
            guard !Task.isCancelled, !endedByUser else { return }
            liveUnavailableReason = .some(String(localized: "Couldn't check GPT-Live."))
        }
    }

    func applyLiveStatus(_ status: VoiceLive.Status?) {
        hostPreferredMode = VoiceMode(hostValue: status?.mode)
        liveUnavailableReason = .some(status.map { $0.unavailableReason } ?? String(localized: "This Hermes has no GPT-Live."))
    }

    private func startEngine(_ mode: VoiceMode, seed: [(role: String, text: String)]) async {
        muted = false
        switch mode {
        case .normal: await startNormal()
        case .live: await startLive(seed: seed)
        }
        if endedByUser { await stopEngine(); return }
        let interval = engineSession?.tickInterval ?? .seconds(1)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.engineSession?.tick()
                if self.engineSession?.mode == .normal { self.engine.tick() }
            }
        }
        if let live = engineSession as? VoiceLiveConversation {
            // GPT-Live's levels come from WebRTC's stats, which have no callback: read them at
            // about the rate WebRTC refreshes them (a new audioLevel every ~110 ms).
            levelReader = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.liveLevelInterval)
                    // WebRTC's media-source / inbound-rtp audioLevel is linear 0…1 (≈ RMS of full scale).
                    let input = await live.inputLevel()
                    let output = await live.outputLevel()
                    guard let self, !Task.isCancelled else { return }
                    if let input { self.noteInputLevel(Float(input)) }
                    if let output { self.noteOutputLevel(Float(output)) }
                }
            }
        }
    }

    /// How often GPT-Live's levels are read from WebRTC's stats.
    static let liveLevelInterval: Duration = .milliseconds(100)
    private var levelReader: Task<Void, Never>?

    private func startNormal() async {
        // The call keeps working in the background (its audio session runs the app), so its
        // client holds the shared Hermes socket through `.background`.
        let client = BotClient(saved: connection, server: server, holdsSocketInBackground: true)
        var settings = VoicePreferences.settings
        // Speech permission is asked here, the first time voice mode needs it.
        let recognition = await recognizer.prepare()
        if !settings.useServerTranscription, recognition != .ready {
            settings.useServerTranscription = true
            notice = recognition == .denied
                ? String(localized: "Speech recognition is off for Hermex. Using the Hermes server instead.")
                : String(localized: "On-device recognition isn't available for this language. Using the Hermes server instead.")
        }
        let session = VoiceSession(backend: client, player: engine, settings: settings, resumeSessionKey: resumeSessionKey,
                                   resumeProfile: resumeProfile)
        session.transcript = transcript
        session.onNeedsApp = { [weak self] line in self?.needsApp(line) }
        attach(session)
        engine.endpointer.silence = VoicePreferences.silence
        let recognizer = self.recognizer
        recognizer.onPartial = { [weak session] text in session?.showLiveCaption(text) }
        engine.onSpeechStarted = { [weak session] in recognizer.begin(); session?.speechStarted() }
        engine.onSpeechBuffer = { buffer in recognizer.append(buffer) }
        engine.onSpeechDiscarded = { [weak session] in recognizer.cancel(); session?.speechDiscarded() }
        engine.onUtterance = { [weak session] data, _ in
            session?.speechEnded()
            Task {
                let caption = await recognizer.finish()
                await session?.utterance(audio: data, mimeType: "audio/m4a", caption: caption)
            }
        }
        engine.onProblem = { [weak self] line in self?.micProblem = line }
        engine.onLevel = { [weak self] level, threshold in
            self?.noteInputLevel(level)
            self?.threshold = threshold
        }
        engine.onOutputLevel = { [weak self] level in self?.noteOutputLevel(level) }
        await startMicrophone()
        await session.start()
    }

    /// GPT-Live: WebRTC owns the mic and the speaker; Hermes runs the delegated turns in this chat.
    private func startLive(seed: [(role: String, text: String)]) async {
        let client = BotClient(saved: connection, server: server, holdsSocketInBackground: true)
        if !(await AVAudioApplication.requestRecordPermission()) {
            micProblem = String(localized: "Microphone access is off for Hermex. Turn it on in Settings, then tap to retry.")
        }
        let conversation = VoiceLiveConversation(backend: client, makeTransport: {
            VoiceLiveSession(backend: client)
        }, resumeSessionKey: resumeSessionKey, resumeProfile: resumeProfile, seedHistory: seed)
        conversation.onNeedsApp = { [weak self] line in self?.needsApp(line) }
        conversation.transcript = transcript
        micActive = true
        threshold = nil
        attach(conversation)
        await conversation.start()
    }

    /// Asks for the mic and starts the engine; a failure becomes `micProblem`.
    private func startMicrophone() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            micProblem = String(localized: "Microphone access is off for Hermex. Turn it on in Settings, then tap to retry.")
            return
        }
        do {
            try engine.configure(useMicrophone: true)
            micActive = true
            micProblem = nil
        } catch {
            micProblem = String(localized: "Microphone didn't start (\(error.localizedDescription)). Tap to restart.")
        }
    }

    /// The mic problem line was tapped.
    func restartMic() {
        guard mode == .normal else { return }
        if micActive { engine.restart(); return }
        Task { await startMicrophone() }
    }

    func toggleMute() {
        muted.toggle()
        if let live = engineSession as? VoiceLiveConversation {
            if live.muted != muted { live.toggleMute() }
        } else {
            engine.muted = muted
        }
    }

    /// Ends this call's engine and releases its audio resources.
    private func stopEngine() async {
        ticker?.cancel()
        levelReader?.cancel()
        let ending = engineSession
        if ending?.mode == .normal {
            recognizer.cancel()
            await ending?.end()
            engine.shutdown()
        } else {
            await ending?.end()
        }
        micActive = false
        level = 0
        outputLevel = 0
        outputLevelAt = nil
        outputPulse = 0
        outputGlide = VoiceOrbGlide()
        inputLevelAt = nil
        inputPulse = 0
        inputGlide = VoiceOrbGlide()
    }

    func end() async {
        endedByUser = true
        await stopEngine()
    }

    /// The dock's End: ends the voice session, then returns the chat the call worked in
    /// (resumed, or created by its first request) so the screen opens it; nil when the call
    /// never made a chat. The chat's work is never cancelled: neither engine's `end()` sends
    /// `session.close`, so its turn, subagents and background processes run on.
    func endAndReturnChat() async -> String? {
        let ending = engineSession
        await end()
        // An explicitly resumed chat already exists, including when End wins before
        // an engine was attached or its connection could resume that chat.
        if let resumeSessionKey { return resumeSessionKey }
        return await ending?.chatForOpening()
    }

}

struct VoiceSettingsView: View {
    let server: URL
    @AppStorage(VoicePreferences.recognitionKey) private var serverTranscription = true
    @AppStorage(VoicePreferences.interruptKey) private var interruptByTalking = true
    @AppStorage(VoicePreferences.progressKey) private var progress = VoiceSession.Settings.Progress.spoken.rawValue
    @AppStorage(VoicePreferences.silenceKey) private var silence = 1.5
    @State private var pronunciations = VoicePreferences.pronunciations

    @AppStorage(VoicePreferences.transcriptModeKey) private var transcriptMode = VoiceTranscriptModel.Mode.full.rawValue
    @AppStorage(VoicePreferences.showsThinkingAndToolsKey) private var showsThinkingAndTools = true
    @AppStorage(VoicePreferences.showsAppendsKey) private var showsAppends = true
    @AppStorage(VoiceLive.ContextMode.defaultsKey) private var liveContext = VoiceLive.ContextMode.sinceLastRequest.stored
    @State private var modePreference: VoiceModePreferenceModel

    init(server: URL, profile: String? = nil, connection: BotConnection? = nil) {
        self.server = server
        _modePreference = State(initialValue: VoiceModePreferenceModel(
            fetch: { try await Self.withClient(server: server, connection: connection) { try await $0.voiceMode(profile: profile) } },
            save: { mode in try await Self.withClient(server: server, connection: connection) { try await $0.saveVoiceMode(mode, profile: profile) } }))
    }

    static let modeFooter = String(localized: "Saved on this Hermes Profile. Applies to the next call. GPT-Live falls back to Speech-to-text + Hermes voice if unavailable.")

    var body: some View {
        Form {
            VoiceModePreferenceSection(model: modePreference)
            Section {
                Picker(String(localized: "Conversation sent with each request"), selection: $liveContext) {
                    Text("Everything since the last request").tag(VoiceLive.ContextMode.sinceLastRequest.stored)
                    Text("Last 1 minute").tag(VoiceLive.ContextMode.lastMinutes(1).stored)
                    Text("Last 2 minutes").tag(VoiceLive.ContextMode.lastMinutes(2).stored)
                    Text("Last 5 minutes").tag(VoiceLive.ContextMode.lastMinutes(5).stored)
                    Text("Last 10 minutes").tag(VoiceLive.ContextMode.lastMinutes(10).stored)
                }
                .accessibilityIdentifier("voice-live-context")
            } header: { Text("GPT-Live") } footer: {
                Text("Conversation context sent with each GPT-Live request.")
            }
            Section {
                Picker(String(localized: "On screen"), selection: $transcriptMode) {
                    Text("Full transcript").tag(VoiceTranscriptModel.Mode.full.rawValue)
                    Text("Current exchange only").tag(VoiceTranscriptModel.Mode.current.rawValue)
                }
                Toggle(String(localized: "Thinking and tool calls"), isOn: $showsThinkingAndTools)
                    .accessibilityIdentifier("settings-voice-show-thinking-tools")
                Toggle(String(localized: "GPT-Live appends"), isOn: $showsAppends)
                    .accessibilityIdentifier("settings-voice-show-appends")
            } header: { Text("Screen") } footer: {
                Text("What the voice screen's transcript shows while Hermes works. The same switches are in the call's settings (the gear at the top right). Hidden rows are only hidden there: the chat itself keeps them.")
            }
            Section {
                Picker(String(localized: "While Hermes works"), selection: $progress) {
                    Text("Spoken updates").tag(VoiceSession.Settings.Progress.spoken.rawValue)
                    Text("Soft sound").tag(VoiceSession.Settings.Progress.tones.rawValue)
                    Text("Silent").tag(VoiceSession.Settings.Progress.off.rawValue)
                }
            } header: { Text("Waiting") } footer: {
                Text("Spoken updates say what Hermes is doing. Soft sound plays a quiet tone every few seconds.")
            }
            Section {
                VStack(alignment: .leading) {
                    Text("Pause before sending: \(silence, specifier: "%.1f") s")
                    Slider(value: $silence, in: 0.8...3, step: 0.1)
                }
                Toggle(String(localized: "Interrupt by talking"), isOn: $interruptByTalking)
                Picker(String(localized: "Recognition"), selection: $serverTranscription) {
                    Text("Hermes server (OpenAI)").tag(true)
                    Text("On-device").tag(false)
                }
            } header: { Text("Listening") }
            Section(String(localized: "Pronunciations")) {
                ForEach($pronunciations, id: \.self) { $entry in
                    HStack {
                        TextField(String(localized: "Written"), text: $entry.written)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField(String(localized: "Spoken"), text: $entry.spoken)
                    }
                }
                .onDelete { pronunciations.remove(atOffsets: $0) }
                Button(String(localized: "Add")) { pronunciations.append(.init(written: "", spoken: "")) }
            }
            .onChange(of: pronunciations) { _, list in VoicePreferences.savePronunciations(list.filter { !$0.written.isEmpty }) }

        }
        .navigationTitle(String(localized: "Voice"))
        .task { await modePreference.load() }
    }

    private func withClient<T>(_ body: (BotClient) async throws -> T) async throws -> T {
        try await Self.withClient(server: server, body)
    }

    private static func withClient<T>(server: URL, connection: BotConnection? = nil, _ body: (BotClient) async throws -> T) async throws -> T {
        guard let connection = try connection ?? BotConnectionStore().load(server: server) else { throw BotFailure.missingChat }
        let client = BotClient(saved: connection, server: server)
        defer { client.close() }
        try await client.connect()
        return try await body(client)
    }

}

/// the chat; there is no separate "Open chat".
struct VoiceDock: View {
    let muted: Bool
    let toggleMute: () -> Void
    let end: () -> Void

    /// The dock's buttons, by accessibility identifier, in order.
    static let buttonIdentifiers = ["voice-mute", "voice-end"]

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleMute) {
                VStack(spacing: 4) {
                    Image(systemName: muted ? "mic.slash.fill" : "mic.fill").font(.title3.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(muteTitle).font(.caption.weight(.medium)).lineLimit(2).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(muted ? Color.white : Color.primary)
                .background(muted ? Color.orange : Color(.secondarySystemFill),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(muteTitle)
            .accessibilityIdentifier(Self.buttonIdentifiers[0])
            Button(role: .destructive, action: end) {
                VStack(spacing: 4) {
                    Image(systemName: "xmark").font(.title3.weight(.semibold))
                    Text(String(localized: "End")).font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(.white)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "End"))
            .accessibilityIdentifier(Self.buttonIdentifiers[1])
        }
        .padding(12)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 6)
    }

    private var muteTitle: String { muted ? String(localized: "Unmute") : String(localized: "Mute") }
}
