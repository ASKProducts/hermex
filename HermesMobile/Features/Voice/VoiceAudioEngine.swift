import AVFoundation
import Foundation

/// Energy endpointing, phase-aware like the desktop's barge-in monitor
/// (`apps/desktop/src/lib/voice-barge-in.ts`), in float RMS as the phone's tap measures it.
///
/// - The noise floor is learned only while nothing plays (down fast, up slowly;
///   clamped at `minimumFloor` so digital silence can't collapse it to 0) and
///   HELD while our audio plays, so speaker bleed never raises it.
/// - Nothing plays: speech needs `threshold` = max(`minimumThreshold`, floor ×
///   `margin`) for a `onset` window with a `onsetMajority` share of it above.
/// - `.suppressed` (the chime and 300 ms after any of our audio): speech can't start.
/// - `.playing` (a reply or line): the trigger adapts to the speaker bleed actually
///   measured: `bleed` is learned from playing frames that stay under the trigger
///   (never from talking over it), and the trigger is `bleed × bleedMargin`, at
///   least `playbackMinimum` (bleed alone can't trip it) and at most
///   `playbackCeiling`; the first `playbackGrace` of playback is ignored; talking
///   over needs `bargeMajority` of a `bargeOnset` window above.
/// An utterance ends after `silence` below the trigger; shorter than
/// `minimumSpeech` is dropped, longer than `maximumSpeech` is cut.
struct VoiceEndpointer {
    enum Event: Equatable { case speechStarted, utteranceEnded, discarded }
    enum Output: Equatable { case quiet, suppressed, playing }

    var margin: Float = 3.5
    var minimumThreshold: Float = 0.01
    var minimumFloor: Float = 0.00001
    /// Minimum playback speech trigger: 0.01 RMS.
    var playbackMinimum: Float = 0.01
    /// Playback speech must exceed the learned bleed by this factor.
    var bleedMargin: Float = 2.5
    var bleedRise: TimeInterval = 1
    var bleedFall: TimeInterval = 0.3
    var playbackCeiling: Float = 0.2
    var onset: TimeInterval = 0.12
    var onsetMajority = 0.7
    var bargeOnset: TimeInterval = 0.3
    var bargeMajority = 0.8
    var playbackGrace: TimeInterval = 0.5
    var playbackGapForGrace: TimeInterval = 1
    var silence: TimeInterval = 1.5
    var minimumSpeech: TimeInterval = 0.2
    /// Upper bound for a single utterance: 180 seconds.
    var maximumSpeech: TimeInterval = 180
    var calibration: TimeInterval = 0.3
    var floorRise: TimeInterval = 3
    var floorRiseInSpeech: TimeInterval = 20
    /// Within `echoWindow` of output starting, discard a burst that becomes quiet for
    /// `echoQuiet` before reaching `echoConfirm` of voiced input.
    var echoWindow: TimeInterval = 4
    var echoQuiet: TimeInterval = 0.5
    var echoConfirm: TimeInterval = 1.0
    /// Outside the onset window, check bursts at least twice the preceding output level.
    var echoLevelRatio: Float = 2
    private var echoReference: Float = 0
    private var burstPeak: Float = 0
    private var startedOverReply = false
    /// The utterance in progress started inside the echo window and hasn't proved itself yet.
    private(set) var echoCheck = false
    private(set) var lastDiscardWasEcho = false
    private(set) var inSpeech = false
    private(set) var floor: Float?
    private var elapsed: TimeInterval = 0
    private var speechTime: TimeInterval = 0
    private var quietTime: TimeInterval = 0
    private var window: [(above: Bool, duration: TimeInterval)] = []
    private var wasPlaying = false
    private var sincePlaying: TimeInterval = .infinity
    private var graceLeft: TimeInterval = 0
    /// Speaker bleed while our audio plays (nil until the first playing frame).
    private(set) var bleed: Float?

    /// The level a frame needs to count as speech while nothing plays.
    var threshold: Float { max(minimumThreshold, (floor ?? 0) * margin) }

    func trigger(for output: Output) -> Float {
        guard output == .playing else { return threshold }
        return min(max(threshold, (bleed ?? 0) * bleedMargin, playbackMinimum), playbackCeiling)
    }

