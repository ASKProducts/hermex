import AVFoundation
import XCTest
@testable import HermesMobile

@MainActor final class VoiceEchoTests: XCTestCase {
    struct SignalCase {
        let name: String
        /// Seconds of the reply audible before the speech start (first-pcm + 0.2 s prebuffer → pause).
        let audible: TimeInterval
        /// The loudest output level in the second before the speech started (`voice-out` out_max).
        let output: Float
        /// The burst's / the user's peak mic level (`voice-level` max).
        let peak: Float
        /// Voiced seconds after speech start (utterance duration minus the 1.5 s endpoint silence).
        let voiced: TimeInterval
        let words: String
        let echo: Bool
    }

    static let echoCases = [
        SignalCase(name: "echo-1", audible: 1.15, output: 0.133, peak: 0.427, voiced: 0.1, words: "Sample output is ready now.", echo: true),
        SignalCase(name: "echo-2", audible: 3.0, output: 0.200, peak: 0.176, voiced: 0.1, words: "Sample output.", echo: true),
        SignalCase(name: "echo-3", audible: 21.8, output: 0.121, peak: 0.321, voiced: 0.1, words: "Ready now.", echo: true),
        SignalCase(name: "echo-4", audible: 1.0, output: 0.114, peak: 0.130, voiced: 0.1, words: "Is the sample ready?", echo: true),
    ]

    static let realCases = [
        SignalCase(name: "interruption-1", audible: 13.9, output: 0.100, peak: 0.110, voiced: 2.6, words: "alpha bravo charlie delta echo foxtrot golf hotel india", echo: false),
        SignalCase(name: "interruption-2", audible: 31.1, output: 0.125, peak: 0.111, voiced: 1.9, words: "alpha bravo charlie delta echo foxtrot golf", echo: false),
        SignalCase(name: "interruption-3", audible: 64.7, output: 0.110, peak: 0.146, voiced: 1.8, words: "alpha bravo charlie delta echo foxtrot golf hotel", echo: false),
        SignalCase(name: "interruption-4", audible: 9.3, output: 0.114, peak: 0.144, voiced: 2.4, words: "alpha bravo charlie delta echo foxtrot golf", echo: false),
        SignalCase(name: "interruption-5", audible: 3.3, output: 0.140, peak: 0.166, voiced: 3.2, words: "alpha bravo charlie delta echo foxtrot golf hotel", echo: false),
        SignalCase(name: "interruption-6", audible: 2.3, output: 0.167, peak: 0.075, voiced: 18.7, words: "alpha bravo", echo: false),
        SignalCase(name: "interruption-7", audible: 56.2, output: 0.091, peak: 0.123, voiced: 3.4, words: "alpha bravo", echo: false),
        SignalCase(name: "interruption-8", audible: 25.7, output: 0.096, peak: 0.128, voiced: 28.4, words: "alpha bravo", echo: false),
    ]

    struct Outcome { var bargedIn = false; var transcribed = 0; var pausedMs: Int?; var resumed = false; var echoEvents = 0 }

