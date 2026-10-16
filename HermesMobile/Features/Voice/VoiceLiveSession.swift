import AVFoundation
import Foundation
import OSLog
import WebRTC

/// The transport `VoiceLiveConversation` drives. Production: `VoiceLiveSession` (WebRTC);
/// tests use a scripted fake around the same `VoiceLiveEvents` core.
@MainActor protocol VoiceLiveTransport: AnyObject {
    var events: VoiceLiveEvents { get }
    /// The remote voice is producing audio (output transcript arriving).
    var onSpeakingChange: ((Bool) -> Void)? { get set }
    func start(history: [BotJSON], profile: String?) async throws
    func setMuted(_ muted: Bool)
    /// Tap to interrupt: silence the voice's audio on this device now (true), restore it for the
    /// next response (false). The server keeps generating; only local playout is cut.
    func setPlayoutCut(_ cut: Bool)
    /// The mic's level, 0…1 (WebRTC stats `media-source.audioLevel`); nil when unknown.
    func inputLevel() async -> Double?
    /// The received voice's level as played, 0…1 (WebRTC stats `inbound-rtp.audioLevel`, measured
    func outputLevel() async -> Double?
    /// Graceful close: `session.close`, then `session.closed` or a 15 s timeout ends it.
    func close()
}

/// The dashboard calls GPT-Live needs (`BotClient`).
@MainActor protocol VoiceLiveBackend: BotVoiceBackend {
    func voiceLiveStatus() async throws -> VoiceLive.Status?
    func voiceLiveSession(sdp: String, history: [BotJSON], profile: String?) async throws -> (answer: String, sessionID: String?)
}

extension BotClient: VoiceLiveBackend {}

enum VoiceLiveError: Error { case alreadyStarted, peerConnection, missingOffer, connectionFailed }

/// WebRTC transport using an RTCPeerConnection with
/// the mic track, the `oai-events` data channel created before the offer, ICE gathering capped at
/// 10 s, the offer POSTed byte-exact through the dashboard (the OpenAI key stays on the host),
/// the answer applied, then events through `VoiceLiveEvents`.
@MainActor final class VoiceLiveSession: NSObject, VoiceLiveTransport {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile", category: "VoiceLive")
    let events: VoiceLiveEvents
    /// Late-bound sink so `events` can exist before `self` (the data channel is created in start).
    private final class Sink { weak var session: VoiceLiveSession? }
    var onSpeakingChange: ((Bool) -> Void)?
    private let backend: any VoiceLiveBackend
    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var micTrack: RTCAudioTrack?
    private var closeTimer: Task<Void, Never>?
    private var iceDone: CheckedContinuation<Void, Never>?
    private var speaking = false
    private var lastOutput = Date.distantPast
    private var speakingProbe: Task<Void, Never>?
    /// Voice diagnostics (`voice-start`, `voice-route`), the same sink as Normal mode.
    /// Monotonic times for the report: offer sent, answer applied, `session.started`.

    init(backend: any VoiceLiveBackend) {
        self.backend = backend
        let sink = Sink()
        events = VoiceLiveEvents { text in
            guard let channel = sink.session?.channel, channel.readyState == .open else { return false }
            return channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
        }
        super.init()
        sink.session = self

        events.transportOutput = { [weak self] in self?.lastOutput = Date(); self?.setSpeaking(true) }
        events.transportFinished = { [weak self] in self?.teardown() }
    }

    private static let sslOnce: Void = { RTCInitializeSSL() }()