    private mutating func learnBleed(level: Float, duration: TimeInterval, loud: Bool) {
        guard let current = bleed else { bleed = level; return }
        guard !loud else { return }  // talking over us is never bleed
        let rate = level < current ? min(1, duration / bleedFall) : min(1, duration / bleedRise)
        bleed = max(0, current + (level - current) * Float(rate))
    }

    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Feeds one frame's level and duration; returns an event when the state changes.
    /// `replyAudible`: seconds the current reply (or line) has been audible so far;
    /// `outputLevel`: the loudest output level of about the last second (the mixer tap's RMS).
    mutating func feed(level: Float, duration: TimeInterval, output: Output = .quiet,
                       replyAudible: TimeInterval = .infinity, outputLevel: Float = 0) -> Event? {
        let playing = output == .playing
        if playing {
            if !wasPlaying, sincePlaying >= playbackGapForGrace { graceLeft = playbackGrace }
            sincePlaying = 0
        } else if sincePlaying.isFinite {
            sincePlaying += duration
        }
        wasPlaying = playing
        let inGrace = graceLeft > 0
        graceLeft = max(0, graceLeft - duration)
        let loud = level >= trigger(for: output)
        if output == .quiet { track(level: level, duration: duration) }
        if playing, !inSpeech { learnBleed(level: level, duration: duration, loud: loud) }
        elapsed += duration
        if !inSpeech {
            let above = loud && elapsed > calibration && output != .suppressed && !inGrace
            let span = playing ? bargeOnset : onset
            let majority = playing ? bargeMajority : onsetMajority
            window.append((above, duration))
            var total = window.reduce(0) { $0 + $1.duration }
            while let first = window.first, total - first.duration >= span { total -= first.duration; window.removeFirst() }
            let aboveTime = window.reduce(0) { $0 + ($1.above ? $1.duration : 0) }
            guard above, total >= span * (playing ? bargeMajority : 1) - 1e-9, aboveTime >= total * majority else { return nil }
            window = []
            inSpeech = true
            speechTime = aboveTime
            quietTime = 0
            echoCheck = playing && replyAudible < echoWindow
            startedOverReply = playing
            echoReference = outputLevel
            burstPeak = level
            noteEchoLevel()
            return .speechStarted
        }
        if loud {
            speechTime += duration + quietTime; quietTime = 0
            if speechTime < echoConfirm { burstPeak = max(burstPeak, level); noteEchoLevel() }
            if speechTime >= echoConfirm { echoCheck = false }
            guard speechTime >= maximumSpeech else { return nil }
            return end()
        }
        quietTime += duration
        if echoCheck, quietTime >= echoQuiet { return end(echo: true) }
        guard quietTime >= silence else { return nil }
        return end()
    }

    /// A not-yet-confirmed burst over the reply far louder than the reply itself is checked as echo.
    private mutating func noteEchoLevel() {
        if startedOverReply, echoReference > 0, burstPeak >= echoReference * echoLevelRatio { echoCheck = true }
    }

    private mutating func end(echo: Bool = false) -> Event {
        inSpeech = false
        echoCheck = false
        startedOverReply = false
        lastDiscardWasEcho = echo
        let long = speechTime >= minimumSpeech
        speechTime = 0; quietTime = 0
        return long && !echo ? .utteranceEnded : .discarded
    }

    private mutating func track(level: Float, duration: TimeInterval) {
        guard let current = floor else { floor = max(minimumFloor, level); return }
        let rise = inSpeech ? floorRiseInSpeech : floorRise
        let rate = level < current ? min(1, duration / 0.1) : min(1, duration / rise)
        floor = max(minimumFloor, current + (level - current) * Float(rate))
    }

    /// Keeps the learned floor (a restart of the same mic doesn't need to relearn it).
    mutating func reset() { inSpeech = false; echoCheck = false; startedOverReply = false; speechTime = 0; quietTime = 0; window = [] }
}

/// Where voice diagnostics go (numbers and short codes only, never words or audio).