    /// Plays a reply, feeds `c` as mic input at its real timing, and reports what the session did.
    func replay(_ c: SignalCase, oldRule: Bool = false) async throws -> Outcome {
        var clock = Date(timeIntervalSince1970: 1000)
        var pausedAt: Date?
        var resumedMs: Int?
        var echoDiscards = 0
        let backend = FakeVoiceBackend()
        let engine = VoiceAudioEngine()
        engine.now = { clock }
        if oldRule {
            // The pre-fix endpointer: no echo window, no level check.
            engine.endpointer.echoWindow = 0
            engine.endpointer.echoLevelRatio = .infinity
        }
        let session = VoiceSession(backend: backend, player: engine, now: { clock })
        session.transcribeRetryDelay = .zero
        session.joinWindow = 0
        var pending: [Task<Void, Never>] = []
        engine.onSpeechStarted = { [weak session, weak engine] in
            session?.speechStarted()
            if engine?.speechPaused == true { pausedAt = clock }
        }
        engine.onSpeechDiscarded = { [weak session, weak engine] in
            let wasPaused = engine?.speechPaused == true
            if engine?.endpointer.lastDiscardWasEcho == true { echoDiscards += 1 }
            session?.speechDiscarded()
            if wasPaused, engine?.speechPaused == false, let pausedAt {
                resumedMs = Int(clock.timeIntervalSince(pausedAt) * 1000)
            }
        }
        engine.onUtterance = { [weak session] data, _ in
            session?.speechEnded()
            pending.append(Task { await session?.utterance(audio: data, mimeType: "audio/m4a", caption: nil) })
        }
        await session.start()
        let mic = { (level: Float, out: Float) in
            engine.noteOutputLevel(engine.speechPaused ? 0 : out)
            engine.process(Self.buffer(level: level))
            clock += 0.1
        }
        for _ in 0..<20 { mic(0.0001, 0) }  // calibration, nothing playing
        session.speechEnded()
        await session.utterance(text: "question")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("Sample output is ready now. Here is the answer.")])
        await backend.speakOpened()
        let socket = try XCTUnwrap(backend.speakSockets.first)
        socket.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        socket.push(.data(Data(count: 9600)))  // the prebuffer: one buffer queued (the unconfigured engine never drains it)
        await waitUntil { session.phase == .speaking && engine.pendingReplyBuffers > 0 }
        XCTAssertEqual(session.phase, .speaking, c.name)
        backend.transcript = c.words
        let transcribedBefore = backend.transcribed.count

        // The reply plays with the phone's bleed under echo cancellation (median ~0.0003)
        // until the burst, which needs 0.3 s above the trigger to start speech.
        let lead = max(0, Int(((c.audible - 0.3) * 10).rounded()))
        for _ in 0..<lead { mic(0.0003, c.output) }
        for level in [c.peak, c.peak * 0.6, c.peak * 0.5] { mic(level, c.output) }
        XCTAssertTrue(engine.endpointer.inSpeech, "\(c.name): speech started")
        // Voiced part after the start (real speech dips briefly between words, never 0.5 s).
        let pattern: [Float] = [1, 0.5, 0.35, 0, 0.45, 0.6, 0.3, 0.4]
        for i in 0..<Int((c.voiced * 10).rounded()) {
            let p = pattern[i % pattern.count]
            mic(p == 0 ? 0.004 : max(0.012, c.peak * p), c.output)
        }
        for _ in 0..<25 { mic(0.00005, c.output) }  // the endpoint silence
        for task in pending { await task.value }

        var outcome = Outcome()
        outcome.bargedIn = engine.pendingReplyBuffers == 0
        outcome.transcribed = backend.transcribed.count - transcribedBefore
        outcome.resumed = resumedMs != nil
        outcome.pausedMs = resumedMs
        outcome.echoEvents = echoDiscards
        await session.end()
        return outcome
    }

    func testEchoAtReplyOnsetNoLongerCutsTheReply() async throws {
        for c in Self.echoCases {
            let before = try await replay(c, oldRule: true)
            let after = try await replay(c)
            XCTAssertTrue(before.bargedIn, "\(c.name): the old rule cut the reply (as on the phone)")
            XCTAssertFalse(after.bargedIn, "\(c.name): echo must not cut the reply")
            XCTAssertTrue(after.resumed, "\(c.name): the reply resumes")
            XCTAssertEqual(after.transcribed, 0, "\(c.name): echo is never transcribed or sent")
            XCTAssertEqual(after.echoEvents, 1, "\(c.name): the endpointer discarded exactly one echo burst")
            XCTAssertLessThanOrEqual(after.pausedMs ?? .max, 800, "\(c.name): paused at most ~0.8 s")
        }
    }

    func testRealBargeInsStillCutTheReply() async throws {
        for c in Self.realCases {
            let before = try await replay(c, oldRule: true)
            let after = try await replay(c)
            XCTAssertTrue(before.bargedIn, c.name)
            XCTAssertTrue(after.bargedIn, "\(c.name): a real barge-in still cuts the reply")
            XCTAssertEqual(after.transcribed, 1, c.name)
            XCTAssertEqual(after.echoEvents, 0, c.name)
        }
    }

    func testSpeechStartedBeforeTheReplyIsNotEchoChecked() {
        // Speech starts during tool work; output begins before the user finishes.
        var vad = VoiceEndpointer()
        var events: [VoiceEndpointer.Event] = []
        for _ in 0..<20 { if let e = vad.feed(level: 0.0001, duration: 0.1) { events.append(e) } }
        for _ in 0..<3 { if let e = vad.feed(level: 0.059, duration: 0.1) { events.append(e) } }
        XCTAssertEqual(events, [.speechStarted])
        // A dip right as the reply starts must not discard it.
        for _ in 0..<6 { if let e = vad.feed(level: 0.0001, duration: 0.1, output: .playing, replyAudible: 0.2, outputLevel: 0.1) { events.append(e) } }
        for _ in 0..<15 { if let e = vad.feed(level: 0.05, duration: 0.1, output: .playing, replyAudible: 1, outputLevel: 0.1) { events.append(e) } }
        XCTAssertEqual(events, [.speechStarted], "no echo discard")
        XCTAssertFalse(vad.lastDiscardWasEcho)
    }

    func testOutsideTheWindowOrdinarySpeechIsUnchanged() {
        // A short burst late in a reply at the reply's own level: exactly today's path (no early discard).
        var vad = VoiceEndpointer()
        var events: [VoiceEndpointer.Event] = []
        func feed(_ level: Float, _ n: Int, audible: TimeInterval) {
            for _ in 0..<n { if let e = vad.feed(level: level, duration: 0.1, output: .playing, replyAudible: audible, outputLevel: 0.12) { events.append(e) } }
        }
        for _ in 0..<20 { _ = vad.feed(level: 0.0001, duration: 0.1) }
        feed(0.0003, 10, audible: 10)
        feed(0.15, 4, audible: 11)
        feed(0.00005, 6, audible: 11)
        XCTAssertEqual(events, [.speechStarted], "0.6 s of quiet doesn't end it outside the window")
        feed(0.00005, 10, audible: 12)
        XCTAssertEqual(events, [.speechStarted, .utteranceEnded])
    }

    static func buffer(level: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = i % 2 == 0 ? level : -level }
        return buffer
    }
}