    func start(history: [BotJSON], profile: String?) async throws {
        guard peer == nil else { throw VoiceLiveError.alreadyStarted }
        _ = Self.sslOnce
        Self.configureAudioSession()
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        self.factory = factory
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw VoiceLiveError.peerConnection
        }
        self.peer = peer
        // Mic with echo cancellation, AGC and noise suppression (the desktop's getUserMedia flags).
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: [
            "googEchoCancellation": "true", "googAutoGainControl": "true", "googNoiseSuppression": "true"
        ], optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "mic")
        micTrack = track
        peer.add(track, streamIds: ["mic"])
        // Register the data channel before the offer so its m-line is negotiated.
        guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()) else {
            throw VoiceLiveError.peerConnection
        }
        channel.delegate = self
        self.channel = channel

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            peer.offer(for: constraints) { sdp, error in
                if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: error ?? VoiceLiveError.missingOffer) }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { error in if let error { cont.resume(throwing: error) } else { cont.resume() } }
        }
        await waitForIceGathering(peer)
        guard let sdp = peer.localDescription?.sdp, !sdp.isEmpty else { throw VoiceLiveError.missingOffer }
        let (answer, sessionID) = try await backend.voiceLiveSession(sdp: sdp, history: history, profile: profile)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer)) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        armSpeakingProbe()
        // The audio unit is running now (WebRTC applied its configuration): log the route it got.

    }

    /// Routes like a phone call (`VoiceCallAudio`): speaker when nothing is connected, else the
    /// headset / Bluetooth. libwebrtc's audio unit re-applies `RTCAudioSessionConfiguration.webRTC()`
    /// every time it starts or restarts I/O (call connect, route change, interruption), and its
    /// default has no `.defaultToSpeaker` (`.playAndRecord` then plays from the earpiece), so the
    /// call's options go into that configuration, not just onto the session once.
    static func configureAudioSession() {
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = VoiceCallAudio.category.rawValue
        config.mode = VoiceCallAudio.mode.rawValue
        config.categoryOptions = VoiceCallAudio.options
        RTCAudioSessionConfiguration.setWebRTC(config)
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setConfiguration(config)
        } catch {
            Self.logger.debug("Audio session setup failed: \(String(describing: error))")
        }
    }

    /// The category, mode and options WebRTC applies whenever it (re)configures the session.
    static var webRTCAudio: (category: String, mode: String, options: AVAudioSession.CategoryOptions) {
        let config = RTCAudioSessionConfiguration.webRTC()
        return (config.category, config.mode, config.categoryOptions)
    }

    /// `voice-route` on every route change while the call runs (reason + new output port).

    private func waitForIceGathering(_ peer: RTCPeerConnection) async {
        if peer.iceGatheringState == .complete { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            iceDone = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(VoiceLive.iceGatherTimeout))
                // Trickle is fine: the vendor answers with the candidates it has.
                self?.resumeIce()
            }
        }
    }

    private func resumeIce() { iceDone?.resume(); iceDone = nil }

    /// Speaking = an output transcript delta in the last 1.2 s (the desktop probes the remote
    /// track's level; the transcript tracks the same audio).
    private func armSpeakingProbe() {
        speakingProbe = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                if self.speaking, Date().timeIntervalSince(self.lastOutput) > 1.2 { self.setSpeaking(false) }
            }
        }
    }

    private func setSpeaking(_ value: Bool) {
        guard value != speaking else { return }
        speaking = value
        onSpeakingChange?(value)
    }

    /// Disabling the remote track sets its receiver's output volume to 0 (libwebrtc
    /// `AudioRtpReceiver::Reconfigure`): playout goes silent on the next 10 ms buffer.
    func setPlayoutCut(_ cut: Bool) {
        for receiver in peer?.receivers ?? [] where receiver.track?.kind == kRTCMediaStreamTrackKindAudio {
            receiver.track?.isEnabled = !cut
        }
    }

    func inputLevel() async -> Double? { await statsLevel(type: "media-source") }

    func outputLevel() async -> Double? { await statsLevel(type: "inbound-rtp", kind: "audio") }

    private func statsLevel(type: String, kind: String? = nil) async -> Double? {
        guard let peer else { return nil }
        let report: RTCStatisticsReport = await withCheckedContinuation { cont in peer.statistics { cont.resume(returning: $0) } }
        for stat in report.statistics.values where stat.type == type {
            if let kind, stat.values["kind"] as? String != kind { continue }
            if let level = stat.values["audioLevel"] as? NSNumber { return level.doubleValue }
        }
        return nil
    }

    func setMuted(_ muted: Bool) {
        micTrack?.isEnabled = !muted
        events.mute(muted)
    }

    func close() {
        guard !events.finalized else { return }
        guard events.requestClose() else { finish("close_requested", nil); return }
        closeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(VoiceLive.closeTimeout))
            guard !Task.isCancelled else { return }
            self?.finish("close_requested", nil)
        }
    }

    /// Ends the session once (`VoiceLiveEvents.finish` → `transportFinished` → `teardown`).
    private func finish(_ reason: String, _ seconds: Double?) { events.finish(reason, seconds) }

    private func teardown() {
        closeTimer?.cancel(); closeTimer = nil
        speakingProbe?.cancel(); speakingProbe = nil
        resumeIce()
        channel?.close(); channel = nil
        peer?.close(); peer = nil
        micTrack = nil
        factory = nil
        setSpeaking(false)
    }
}

extension VoiceLiveSession: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor in self.resumeIce() }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        guard newState == .failed || newState == .disconnected else { return }
        Task { @MainActor in self.finish("connection_lost", nil) }
    }

    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        Task { @MainActor in
            if state == .closed, !self.events.finalized { self.finish("connection_lost", nil) }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let text = String(data: buffer.data, encoding: .utf8) else { return }
        Task { @MainActor in self.events.handle(text) }
    }
}