/// The audio session both voice modes run in, so they route like a phone call: the loud speaker
/// when nothing is connected (`.defaultToSpeaker`, never the earpiece), wired headphones,
/// AirPods / Bluetooth headsets and car Bluetooth (`.allowBluetoothHFP`) when connected, and
/// back again when one is unplugged. iOS moves the route; nothing here forces a port.
enum VoiceCallAudio {
    static let category = AVAudioSession.Category.playAndRecord
    static let mode = AVAudioSession.Mode.voiceChat
    static let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]

    static func routeFields(_ session: AVAudioSession = .sharedInstance()) -> [String: Any] {
        ["route_out": session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","),
         "route_in": session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ","),
         "category": session.category.rawValue, "audio_mode": session.mode.rawValue,
         "options": Int(session.categoryOptions.rawValue),
         "speaker_default": session.categoryOptions.contains(.defaultToSpeaker)]
    }

    /// `voice-route` fields for a route change: the reason code and the new output port type.
    static func routeChangeFields(_ note: Notification, _ session: AVAudioSession = .sharedInstance()) -> [String: Any] {
        ["reason": Int(note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0),
         "route_out": session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","),
         "options": Int(session.categoryOptions.rawValue)]
    }
}

/// Mic health: why the input stopped, as seen by the voice screen.
enum VoiceMicEvent: Equatable {
    case configurationChange
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChange(reason: UInt)

    /// Maps a system notification (as posted, or injected by tests) to an event.
    static func from(_ note: Notification) -> VoiceMicEvent? {
        switch note.name {
        case .AVAudioEngineConfigurationChange: return .configurationChange
        case AVAudioSession.interruptionNotification:
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
            if type == .began { return .interruptionBegan }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        case AVAudioSession.routeChangeNotification:
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            return .routeChange(reason: raw)
        default: return nil
        }
    }

    var code: String {
        switch self {
        case .configurationChange: return "config-change"
        case .interruptionBegan: return "interruption-began"
        case .interruptionEnded(let resume): return resume ? "interruption-ended-resume" : "interruption-ended"
        case .routeChange(let reason): return "route-change-\(reason)"
        }
    }
}

@MainActor final class VoiceAudioEngine: VoicePlayback {
    var onSpeechStarted: (() -> Void)?
    /// Speech that ended shorter than `minimumSpeech` (a click or cough).
    var onSpeechDiscarded: (() -> Void)?
    /// Every buffer of an utterance in progress (mic or file-fed), for the recognizer.
    var onSpeechBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Recorded m4a (AAC, input rate, mono) of one utterance and its length in seconds.
    var onUtterance: ((Data, TimeInterval) -> Void)?
    /// A plain line for the voice screen when the mic isn't working; nil when it works again.
    var onProblem: ((String?) -> Void)?
    /// Mic level for the meter, about 10 times a second: (level, threshold).
    var onLevel: ((Float, Float) -> Void)?
    /// What the speaker plays (main mixer tap RMS, one value per 2048-frame buffer) for the
    var onOutputLevel: ((Float) -> Void)?
    var muted = false
    /// Extra `voice-start` fields from the screen (recognition mode).
    var startContext: [String: Any] = [:]
    var endpointer = VoiceEndpointer()
    /// Seconds without any mic buffer before the input counts as stopped.
    var stallTimeout: TimeInterval = 3
    /// Route/config changes within this window are coalesced into one restart
    /// (activating the session posts two or three of them in the first second).
    var restartDebounce: TimeInterval = 0.3
    /// Speech can't start while the chime plays and for this long after any of our audio.
    var echoTail: TimeInterval = 0.3
    /// Restarts the input (tests replace it; the real one rebuilds the tap and starts the engine).
    lazy var inputRestarter: () throws -> Void = { [unowned self] in try self.restartEngineInput() }
    var now: () -> Date = Date.init

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerFormat: AVAudioFormat?
    private var recorder: AVAudioFile?
    private var recordingURL: URL?
    private var recordingFailed = false
    private var utteranceSeconds: TimeInterval = 0
    private var drained: (() -> Void)?
    /// Reply buffers scheduled and not yet played, oldest first. Kept so a mic
    /// restart (which stops the engine and drops the player's queue) can replay them.
    private var pendingBuffers: [(id: Int, buffer: AVAudioPCMBuffer)] = []
    private var nextBufferID = 0
    /// The odd byte left over from the last reply frame (see `enqueue`).
    private var carry: UInt8?
    private var replyIndex = 0
    private var playGeneration = 0
    private var suppressUntil: Date?
    private var pendingRestartReasons: [String] = []
    private var pendingRestartTask: Task<Void, Never>?
    private var preroll: [AVAudioPCMBuffer] = []
    private var outWindow = LevelWindow()
    private var outBytes = 0
    private var buffersScheduled = 0
    private var buffersPlayed = 0
    private var playedSeconds: Double = 0
    private var outputWasActive = false
    private var mixerTapInstalled = false
    var pendingReplyBuffers: Int { pendingBuffers.count }
    /// The unplayed reply as float samples, oldest first (tests).
    var pendingReplySamples: [Float] {
        pendingBuffers.flatMap { item in
            Array(UnsafeBufferPointer(start: item.buffer.floatChannelData![0], count: Int(item.buffer.frameLength)))
        } + staging
    }
    /// Frame counts of the scheduled reply buffers (tests).
    var pendingBufferFrames: [Int] { pendingBuffers.map { Int($0.buffer.frameLength) } }
    private(set) var rescheduledAfterRestart = 0
    private var clipPlayer: AVAudioPlayer?
    private var clipDelegate: ClipDelegate?
    private var configured = false
    private(set) var feedingFile = false
    var usesMicrophone = false
    private(set) var interrupted = false
    private(set) var problem: String?
    private(set) var restarts = 0
    private var observers: [NSObjectProtocol] = []
    private var tapInstalled = false
    private var lastBuffer: Date?
    private var levelWindow = LevelWindow()
    private var meterWindow = LevelWindow()
    private var recentRestarts: [Date] = []

    struct LevelWindow {
        var max: Float = 0, sum: Float = 0, count = 0
        mutating func add(_ level: Float) { max = Swift.max(max, level); sum += level; count += 1 }
        var mean: Float { count == 0 ? 0 : sum / Float(count) }
    }

    static let micStoppedLine = String(localized: "Microphone stopped. Tap to restart.")

    func configure(useMicrophone: Bool) throws {
        guard !configured else { return }
        configured = true
        usesMicrophone = useMicrophone
        let session = AVAudioSession.sharedInstance()
        var fields: [String: Any] = startContext
        fields["mic"] = useMicrophone
        do {
            try session.setCategory(VoiceCallAudio.category, mode: VoiceCallAudio.mode,
                                    options: VoiceCallAudio.options)
            try session.setActive(true)
            fields["input_available"] = session.isInputAvailable
            fields["session_rate"] = Int(session.sampleRate)
            fields["session_in_ch"] = session.inputNumberOfChannels
            fields.merge(VoiceCallAudio.routeFields(session)) { _, new in new }
            engine.attach(player)
            if useMicrophone {
                do { try engine.inputNode.setVoiceProcessingEnabled(true) } catch {
                    fields["vp_error"] = Self.code(error)
                }
                fields["vp"] = engine.inputNode.isVoiceProcessingEnabled
                let format = engine.inputNode.outputFormat(forBus: 0)
                fields["in_rate"] = Int(format.sampleRate)
                fields["in_ch"] = Int(format.channelCount)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw NSError(domain: "VoiceAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "No microphone input is available.")])
                }
                installTap()
            }
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
            engine.connect(player, to: engine.mainMixerNode, format: format)
            playerFormat = format
            installMixerTap()
            observe()
            engine.prepare()
            try engine.start()
            lastBuffer = now()
            fields["start"] = "ok"

        } catch {
            fields["start"] = "error"
            fields["error"] = Self.code(error)

            throw error
        }
    }

    func shutdown() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        player.stop()
        removeTap()
        if mixerTapInstalled { engine.mainMixerNode.removeTap(onBus: 0); mixerTapInstalled = false }
        pendingRestartTask?.cancel()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static func code(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain):\(ns.code)"
    }

    // MARK: Mic health

    private func observe() {
        let center = NotificationCenter.default
        let names: [(Notification.Name, AnyObject?)] = [
            (.AVAudioEngineConfigurationChange, engine),
            (AVAudioSession.interruptionNotification, AVAudioSession.sharedInstance()),
            (AVAudioSession.routeChangeNotification, AVAudioSession.sharedInstance())
        ]
        for (name, object) in names {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
                guard let event = VoiceMicEvent.from(note) else { return }
                MainActor.assumeIsolated { self?.handle(event) }
            })
        }
    }

    /// Reacts to a configuration change, interruption or route change.
    func handle(_ event: VoiceMicEvent) {
        var fields: [String: Any] = ["event": event.code]
        switch event {
        case .configurationChange:
            fields["action"] = interrupted ? "wait" : "restart"

            if !interrupted { scheduleRestart(reason: event.code) }
        case .interruptionBegan:
            interrupted = true
            dropUtterance()
            fields["action"] = "pause"

        case .interruptionEnded(let resume):
            interrupted = false
            fields["action"] = resume ? "restart" : "ask"

            if resume { restart(reason: event.code) } else { report(Self.micStoppedLine) }
        case .routeChange(let reason):
            // New or lost device (headphones, Bluetooth) or a route override: the input changed.
            let restartReasons: Set<UInt> = [AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
                                             AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                                             AVAudioSession.RouteChangeReason.override.rawValue]
            let act = !interrupted && usesMicrophone && (restartReasons.contains(reason) || !engine.isRunning)
            fields["action"] = act ? "restart" : "none"

            if act { scheduleRestart(reason: event.code) }
        }
    }

    /// Coalesces a burst of route/config changes into one restart after `restartDebounce`.
    private func scheduleRestart(reason: String) {
        guard restartDebounce > 0 else { restart(reason: reason); return }
        if !pendingRestartReasons.contains(reason) { pendingRestartReasons.append(reason) }
        pendingRestartTask?.cancel()
        let delay = restartDebounce
        pendingRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flushPendingRestart()
        }
    }

    /// Runs the coalesced restart now (tests call it instead of waiting).
    func flushPendingRestart() {
        pendingRestartTask?.cancel()
        pendingRestartTask = nil
        guard !pendingRestartReasons.isEmpty else { return }
        let reason = pendingRestartReasons.joined(separator: "+")
        pendingRestartReasons = []
        guard !interrupted else { return }
        restart(reason: reason)
    }

    /// Restarts the mic (also the voice screen's "tap to restart"). More than 5
    /// restarts within 10 s stop the loop and ask the user instead.
    func restart(reason: String = "user") {
        guard usesMicrophone else { return }
        let t = now()
        recentRestarts = recentRestarts.filter { t.timeIntervalSince($0) < 10 }
        if reason != "user", recentRestarts.count >= 5 {

            report(Self.micStoppedLine)
            return
        }
        recentRestarts.append(t)
        restarts += 1
        dropUtterance()
        do {
            playGeneration += 1
            try inputRestarter()
            lastBuffer = t
            interrupted = false
            let replayed = rescheduleReply()

            report(nil)
        } catch {

            report(String(localized: "Microphone stopped (\(error.localizedDescription)). Tap to restart."))
        }
    }

    private func restartEngineInput() throws {
        engine.stop()
        removeTap()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "VoiceAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "No microphone input is available.")])
        }
        installTap()
        engine.prepare()
        try engine.start()
    }

    func tick() {
        let t = now()
        let w = levelWindow
        levelWindow = LevelWindow()
        reportOutput()
        guard usesMicrophone else { return }
        let output = outputState()

        guard !interrupted, problem == nil, let last = lastBuffer, t.timeIntervalSince(last) >= stallTimeout else { return }

        restart(reason: "stall")
    }

    /// `voice-out` once a second while reply audio is pending or playing, and once after.
    private func reportOutput() {
        let active = !pendingBuffers.isEmpty || outBytes > 0 || player.isPlaying && outWindow.max > 0 || clipPlayer?.isPlaying == true
        if active || outputWasActive {
            let o = outWindow

        }
        outputWasActive = active
        outWindow = LevelWindow()
        outBytes = 0
        playedSeconds = 0
    }

    private static func round(_ v: Float) -> Double { (Double(v) * 100_000).rounded() / 100_000 }

    private static func code(_ output: VoiceEndpointer.Output) -> String {
        switch output { case .quiet: return "quiet"; case .suppressed: return "suppressed"; case .playing: return "playing" }
    }

    /// What our speaker is doing, for the endpointer.
    func outputState() -> VoiceEndpointer.Output {
        // Paused for the user's speech: nothing plays, so their speech is judged as in the quiet.
        if !speechPaused, !pendingBuffers.isEmpty || clipPlayer?.isPlaying == true { return .playing }
        if let until = suppressUntil, now() < until { return .suppressed }
        return .quiet
    }

    private func suppress(for seconds: TimeInterval) {
        let until = now().addingTimeInterval(seconds)
        if suppressUntil.map({ $0 < until }) ?? true { suppressUntil = until }
    }

    private func report(_ line: String?) {
        guard line != problem else { return }
        problem = line
        onProblem?(line)
    }

    // MARK: Input

    private func installTap() {
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // AVAudioEngine reuses the tap's buffer: copy before leaving the audio thread.
            guard let copy = VoiceAudioEngine.copy(buffer) else { return }
            Task { @MainActor in self?.process(copy) }
        }
        tapInstalled = true
    }

    private func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// A deep copy of `buffer` (float formats; other formats return nil).
    nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        guard let src = buffer.floatChannelData, let dst = copy.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.format.isInterleaved ? channels : 1
        let planes = buffer.format.isInterleaved ? 1 : channels
        for c in 0..<planes { memcpy(dst[c], src[c], Int(buffer.frameLength) * stride * MemoryLayout<Float>.size) }
        return copy
    }

    /// One input buffer (mic tap or file feed). Internal for tests.
    func process(_ buffer: AVAudioPCMBuffer) {
        lastBuffer = now()
        guard !muted, !interrupted, let channel = buffer.floatChannelData?[0] else { return }
        let level = VoiceEndpointer.rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        levelWindow.add(level)
        meterWindow.add(level)
        let output = outputState()
        if meterWindow.count >= max(1, Int(0.1 / max(duration, 0.001))) {
            onLevel?(meterWindow.max, endpointer.trigger(for: output))
            meterWindow = LevelWindow()
        }
        let event = endpointer.feed(level: level, duration: duration, output: output, replyAudible: replyAudible,
                                    outputLevel: recentOutputLevel())
        if event == .speechStarted {
            startRecording(format: buffer.format)
            // The onset window that confirmed speech is part of the utterance.
            for early in preroll where early.format == buffer.format { try? recorder?.write(from: early); onSpeechBuffer?(early) }
            preroll = []
            onSpeechStarted?()
        } else if !endpointer.inSpeech {
            preroll.append(buffer)
            if preroll.count > 16 { preroll.removeFirst() }
        }
        if endpointer.inSpeech || event != nil {
            utteranceSeconds += duration
            if let recorder {
                do { try recorder.write(from: buffer) } catch {
                    if !recordingFailed {
                        recordingFailed = true

                    }
                }
            }
            onSpeechBuffer?(buffer)
        }
        switch event {
        case .utteranceEnded?: finishRecording(deliver: true)
        case .discarded?:
            finishRecording(deliver: false)
            if endpointer.lastDiscardWasEcho {

            }
            onSpeechDiscarded?()
        default: break
        }
    }

    private func dropUtterance() {
        guard endpointer.inSpeech else { return }
        endpointer.reset()
        finishRecording(deliver: false)
        onSpeechDiscarded?()
    }

    private func startRecording(format: AVAudioFormat) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        // AAC at the input's own rate, mono: AVAudioFile writes only buffers in
        // its processing format, so it can't resample to 16 kHz here.
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 32000 * Int(format.channelCount)]
        recordingFailed = false
        utteranceSeconds = 0
        do {
            recorder = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                       interleaved: format.isInterleaved)
            recordingURL = url
        } catch {
            recorder = nil
            recordingURL = nil
            recordingFailed = true

            report(String(localized: "Couldn't record what you said (\(error.localizedDescription))."))
        }
    }

    private func finishRecording(deliver: Bool) {
        recorder = nil  // closes the file
        let seconds = utteranceSeconds
        utteranceSeconds = 0
        guard let url = recordingURL else {
            if deliver {

                onSpeechDiscarded?()  // ends the hold on our audio
            }
            return
        }
        recordingURL = nil
        defer { try? FileManager.default.removeItem(at: url) }
        guard deliver else { return }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {

            report(String(localized: "Couldn't record what you said."))
            onSpeechDiscarded?()
            return
        }
        if problem != nil, problem != Self.micStoppedLine { report(nil) }
        onUtterance?(data, seconds)
    }


    // MARK: Output

    func beginSpeech(sampleRate: Int, channels: Int) {
        if configured, let current = playerFormat, Int(current.sampleRate) != sampleRate, sampleRate > 0,
           let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false) {

            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            playerFormat = format
        } else if !configured, sampleRate > 0 {
            playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)
        }
        carry = nil
        flushStaging()
        prebuffering = true
        audibleBase = 0
        audibleSince = nil
        replyIndex += 1

        startPlayer()
    }

    /// Reply audio is scheduled in buffers of at least `chunkSeconds` (a server frame is
    /// ~28 ms; thousands of tiny buffers underrun on jitter), and a reply starts only once
    /// `prebufferSeconds` is queued or its stream ended. When the queue runs dry the
    /// staged remainder goes out at once rather than waiting to fill a chunk.
    var chunkSeconds: Double = 0.15
    var prebufferSeconds: Double = 0.2
    private var staging: [Float] = []
    private var prebuffering = false

    func enqueue(pcm: Data) {
        let format = playerFormat ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        outBytes += pcm.count
        // Provider frames aren't sample-aligned: an odd trailing byte is the low byte of
        // a sample whose high byte opens the next frame, so carry it over.
        var bytes = pcm
        if let carried = carry { bytes.insert(carried, at: bytes.startIndex); carry = nil }
        if bytes.count % 2 == 1 { carry = bytes.removeLast() }
        let count = bytes.count / 2
        guard count > 0 else { return }
        bytes.withUnsafeBytes { raw in
            for i in 0..<count { staging.append(Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768) }
        }
        let rate = format.sampleRate
        if prebuffering {
            guard Double(staging.count) >= prebufferSeconds * rate else { return }
            prebuffering = false
            flushStaging()
            return
        }
        if pendingBuffers.isEmpty || Double(staging.count) >= chunkSeconds * rate { flushStaging() }
    }

    /// Schedules everything staged as one buffer.
    private func flushStaging() {
        guard !staging.isEmpty else { return }
        let format = playerFormat ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(staging.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(staging.count)
        staging.withUnsafeBufferPointer { src in buffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count) }
        staging.removeAll(keepingCapacity: true)
        append(buffer)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        nextBufferID += 1
        pendingBuffers.append((nextBufferID, buffer))
        schedule(id: nextBufferID, buffer)
        startPlayer()
        markAudible(true)
    }

    private func schedule(id: Int, _ buffer: AVAudioPCMBuffer) {
        buffersScheduled += 1
        guard configured else { return }
        let generation = playGeneration
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in self?.bufferPlayed(id: id, generation: generation) }
        }
    }

    /// `player.play()` needs a running engine; a stopped engine is started first.
    private func startPlayer() {
        guard configured else { return }
        if !engine.isRunning {
            do { engine.prepare(); try engine.start() } catch {

                return
            }
        }
        if !speechPaused, !player.isPlaying { player.play() }
    }

    /// True while reply playback is held for the user's speech (`pauseSpeech`).
    private(set) var speechPaused = false
    private(set) var pausedAt: Date?
    /// Seconds the current reply (or line) has been audible (wall clock while it plays unpaused),
    /// for the endpointer's echo check; `.infinity` before the first reply.
    var replyAudible: TimeInterval { audibleBase + (audibleSince.map { now().timeIntervalSince($0) } ?? 0) }
    private var audibleBase: TimeInterval = .infinity
    private var audibleSince: Date?
    private func markAudible(_ on: Bool) {
        if on { if audibleSince == nil, !speechPaused, !pendingBuffers.isEmpty { audibleSince = now() }; return }
        if let since = audibleSince { audibleBase += now().timeIntervalSince(since) }
        audibleSince = nil
    }
    /// Output levels (mixer tap RMS) of about the last second, for the endpointer's echo check.
    private var outputLevels: [(at: Date, level: Float)] = []

    /// One output level as rendered (mixer tap; tests call it directly).
    func noteOutputLevel(_ level: Float) {
        let t = now()
        outputLevels.append((t, level))
        outputLevels.removeAll { t.timeIntervalSince($0.at) > 1 }
    }

    private func recentOutputLevel() -> Float {
        let t = now()
        return outputLevels.filter { t.timeIntervalSince($0.at) <= 1 }.map(\.level).max() ?? 0
    }

    /// Holds playback where it is, keeping every queued buffer and the stream.
    func pauseSpeech() {
        guard !speechPaused else { return }
        speechPaused = true
        pausedAt = now()
        markAudible(false)
        if !pendingBuffers.isEmpty || clipPlayer != nil {

        }
        if configured, player.isPlaying { player.pause() }
        clipPlayer?.pause()
    }

    /// Continues a paused reply from where it stopped (reason "resumed" is logged).
    func resumeSpeech(reason: String) {
        guard speechPaused else { return }
        speechPaused = false
        let pausedMs = pausedAt.map { Int((now().timeIntervalSince($0) * 1000).rounded()) } ?? 0
        pausedAt = nil
        if reason == "resumed" {

        }
        if !pendingBuffers.isEmpty { startPlayer() }
        markAudible(true)
        clipPlayer?.play()
    }

    /// After a mic restart: the engine stop dropped the player's queue, so the
    /// unplayed reply buffers are scheduled again and playback resumes.
    private func rescheduleReply() -> Int {
        guard !pendingBuffers.isEmpty else { return 0 }
        if configured { player.stop() }
        for item in pendingBuffers { schedule(id: item.id, item.buffer) }
        rescheduledAfterRestart += pendingBuffers.count
        startPlayer()
        return pendingBuffers.count
    }

    /// int16 little-endian mono → float32 buffer.
    static func buffer(fromInt16 pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let count = pcm.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        let out = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            for i in 0..<count { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
        }
        return buffer
    }

    private func bufferPlayed(id: Int, generation: Int) {
        guard generation == playGeneration, let index = pendingBuffers.firstIndex(where: { $0.id == id }) else { return }
        let played = pendingBuffers.remove(at: index).buffer
        buffersPlayed += 1
        playedSeconds += Double(played.frameLength) / played.format.sampleRate
        guard pendingBuffers.isEmpty else { return }
        // Ran dry mid-stream: whatever is staged goes out now.
        if !staging.isEmpty { prebuffering = false; flushStaging(); return }
        markAudible(false)
        suppress(for: echoTail)
        // An underrun mid-stream also empties the queue; only the end of the reply closes the capture.
        if let done = drained { drained = nil; done() }
    }

    var queuedSpeechSeconds: TimeInterval {
        let rate = playerFormat?.sampleRate ?? 24000
        return pendingBuffers.reduce(Double(staging.count)) { $0 + Double($1.buffer.frameLength) } / rate
    }

    func finishSpeech(onDrained: @escaping () -> Void) {
        prebuffering = false
        flushStaging()
        if pendingBuffers.isEmpty { onDrained() } else { drained = onDrained }
    }

    func playClip(_ data: Data, onDrained: @escaping () -> Void) {
        guard let clip = try? AVAudioPlayer(data: data) else { onDrained(); return }
        let delegate = ClipDelegate { [weak self] in
            guard let self else { return }
            self.suppress(for: self.echoTail)
            onDrained()
        }
        clipDelegate = delegate
        clip.delegate = delegate
        clipPlayer = clip
        if !speechPaused { clip.play() }
    }

    func stopSpeech(reason: String) {
        let hadAudio = !pendingBuffers.isEmpty || clipPlayer != nil

        drained = nil
        markAudible(false)
        pendingBuffers = []
        staging = []
        prebuffering = false
        carry = nil

        playGeneration += 1
        if configured { player.stop() }
        clipPlayer?.stop()
        clipPlayer = nil
        if hadAudio { suppress(for: echoTail) }
    }

    func earcon() {
        // The chime and its room echo must not start "speech" (phone run 1: it came back at 0.04).
        suppress(for: 0.1 + echoTail)
        guard configured, let format = playerFormat, let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400) else { return }
        tone.frameLength = 2400
        let out = tone.floatChannelData![0]
        let frames = Int(tone.frameLength)
        for i in 0..<frames { out[i] = 0.15 * sin(Float(i) * 2 * .pi * 880 / Float(format.sampleRate)) * (1 - Float(i) / Float(frames)) }
        suppress(for: Double(frames) / format.sampleRate + echoTail)
        player.scheduleBuffer(tone)
        startPlayer()
    }

    /// Measures what actually reaches the output (voice-out `out_max`/`out_mean`).
    private func installMixerTap() {
        guard !mixerTapInstalled else { return }
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 2048, format: mixer.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let level = VoiceEndpointer.rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            Task { @MainActor in self?.outWindow.add(level); self?.noteOutputLevel(level); self?.onOutputLevel?(level) }
        }
        mixerTapInstalled = true
    }


    private final class ClipDelegate: NSObject, AVAudioPlayerDelegate {
        let done: () -> Void
        init(_ done: @escaping () -> Void) { self.done = done }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            DispatchQueue.main.async { self.done() }
        }
    }
}
