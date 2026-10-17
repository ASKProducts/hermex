import AVFoundation
import XCTest
@testable import HermesMobile

@MainActor final class VoiceModeTests: XCTestCase {
    func testChatComposerVoiceStateMapsAvailabilityAndRunningCall() {
        XCTAssertEqual(ComposerVoiceCallState(availability: .available(profile: "default"), callIsRunning: false), .enabled)
        XCTAssertEqual(ComposerVoiceCallState(availability: .available(profile: "default"), callIsRunning: true), .disabled)
        XCTAssertEqual(ComposerVoiceCallState(availability: .busy, callIsRunning: false), .disabled)
        XCTAssertEqual(ComposerVoiceCallState(availability: .busy, callIsRunning: true), .disabled)
        XCTAssertEqual(ComposerVoiceCallState(availability: .hidden, callIsRunning: false), .hidden)
        XCTAssertEqual(ComposerVoiceCallState(availability: .hidden, callIsRunning: true), .hidden)
    }

    // MARK: BotClient validators

    func testVoiceShapesAreAcceptedAndOthersStillRefused() async throws {
        let socket = VoiceScriptedSocket()
        socket.reply = { request in
            if request["method"].text == "session.create" {
                return .object(["id": request["id"], "result": .object(["session_id": .string("rt-1"), "stored_session_id": .string("key-1")])])
            }
            return .object(["id": request["id"], "result": .object(["ok": .bool(true)])])
        }
        let client = try await connectedClient(socket)
        defer { client.close() }

        let created = try await client.call(.voiceSessionCreate)
        XCTAssertEqual(created["stored_session_id"].text, "key-1")
        _ = try await client.call(.voicePromptSubmit(sessionID: "rt-1", text: "hi", interrupted: true))
        _ = try await client.call(.voicePromptSubmit(sessionID: "rt-1", text: "hi", interrupted: false))

        // The typed cases leave no room for the old refused shapes (a profile or title on the
        // voice create, a non-Bool `interrupted`, a `surface` beside it, `session.delete`); the
        // value rules that remain are still refused before dispatch.
        let refused: [HermesCall] = [
            .voicePromptSubmit(sessionID: "rt-1", text: "", interrupted: true),
            .voicePromptSubmit(sessionID: "", text: "hi", interrupted: true),
            .voiceLivePromptSubmit(sessionID: "rt-1", text: "hi", voiceContext: String(repeating: "c", count: 6_001)),
            .voiceSessionResume(sessionID: "", profile: nil),
            .sessionCreate(profile: ""),
        ]
        for call in refused { await assertRefused(client, call) }
        XCTAssertEqual(try HermesCall.voiceSessionCreate.params(), ["hidden": .bool(false)])
        // The Bot Chat shape still passes.
        _ = try await client.call(.sessionCreate(profile: "default"))
        XCTAssertEqual(socket.sentMethods, ["session.create", "prompt.submit", "prompt.submit", "session.create"])
    }

    func testVoiceRoutesAndSpeakStreamURL() throws {
        let base = URL(string: "http://100.101.100.67:9129")!
        let ws = try BotVoiceRPC.speakStreamURL(base: base, ticket: "t1")
        XCTAssertEqual(ws.scheme, "ws")
        XCTAssertEqual(ws.path, "/api/audio/speak-stream")
        XCTAssertEqual(ws.query, "ticket=t1", "no profile: the dashboard's own profile speaks")
        XCTAssertEqual(try BotVoiceRPC.speakStreamURL(base: URL(string: "https://h.example")!, ticket: "t").scheme, "wss")
        XCTAssertThrowsError(try BotVoiceRPC.speakStreamURL(base: base, ticket: ""))
        XCTAssertEqual(BotClient.decodeDataURL("data:audio/mpeg;base64,AAEC"), Data([0, 1, 2]))
        XCTAssertNil(BotClient.decodeDataURL("https://x"))
    }

    func testNativeHTTPAndFreshTicketPerSpeakStream() async throws {
        var tickets = 0
        var bodies: [String: BotJSON] = [:]
        VoiceHTTPFixture.handler = { request in
            let path = request.url!.path
            if let stream = request.httpBodyStream {
                stream.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 65536)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
                bodies[path] = try? JSONDecoder().decode(BotJSON.self, from: data)
            }
            switch path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object(["ok": .bool(true)]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/profiles/active": return (200, .object(["current": .string("default")]))
            case "/api/auth/ws-ticket": tickets += 1; return (200, .object(["ticket": .string("ticket-\(tickets)")]))
            case "/api/audio/transcribe": return (200, .object(["ok": .bool(true), "transcript": .string(" hello there "), "provider": .string("openai")]))
            default: XCTFail("Unexpected " + path); return (404, .null)
            }
        }
        defer { VoiceHTTPFixture.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceHTTPFixture.self]
        var urls: [URL] = []
        let client = BotClient(connection: connection(), configuration: configuration) { request in
            urls.append(request.url!); return VoiceScriptedSocket()
        }
        try await client.connect()
        defer { client.close() }
        let text = try await client.transcribeVoice(sessionKey: "key-1", audio: Data([1, 2, 3]), mimeType: "audio/m4a")
        XCTAssertEqual(text, "hello there")
        let body = bodies["/api/audio/transcribe"]
        XCTAssertEqual(body?["mime_type"].text, "audio/m4a")
        XCTAssertEqual(body?["data_url"].text, "data:audio/m4a;base64,AQID")
        _ = try await client.openSpeakStream()
        _ = try await client.openSpeakStream()
        XCTAssertEqual(tickets, 3)
        XCTAssertEqual(urls.dropFirst().map(\.query), ["ticket=ticket-2", "ticket=ticket-3"])
    }

    // MARK: Text rules

    func testStopPhrasesMatchWholeUtterancesOnly() {
        for phrase in ["stop", "Stop.", "Hey Hermes, stop!", "okay that's all", "never mind", "Goodbye", "hermes cancel", "please stop"] {
            XCTAssertTrue(VoiceText.isStopCommand(phrase), phrase)
        }
        for phrase in ["", "hermes", "stop the server", "don't stop", "can you cancel my meeting", "bye bye now"] {
            XCTAssertFalse(VoiceText.isStopCommand(phrase), phrase)
        }
    }

    func testApprovalAndChoicePhrases() {
        XCTAssertEqual(VoiceText.approvalAnswer("Approve."), .approve)
        XCTAssertEqual(VoiceText.approvalAnswer("yes"), .approve)
        XCTAssertEqual(VoiceText.approvalAnswer("Hermes, deny"), .deny)
        XCTAssertEqual(VoiceText.approvalAnswer("no"), .deny)
        XCTAssertNil(VoiceText.approvalAnswer("yes but also delete the logs"))
        XCTAssertNil(VoiceText.approvalAnswer("always"))
        XCTAssertEqual(VoiceText.choiceIndex("two", choices: ["a", "b", "c"]), 1)
        XCTAssertEqual(VoiceText.choiceIndex("option 3", choices: ["a", "b", "c"]), 2)
        XCTAssertEqual(VoiceText.choiceIndex("Blue", choices: ["Red", "Blue"]), 1)
        XCTAssertNil(VoiceText.choiceIndex("four", choices: ["a", "b"]))
    }

    func testPronunciationsReplaceWholeWords() {
        let out = VoiceText.applyPronunciations("Hermex uses CalDAV; Hermexes stay.", VoiceText.defaultPronunciations)
        XCTAssertEqual(out, "Her-mex uses cal-dav; Hermexes stay.")
    }

    func testProgressTableAndPacing() {
        XCTAssertEqual(VoiceText.progressPhrase(tool: "terminal"), "Running a command.")
        XCTAssertEqual(VoiceText.progressPhrase(tool: "search_files"), "Reading files.")
        XCTAssertEqual(VoiceText.progressPhrase(tool: "browser_click"), "Using the browser.")
        XCTAssertEqual(VoiceText.progressPhrase(tool: "mystery"), "Still working.")
        var pacer = VoiceProgressPacer()
        let t0 = Date(timeIntervalSince1970: 0)
        pacer.reset(sentAt: t0)
        XCTAssertNil(pacer.phrase(latestTool: "terminal", now: t0.addingTimeInterval(5), replyStarted: false))
        XCTAssertEqual(pacer.phrase(latestTool: "terminal", now: t0.addingTimeInterval(6), replyStarted: false), "Running a command.")
        XCTAssertNil(pacer.phrase(latestTool: "read_file", now: t0.addingTimeInterval(20), replyStarted: false), "within 20 s")
        XCTAssertNil(pacer.phrase(latestTool: "terminal", now: t0.addingTimeInterval(40), replyStarted: false), "same status")
        XCTAssertEqual(pacer.phrase(latestTool: "read_file", now: t0.addingTimeInterval(40), replyStarted: false), "Reading files.")
        XCTAssertNil(pacer.phrase(latestTool: "web_search", now: t0.addingTimeInterval(90), replyStarted: true))
    }

    func testEndpointerNeedsSilenceAndMinimumSpeech() {
        var vad = VoiceEndpointer()
        XCTAssertEqual(run(&vad, level: 0.0001, seconds: 1), [])
        XCTAssertEqual(run(&vad, level: 0.2, seconds: 0.5), [.speechStarted])
        XCTAssertEqual(run(&vad, level: 0, seconds: 1.4), [])
        XCTAssertEqual(run(&vad, level: 0, seconds: 0.2), [.utteranceEnded])
        var short = VoiceEndpointer()
        _ = run(&short, level: 0.0001, seconds: 1)
        // 0.13 s of speech: past the onset, under the 0.2 s minimum.
        XCTAssertEqual(run(&short, level: 0.3, seconds: 0.13), [.speechStarted])
        XCTAssertEqual(run(&short, level: 0, seconds: 1.6), [.discarded])
    }

    // MARK: Real-mic endpointing and mic health (round 4)

    /// 1024-frame buffers at 48 kHz, as the phone's tap delivers them.
    private static let frame = 1024.0 / 48000

    private func run(_ vad: inout VoiceEndpointer, level: Float, seconds: Double) -> [VoiceEndpointer.Event] {
        var events: [VoiceEndpointer.Event] = []
        for _ in 0..<Int(seconds / Self.frame) { if let e = vad.feed(level: level, duration: Self.frame) { events.append(e) } }
        return events
    }

    func testQuietSpeechOverAQuietRoomTriggersAndEnds() {
        var vad = VoiceEndpointer()
        XCTAssertEqual(run(&vad, level: 0.001, seconds: 2), [], "a quiet room is not speech")
        XCTAssertEqual(vad.floor ?? 0, 0.001, accuracy: 0.0002)
        for speech: Float in [0.015, 0.03, 0.05] {
            var v = vad
            let events = run(&v, level: speech, seconds: 1.2) + run(&v, level: 0.001, seconds: 1.6)
            XCTAssertEqual(events, [.speechStarted, .utteranceEnded], "RMS \(speech) over a 0.001 floor is speech")
        }
    }

    func testSteadyNoiseNeverTriggers() {
        for noise: Float in [0.003, 0.009, 0.02, 0.05, 0.1] {
            var vad = VoiceEndpointer()
            XCTAssertEqual(run(&vad, level: noise, seconds: 60), [], "steady noise \(noise) is not speech")
            XCTAssertGreaterThan(vad.threshold, noise)
        }
    }

    func testSpeechOverNoiseTriggersAndNoiseRisingSlowlyIsLearned() {
        var vad = VoiceEndpointer()
        XCTAssertEqual(run(&vad, level: 0.02, seconds: 3), [])
        XCTAssertEqual(run(&vad, level: 0.12, seconds: 1) + run(&vad, level: 0.02, seconds: 1.6), [.speechStarted, .utteranceEnded])
        // A fan switching on: the level ramps up over 10 s and must not count as speech.
        var level: Float = 0.001
        var quiet = VoiceEndpointer()
        _ = run(&quiet, level: 0.001, seconds: 2)
        var events: [VoiceEndpointer.Event] = []
        for _ in 0..<Int(10 / Self.frame) {
            level = min(0.03, level * 1.0012)
            if let e = quiet.feed(level: level, duration: Self.frame) { events.append(e) }
        }
        XCTAssertEqual(events, [])
    }

    func testThresholdHasAnAbsoluteMinimumAndTheFloorNeverCollapsesToZero() {
        var vad = VoiceEndpointer()
        XCTAssertEqual(run(&vad, level: 0, seconds: 5), [])
        XCTAssertEqual(vad.threshold, vad.minimumThreshold)
        XCTAssertGreaterThan(vad.floor ?? 0, 0, "digital silence clamps the floor above zero")
        XCTAssertEqual(run(&vad, level: 0.008, seconds: 1), [], "below the absolute minimum")
        XCTAssertEqual(run(&vad, level: 0.03, seconds: 0.5).first, .speechStarted)
    }

    // MARK: Playback speech detection

    private func phoneSecond(max peak: Float, mean: Float, peakFrames n: Int = 1) -> [Float] {
        let frames = Int((1 / Self.frame).rounded())
        let rest = Swift.max(0, (mean * Float(frames) - peak * Float(n)) / Float(frames - n))
        return (0..<frames).map { i in i % (frames / n) == 0 && i / (frames / n) < n ? peak : rest }
    }

    private func feed(_ vad: inout VoiceEndpointer, _ levels: [Float], output: VoiceEndpointer.Output = .quiet) -> [VoiceEndpointer.Event] {
        levels.compactMap { vad.feed(level: $0, duration: Self.frame, output: output) }
    }

    func testPhoneNoiseSecondsNeverStartSpeech() {
        // 02:53:06-02:53:17: floor 0.00001-0.00005; the "speech" that transcribed to "" twice
        // (max 0.00219/mean 0.00071, max 0.00519/mean 0.00105, a 3-frame 0.005 burst).
        var vad = VoiceEndpointer()
        var events = feed(&vad, Array(repeating: 0.00002, count: 50))
        for (peak, mean) in [(0.00219, 0.00071), (0.00079, 0.00029), (0.00519, 0.00105), (0.00113, 0.00018), (0.00285, 0.0005),
                             (0.01646, 0.00318), (0.00272, 0.00055), (0.0016, 0.0003)] as [(Float, Float)] {
            events += feed(&vad, phoneSecond(max: peak, mean: mean, peakFrames: 3))
        }
        XCTAssertEqual(events, [], "phone noise (a lone 0.016 click included) is not speech")
    }

    func testPhoneSpeechAt025320IsSpeech() {
        var vad = VoiceEndpointer()
        _ = feed(&vad, Array(repeating: 0.00003, count: 50))
        // 02:53:20 max 0.146 mean 0.048, 02:53:21 max 0.075 mean 0.028: speech in most frames.
        let speech = (0..<47).map { i -> Float in i % 5 == 4 ? 0.004 : [0.03, 0.06, 0.146, 0.05][i % 4] }
        let events = feed(&vad, speech) + feed(&vad, Array(repeating: 0.00003, count: 80))
        XCTAssertEqual(events, [.speechStarted, .utteranceEnded])
    }

    func testChimeAndItsTailNeverStartSpeech() {
        var vad = VoiceEndpointer()
        _ = feed(&vad, Array(repeating: 0.00003, count: 50))
        // 02:53:27: the chime came back at max 0.040 while we were `working`.
        let chime = Array(repeating: Float(0.04), count: 5) + Array(repeating: Float(0.02), count: 14)
        XCTAssertEqual(feed(&vad, chime, output: .suppressed), [])
        XCTAssertEqual(feed(&vad, Array(repeating: 0.00003, count: 20)), [])
    }

    func testReplyBleedDuringPlaybackIsNotABargeIn() {
        var vad = VoiceEndpointer()
        _ = feed(&vad, Array(repeating: 0.00003, count: 50))
        // 02:53:28-31: reply playing, bleed peaks at 0.035-0.04 for seconds.
        let bleed = (0..<140).map { i -> Float in [0.035, 0.04, 0.02, 0.03, 0.01][i % 5] }
        XCTAssertEqual(feed(&vad, bleed, output: .playing), [], "bleed alone never trips a barge-in")
        XCTAssertEqual(vad.floor ?? 1, 0.00003, accuracy: 0.00002, "the floor is held while we play")
        // Talking over it at 0.07-0.15 does.
        let talk = (0..<30).map { i -> Float in [0.07, 0.15, 0.09][i % 3] }
        XCTAssertEqual(feed(&vad, talk, output: .playing).first, .speechStarted)
    }

    func testPlaybackOnsetHasAGraceWindow() {
        var vad = VoiceEndpointer()
        _ = feed(&vad, Array(repeating: 0.00003, count: 50))
        // A loud onset transient in the first 0.5 s of playback is ignored.
        XCTAssertEqual(feed(&vad, Array(repeating: 0.2, count: 20), output: .playing), [])
        XCTAssertEqual(feed(&vad, Array(repeating: 0.2, count: 20), output: .playing).first, .speechStarted)
    }

    func testTranscribeFailureRetriesOnceThenKeepsListening() async {
        let backend = FakeVoiceBackend()
        backend.failTranscribes = 1
        let session = VoiceSession(backend: backend, player: FakePlayer())
        session.transcribeRetryDelay = .zero
        await session.start()
        session.speechStarted()
        session.speechEnded()
        await session.utterance(audio: Data([1]), mimeType: "audio/m4a", caption: nil)
        XCTAssertEqual(backend.transcribed.count, 2, "retried once with the same audio")
        XCTAssertEqual(session.turnsSubmitted, 1)
        XCTAssertFalse(session.isEnded)

        backend.failTranscribes = 2
        var errors: [String] = []
        session.onError = { place, _ in errors.append(place) }
        backend.emit("message.complete")
        session.speechStarted()
        session.speechEnded()
        await session.utterance(audio: Data([1]), mimeType: "audio/m4a", caption: nil)
        XCTAssertEqual(backend.transcribed.count, 4)
        XCTAssertFalse(session.isEnded, "two failures: say so and keep listening, don't end")
        XCTAssertEqual(errors, ["transcribe-retry", "transcribe"])
        await backend.speakOpened(count: 1)
        let line = backend.speakSockets.last!
        await line.waitForSent(1)
        XCTAssertEqual(line.sentJSON.first, .object(["text": .string(String(localized: "Sorry, I didn't catch that."))]))
    }

    func testCoalescedStartupRestarts() {
        let h = MicHarness(), engine = micEngine(h)
        engine.restartDebounce = 0.25
        post(engine, AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        post(engine, .AVAudioEngineConfigurationChange)
        post(engine, .AVAudioEngineConfigurationChange)
        XCTAssertEqual(h.restarts, 0, "waits for the burst to settle")
        engine.flushPendingRestart()
        XCTAssertEqual(h.restarts, 1, "one restart for the whole burst")
        engine.flushPendingRestart()
        XCTAssertEqual(h.restarts, 1)
    }

    func testRestartDuringReplyReschedulesTheUnplayedAudio() {
        let h = MicHarness(), engine = micEngine(h)
        engine.prebufferSeconds = 0.05
        engine.chunkSeconds = 0.05
        engine.beginSpeech(sampleRate: 24000, channels: 1)
        engine.enqueue(pcm: Data(count: 4800))
        engine.enqueue(pcm: Data(count: 4800))
        XCTAssertEqual(engine.pendingReplyBuffers, 2)
        post(engine, .AVAudioEngineConfigurationChange)
        XCTAssertEqual(h.restarts, 1)
        XCTAssertEqual(engine.pendingReplyBuffers, 2, "unplayed reply audio survives the restart")
        XCTAssertEqual(engine.rescheduledAfterRestart, 2)
        var drained = false
        engine.finishSpeech { drained = true }
        XCTAssertFalse(drained, "the reply still has to play")
        engine.stopSpeech(reason: "end")
        XCTAssertEqual(engine.pendingReplyBuffers, 0)
    }

    func testUtteranceEndingDuringTheReplyDoesNotStopOrHideIt() async throws {
        // Phone run 1: an utterance started by our own chime ended while the reply played; the
        // screen went to "Sending" over the reply. An empty transcript must leave the reply alone.
        let backend = FakeVoiceBackend(), player = FakePlayer()
        let session = VoiceSession(backend: backend, player: player)
        await session.start()
        session.speechEnded()
        await session.utterance(text: "what time is it")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("It is noon.")])
        await backend.speakOpened()
        backend.speakSockets[0].push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        await waitUntil { session.phase == .speaking }
        backend.transcript = ""
        session.speechEnded()
        await session.utterance(audio: Data([1]), mimeType: "audio/m4a", caption: nil)
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertEqual(player.stops, 0)
    }

    func testLoudNoiseDuringSpeechCannotHoldAnUtteranceOpenForever() {
        var vad = VoiceEndpointer()
        _ = run(&vad, level: 0.001, seconds: 1)
        let events = run(&vad, level: 0.2, seconds: 40)
        XCTAssertEqual(events.first, .speechStarted)
        XCTAssertTrue(events.contains(.utteranceEnded), "cut at maximumSpeech or when the floor catches up")
    }

    func testTapBufferIsDeepCopied() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        for i in 0..<1024 { buffer.floatChannelData![0][i] = Float(i) / 1024 }
        let copy = try XCTUnwrap(VoiceAudioEngine.copy(buffer))
        XCTAssertNotEqual(copy.floatChannelData![0], buffer.floatChannelData![0], "own storage")
        buffer.floatChannelData![0][5] = 99
        XCTAssertEqual(copy.floatChannelData![0][5], 5.0 / 1024)
        XCTAssertEqual(copy.frameLength, 1024)
    }

    func testMicNotificationsMapToEvents() {
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(VoiceMicEvent.from(Notification(name: .AVAudioEngineConfigurationChange)), .configurationChange)
        XCTAssertEqual(VoiceMicEvent.from(Notification(name: AVAudioSession.interruptionNotification, object: session,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])), .interruptionBegan)
        XCTAssertEqual(VoiceMicEvent.from(Notification(name: AVAudioSession.interruptionNotification, object: session,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])),
                       .interruptionEnded(shouldResume: true))
        XCTAssertEqual(VoiceMicEvent.from(Notification(name: AVAudioSession.interruptionNotification, object: session,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])),
                       .interruptionEnded(shouldResume: false))
        XCTAssertEqual(VoiceMicEvent.from(Notification(name: AVAudioSession.routeChangeNotification, object: session,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])),
                       .routeChange(reason: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue))
        XCTAssertNil(VoiceMicEvent.from(Notification(name: AVAudioSession.interruptionNotification)))
    }

    private final class MicHarness {
        var restarts = 0
        var fail: Error?
        var problems: [String?] = []
        var events: [(String, [String: Any])] = []
        var clock = Date(timeIntervalSince1970: 1000)
        func names(_ n: String) -> [[String: Any]] { events.filter { $0.0 == n }.map(\.1) }
    }

    private func micEngine(_ h: MicHarness) -> VoiceAudioEngine {
        let engine = VoiceAudioEngine()
        engine.usesMicrophone = true
        engine.inputRestarter = { h.restarts += 1; if let e = h.fail { throw e } }
        engine.onProblem = { h.problems.append($0) }
        engine.now = { h.clock }
        engine.restartDebounce = 0  // restarts at once; testCoalescedStartupRestarts covers the debounce
        return engine
    }

    private func post(_ engine: VoiceAudioEngine, _ name: Notification.Name, _ info: [AnyHashable: Any]? = nil) {
        engine.handle(try! XCTUnwrap(VoiceMicEvent.from(Notification(name: name, object: nil, userInfo: info))))
    }

    func testConfigurationChangeRestartsTheInput() {
        let h = MicHarness(), engine = micEngine(h)
        post(engine, .AVAudioEngineConfigurationChange)
        XCTAssertEqual(h.restarts, 1)
        XCTAssertNil(engine.problem)
    }

    func testInterruptionPausesAndResumesOnlyWhenTheSystemSaysSo() {
        let h = MicHarness(), engine = micEngine(h)
        post(engine, AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertTrue(engine.interrupted)
        post(engine, .AVAudioEngineConfigurationChange)
        XCTAssertEqual(h.restarts, 0, "no restart while interrupted")
        h.clock += 10; engine.tick()
        XCTAssertEqual(h.restarts, 0, "no stall restart while interrupted")
        post(engine, AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                                              AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        XCTAssertEqual(h.restarts, 1)
        XCTAssertFalse(engine.interrupted)

        post(engine, AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        post(engine, AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        XCTAssertEqual(h.restarts, 1, "ended without shouldResume: ask the user")
        XCTAssertEqual(engine.problem, VoiceAudioEngine.micStoppedLine)
        engine.restart()
        XCTAssertEqual(h.restarts, 2, "tap to restart")
        XCTAssertNil(engine.problem)
        XCTAssertEqual(h.problems.last!, nil)
    }

    func testRouteChangeRestartsTheInput() {
        let h = MicHarness(), engine = micEngine(h)
        post(engine, AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        post(engine, AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        XCTAssertEqual(h.restarts, 2)
    }

    func testRestartFailureIsShownAndReported() {
        let h = MicHarness(), engine = micEngine(h)
        h.fail = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)
        post(engine, .AVAudioEngineConfigurationChange)
        XCTAssertNotNil(engine.problem)
        XCTAssertTrue(engine.problem!.contains("Tap to restart"))
        h.fail = nil
        engine.restart()
        XCTAssertNil(engine.problem)
    }

    func testStalledMicIsRestartedAndARestartLoopAsksTheUser() {
        let h = MicHarness(), engine = micEngine(h)
        engine.tick()
        XCTAssertEqual(h.restarts, 0, "no buffers yet but not stalled: lastBuffer unset")
        engine.process(Self.silentBuffer())
        h.clock += 1; engine.tick()
        XCTAssertEqual(h.restarts, 0)
        h.clock += 3; engine.tick()
        XCTAssertEqual(h.restarts, 1, "no buffers for 3 s: restart")
        for _ in 0..<6 { h.clock += 1; post(engine, .AVAudioEngineConfigurationChange) }
        XCTAssertEqual(h.restarts, 5, "at most 5 automatic restarts in 10 s")
        XCTAssertEqual(engine.problem, VoiceAudioEngine.micStoppedLine)
    }

    private static func silentBuffer(level: Float = 0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        for i in 0..<1024 { buffer.floatChannelData![0][i] = i % 2 == 0 ? level : -level }
        return buffer
    }

    func testInt16PCMConversion() throws {
        let format = AVAudioFormatFactory.mono24k()
        let pcm = Data([0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80])
        let buffer = try XCTUnwrap(VoiceAudioEngine.buffer(fromInt16: pcm, format: format))
        XCTAssertEqual(buffer.frameLength, 3)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0)
        XCTAssertEqual(buffer.floatChannelData![0][1], 32767.0 / 32768, accuracy: 1e-6)
        XCTAssertEqual(buffer.floatChannelData![0][2], -1)
    }

    /// Streaming audio can arrive in frames that are not
    /// sample-aligned (185, 1369, 1369, … bytes). Decoding each frame on its own shifted
    /// every later frame by one byte, so the reply turned into static after the first frame.
    func testOddSizedReplyFramesDecodeToTheOriginalSignal() {
        let signal: [Int16] = (0..<2062).map { Int16(truncatingIfNeeded: ($0 * 7919) % 60001 - 30000) }
        var bytes = Data()
        for s in signal { withUnsafeBytes(of: s.littleEndian) { bytes.append(contentsOf: $0) } }
        XCTAssertEqual(bytes.count, 185 + 1369 + 1369 + 1201)
        let engine = VoiceAudioEngine()
        engine.beginSpeech(sampleRate: 24000, channels: 1)
        var offset = 0
        for size in [185, 1369, 1369, 1201] {
            engine.enqueue(pcm: bytes.subdata(in: offset..<offset + size))
            offset += size
        }
        let expected = signal.map { Float($0) / 32768 }
        XCTAssertEqual(engine.pendingReplySamples.count, expected.count, "every whole sample is played, none dropped")
        XCTAssertEqual(engine.pendingReplySamples, expected, "odd frames decode to exactly the sent signal")
    }

    func testCarriedByteIsDroppedWhenTheReplyStopsOrANewOneBegins() {
        let engine = VoiceAudioEngine()
        engine.beginSpeech(sampleRate: 24000, channels: 1)
        engine.enqueue(pcm: Data([0x01, 0x02, 0x03]))  // one sample + a dangling byte
        engine.stopSpeech(reason: "barge-in")
        engine.beginSpeech(sampleRate: 24000, channels: 1)
        engine.enqueue(pcm: Data([0x00, 0x40]))  // 0x4000 = 0.5
        XCTAssertEqual(engine.pendingReplySamples, [0.5], "a stopped reply's odd byte never leaks into the next")
        engine.enqueue(pcm: Data([0x00]))
        engine.beginSpeech(sampleRate: 24000, channels: 1)
        engine.enqueue(pcm: Data([0x00, 0xC0]))  // 0xC000 = -0.5
        XCTAssertEqual(engine.pendingReplySamples, [0.5, -0.5], "a new reply starts sample-aligned")
    }

    // MARK: Turn and playback ordering

    func testNextTurnsReplyWhileThePreviousStillPlaysGetsItsOwnStreamAfterIt() async throws {
        // 10:51:59: turn A's reply played; the re-queued steer ran as turn B, whose
        // 4-sentence reply went into A's finished stream and was never spoken.
        let backend = FakeVoiceBackend(), player = FakePlayer()
        player.holdDrain = true
        let session = VoiceSession(backend: backend, player: player)
        await session.start()
        session.speechEnded()
        await session.utterance(text: "I, I.")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("Sorry, I cut you off. Go ahead, I'm listening.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        let a = backend.speakSockets[0]
        await a.waitForSent(2)
        a.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        a.push(.data(Data(count: 4800)))
        await waitUntil { session.phase == .speaking }
        // Turn B while A's audio is still pending.
        backend.emit("message.start")
        let b1 = "I can hear you fine, but my replies aren't playing. ", b2 = "Let me check. That is odd. Try again."
        backend.emit("message.delta", ["text": .string(b1)])
        backend.emit("message.delta", ["text": .string(b2)])
        backend.emit("message.complete", ["status": .string("complete")])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(a.sentJSON, [.object(["text": .string("Sorry, I cut you off. Go ahead, I'm listening.")]), .object(["done": .bool(true)])],
                       "nothing of B goes into A's finished stream")
        XCTAssertEqual(backend.speakSockets.count, 1, "B waits: A is never cut")
        XCTAssertEqual(player.stops, 0)
        a.push(.string(#"{"type":"end"}"#))
        await waitUntil { player.drains.isEmpty == false }
        player.drain()
        await backend.speakOpened(count: 2)
        let b = backend.speakSockets[1]
        await b.waitForSent(3)
        XCTAssertEqual(b.sentJSON, [.object(["text": .string(b1)]), .object(["text": .string(b2)]), .object(["done": .bool(true)])],
                       "B's whole text in its own stream, then done")
    }

    func testStreamThatProducesNoAudioIsRetriedOnceThenGivenUp() async throws {
        // 10:51:48 / 10:54:39: streams open 3.8 s / 21 s that delivered only 52 bytes.
        let backend = FakeVoiceBackend()
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: FakePlayer(), now: { clock })
        var tts: [String] = []
        session.onTTS = { event, _ in tts.append(event) }
        await session.start()
        session.speechEnded()
        await session.utterance(text: "can you hear me")
        backend.emit("message.start")
        backend.emit("message.delta", [ "text": .string("Yes, I can hear you loud and clear.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        await backend.speakSockets[0].waitForSent(2)
        clock = clock.addingTimeInterval(VoiceSession.stallTimeout + 0.5)
        session.tick()
        await backend.speakOpened(count: 2)
        let retry = backend.speakSockets[1]
        await retry.waitForSent(2)
        XCTAssertEqual(retry.sentJSON, [.object(["text": .string("Yes, I can hear you loud and clear.")]), .object(["done": .bool(true)])])
        clock = clock.addingTimeInterval(VoiceSession.stallTimeout + 0.5)
        session.tick()
        await waitUntil { session.phase == .listening }
        XCTAssertEqual(session.phase, .listening, "a second stall gives up instead of sitting silent")
        XCTAssertEqual(backend.speakSockets.count, 2)
        XCTAssertTrue(tts.contains("stalled"))
        XCTAssertTrue(tts.contains("done-sent"))
    }

    func testStreamThatStopsMidReplyWithoutEndIsFinishedNotLeftSpeaking() async throws {
        // Sim r7 long reply: 4 of 7 sentences played, then no PCM and no `end`.
        let backend = FakeVoiceBackend()
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: FakePlayer(), now: { clock })
        await session.start()
        session.speechEnded()
        await session.utterance(text: "explain rainbows")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("One. Two. Three.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        let s = backend.speakSockets[0]
        await s.waitForSent(2)
        s.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        s.push(.data(Data(count: 4800)))
        await waitUntil { session.pcmBytesReceived == 4800 }
        clock = clock.addingTimeInterval(3)
        session.tick()
        XCTAssertEqual(session.phase, .speaking, "a short pause between sentences is not a stall")
        clock = clock.addingTimeInterval(VoiceSession.stallTimeout)
        session.tick()
        await waitUntil { session.phase == .listening }
        XCTAssertEqual(session.phase, .listening)
    }

    // MARK: Round 8 (box probe: 4.46 s between two sentences' first bytes)

    func testReceiveGapWhileQueuedAudioStillPlaysIsNotAStall() async throws {
        let backend = FakeVoiceBackend(), player = FakePlayer()
        var clock = Date(timeIntervalSince1970: 0)
        player.clock = { clock }
        let session = VoiceSession(backend: backend, player: player, now: { clock })
        var tts: [String] = []
        session.onTTS = { event, _ in tts.append(event) }
        await session.start()
        session.speechEnded()
        await session.utterance(text: "tell me about the weather")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("One. Two. Three. Four. Five. Six. Seven.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        let s = backend.speakSockets[0]
        await s.waitForSent(2)
        s.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        s.push(.data(Data(count: 48000 * 20)))  // 20 s of audio queued
        await waitUntil { session.pcmBytesReceived == 48000 * 20 }
        for _ in 0..<10 {  // 10 s with nothing received while it plays
            clock = clock.addingTimeInterval(1)
            session.tick()
        }
        XCTAssertFalse(tts.contains("stalled"), "queued audio still playing: waiting for the next sentence is not a stall")
        XCTAssertEqual(session.phase, .speaking)
        s.push(.data(Data(count: 48000 * 3)))
        s.push(.string(#"{"type":"end"}"#))
        await waitUntil { session.phase == .listening }
        XCTAssertEqual(player.pcm, 48000 * 23, "every later sentence reaches the player")
        XCTAssertFalse(tts.contains("stalled"))
        XCTAssertTrue(tts.contains("end"))
    }

    func testStallCountsOnlyOnceThePlayerRanDryAndSixSecondsPassed() async throws {
        let backend = FakeVoiceBackend(), player = FakePlayer()
        var clock = Date(timeIntervalSince1970: 0)
        player.clock = { clock }
        let session = VoiceSession(backend: backend, player: player, now: { clock })
        var tts: [String] = []
        session.onTTS = { event, _ in tts.append(event) }
        await session.start()
        session.speechEnded()
        await session.utterance(text: "explain rainbows")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("One. Two. Three.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        let s = backend.speakSockets[0]
        await s.waitForSent(2)
        s.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        s.push(.data(Data(count: 48000)))  // 1 s of audio, then nothing
        await waitUntil { session.pcmBytesReceived == 48000 }
        for _ in 0..<Int(VoiceSession.stallTimeout) {  // dry from t=1; one second short of the timeout
            clock = clock.addingTimeInterval(1)
            session.tick()
        }
        XCTAssertFalse(tts.contains("stalled"), "the timeout since the last PCM but one second less since the player ran dry")
        XCTAssertEqual(session.phase, .speaking)
        clock = clock.addingTimeInterval(1)
        session.tick()
        await waitUntil { session.phase == .listening }
        XCTAssertTrue(tts.contains("stalled"), "dry + the timeout of silence is a stall")
        XCTAssertEqual(session.phase, .listening)
    }

    /// Probe run 3: 4.3 s of audio, then a 6.9 s receive gap, more audio at 11.3 s.
    func testProbeRun3InterSentenceGapPlaysEverything() async throws {
        let backend = FakeVoiceBackend(), player = FakePlayer()
        var clock = Date(timeIntervalSince1970: 0)
        player.clock = { clock }
        let session = VoiceSession(backend: backend, player: player, now: { clock })
        var tts: [String] = []
        session.onTTS = { event, _ in tts.append(event) }
        await session.start()
        session.speechEnded()
        await session.utterance(text: "explain rainbows")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("One. Two. Three. Four. Five. Six. Seven.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        let s = backend.speakSockets[0]
        await s.waitForSent(2)
        s.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        s.push(.data(Data(count: 206_400)))  // 4.3 s
        await waitUntil { session.pcmBytesReceived == 206_400 }
        for _ in 0..<11 {  // ticks at t=1…11: dry from 4.3 s, nothing until 11.3 s
            clock = clock.addingTimeInterval(1)
            session.tick()
        }
        clock = clock.addingTimeInterval(0.3)
        XCTAssertFalse(tts.contains("stalled"), "a 6.9 s gap between sentences is a slow server, not a dead one")
        s.push(.data(Data(count: 48000 * 30)))
        s.push(.string(#"{"type":"end"}"#))
        await waitUntil { session.phase == .listening }
        XCTAssertEqual(player.pcm, 206_400 + 48000 * 30, "every sentence plays")
        XCTAssertFalse(tts.contains("stalled"))
    }

    /// Probe run 4: first audio 32 s after done. The reopen fires at the timeout; the
    /// original stream's late audio is ignored so nothing plays twice.
    func testProbeRun4SlowFirstAudioReopensOnceAndLateAudioDoesNotDoublePlay() async throws {
        let backend = FakeVoiceBackend(), player = FakePlayer()
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: player, now: { clock })
        var tts: [String] = []
        session.onTTS = { event, _ in tts.append(event) }
        await session.start()
        session.speechEnded()
        await session.utterance(text: "explain rainbows")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("One. Two.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        let original = backend.speakSockets[0]
        await original.waitForSent(2)
        session.tick()
        for _ in 0..<19 {
            clock = clock.addingTimeInterval(1)
            session.tick()
        }
        XCTAssertEqual(backend.speakSockets.count, 1, "no reopen before 20 s")
        XCTAssertTrue(session.speechSlow, "past 5 s without audio the screen says the voice is slow")
        XCTAssertFalse(tts.contains("stalled"))
        clock = clock.addingTimeInterval(1)
        session.tick()
        await backend.speakOpened(count: 2)
        let retry = backend.speakSockets[1]
        await retry.waitForSent(2)
        XCTAssertEqual(retry.sentJSON, [.object(["text": .string("One. Two.")]), .object(["done": .bool(true)])])
        XCTAssertTrue(tts.contains("stalled"))
        original.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        original.push(.data(Data(count: 9600)))
        original.push(.string(#"{"type":"end"}"#))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(player.pcm, 0, "the abandoned stream's late audio is not played")
        retry.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        retry.push(.data(Data(count: 4800)))
        retry.push(.string(#"{"type":"end"}"#))
        await waitUntil { session.phase == .listening }
        XCTAssertEqual(player.pcm, 4800, "the reply plays once, from the reopened stream")
        XCTAssertFalse(session.speechSlow, "cleared once audio starts")
    }

    func testSlowNoticeShowsAfterFiveSecondsWithoutAudioAndClearsOnFirstAudio() async throws {
        let backend = FakeVoiceBackend()
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: FakePlayer(), now: { clock })
        await session.start()
        session.speechEnded()
        await session.utterance(text: "hello")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("Hi there.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        let s = backend.speakSockets[0]
        await s.waitForSent(2)
        clock = clock.addingTimeInterval(4)
        session.tick()
        XCTAssertFalse(session.speechSlow)
        clock = clock.addingTimeInterval(1)
        session.tick()
        XCTAssertTrue(session.speechSlow)
        s.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        s.push(.data(Data(count: 4800)))
        await waitUntil { session.pcmBytesReceived == 4800 }
        XCTAssertFalse(session.speechSlow)
    }

    func testDeadStreamClosesAfterTwentySecondsDryAndListens() async throws {
        let backend = FakeVoiceBackend(), player = FakePlayer()
        var clock = Date(timeIntervalSince1970: 0)
        player.clock = { clock }
        let session = VoiceSession(backend: backend, player: player, now: { clock })
        var tts: [String] = []
        session.onTTS = { event, _ in tts.append(event) }
        await session.start()
        session.speechEnded()
        await session.utterance(text: "explain rainbows")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("One. Two. Three.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        let s = backend.speakSockets[0]
        await s.waitForSent(2)
        s.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        s.push(.data(Data(count: 48000 * 2)))  // 2 s, then the server goes silent without `end`
        await waitUntil { session.pcmBytesReceived == 48000 * 2 }
        for _ in 0..<21 {  // dry from t=2: 19 s of dry silence at t=21
            clock = clock.addingTimeInterval(1)
            session.tick()
        }
        XCTAssertFalse(tts.contains("stalled"))
        XCTAssertEqual(session.phase, .speaking)
        clock = clock.addingTimeInterval(1)
        session.tick()
        await waitUntil { session.phase == .listening }
        XCTAssertTrue(tts.contains("stalled"))
        XCTAssertEqual(session.phase, .listening)
    }

    func testTapToInterruptStopsTheReplyAndKeepsListening() async throws {
        let backend = FakeVoiceBackend(), player = FakePlayer()
        player.holdDrain = true
        let session = VoiceSession(backend: backend, player: player)
        await session.start()
        session.speechEnded()
        await session.utterance(text: "tell me a long story")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("Once upon a time.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        backend.speakSockets[0].push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        await waitUntil { session.phase == .speaking }
        session.tapToInterrupt()
        XCTAssertEqual(player.stops, 1)
        XCTAssertEqual(player.stopReasons.last, "barge-in")
        XCTAssertEqual(session.phase, .listening)
        XCTAssertFalse(session.isEnded)
    }

    func testVoiceScreenReportsItsChatForPushPresence() async throws {
        let backend = FakeVoiceBackend()
        let session = VoiceSession(backend: backend, player: FakePlayer())
        let server = URL(string: "https://dash.example")!
        await session.start()
        XCTAssertNil(session.pushViewer(server: server), "no chat yet")
        session.speechEnded()
        await session.utterance(text: "hello")
        // hermex-push reports under the agent session ID, which for a dashboard session
        // is the stored key session.create returned.
        XCTAssertEqual(session.pushViewer(server: server), PushPresence.Viewer(server: server, sessionID: "key-1"))
    }

    func testUtterancesAreTranscribedOneAtATimeInOrder() async throws {
        let backend = FakeVoiceBackend()
        let session = VoiceSession(backend: backend, player: FakePlayer())
        await session.start()
        backend.transcripts = ["first", "second", "third"]
        backend.transcribeDelay = .milliseconds(30)
        var tasks: [Task<Void, Never>] = []
        for byte in [UInt8(1), 2, 3] {
            session.speechEnded()
            tasks.append(Task { await session.utterance(audio: Data([byte]), mimeType: "audio/m4a", caption: nil) })
            await Task.yield()
        }
        for task in tasks { await task.value }
        XCTAssertEqual(backend.maxConcurrentTranscribes, 1, "never two transcribes at once")
        XCTAssertEqual(backend.calls.filter { $0.0 == "prompt.submit" || $0.0 == "session.steer" }.compactMap { $0.1["text"]?.text },
                       ["first", "second", "third"])
    }

    func testSpeechRightAfterABargeInJoinsItIntoOneUtterance() async throws {
        // 10:51:49-59: "I, I." and the rest became two turns.
        let backend = FakeVoiceBackend(), player = FakePlayer()
        player.holdDrain = true
        let session = VoiceSession(backend: backend, player: player)
        session.joinWindow = 0.3
        await session.start()
        session.speechEnded()
        await session.utterance(text: "hello")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("Yes, I can hear you.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        backend.speakSockets[0].push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        await waitUntil { session.phase == .speaking }
        session.speechStarted()  // barge-in
        backend.transcript = "I, I."
        session.speechEnded()
        let first = Task { await session.utterance(audio: Data([1]), mimeType: "audio/m4a", caption: nil) }
        try await Task.sleep(for: .milliseconds(50))
        session.speechStarted()  // the user keeps talking within the window
        backend.transcript = "couldn't hear a word you just said."
        session.speechEnded()
        await session.utterance(audio: Data([2]), mimeType: "audio/m4a", caption: nil)
        await first.value
        let texts = backend.calls.filter { $0.0 == "prompt.submit" }.compactMap { $0.1["text"]?.text }
        XCTAssertEqual(texts, ["hello", "I, I. couldn't hear a word you just said."])
    }

    private func playbackSeconds(_ seconds: [(Float, Float)]) -> [Float] {
        seconds.flatMap { phoneSecond(max: $0.0, mean: $0.1, peakFrames: 3) }
    }

    func testNormalSpeechOverAQuietAECReplyInterrupts() {
        var vad = VoiceEndpointer()
        _ = feed(&vad, Array(repeating: 0.00003, count: 50))
        // 10:54:46-10:55:41: reply playing, bleed 0.00001-0.0009.
        let bleed = (0..<(47 * 20)).map { i -> Float in [0.00001, 0.0003, 0.0009, 0.0001, 0.00005][i % 5] }
        XCTAssertEqual(feed(&vad, bleed, output: .playing), [], "bleed never trips")
        // 10:55:42-48: seven seconds of the user talking.
        let burst = playbackSeconds([(0.066, 0.012), (0.072, 0.034), (0.070, 0.045), (0.077, 0.023), (0.020, 0.002),
                                     (0.108, 0.021), (0.109, 0.018)])
        XCTAssertEqual(feed(&vad, burst, output: .playing).first, .speechStarted, "the user's normal-level speech interrupts")
    }

    func testLoudBargeInAt105329StillInterrupts() {
        var vad = VoiceEndpointer()
        _ = feed(&vad, Array(repeating: 0.00003, count: 50))
        _ = feed(&vad, Array(repeating: 0.0003, count: 60), output: .playing)
        XCTAssertEqual(feed(&vad, playbackSeconds([(0.116, 0.032)]), output: .playing).first, .speechStarted)
    }

    func testLoudRoundFiveBleedStillDoesNotInterrupt() {
        // Without AEC (round 5) bleed ran 0.01-0.04: the learned bleed raises the trigger.
        var vad = VoiceEndpointer()
        _ = feed(&vad, Array(repeating: 0.00003, count: 50))
        let bleed = (0..<280).map { i -> Float in [0.035, 0.04, 0.02, 0.03, 0.01][i % 5] }
        XCTAssertEqual(feed(&vad, bleed, output: .playing), [])
    }

    func testReplyAudioIsCoalescedAndPrebuffered() {
        let engine = VoiceAudioEngine()
        engine.beginSpeech(sampleRate: 24000, channels: 1)
        let frame = Data(count: 1369)  // ~28 ms, odd-sized like OpenAI's frames
        for _ in 0..<6 { engine.enqueue(pcm: frame) }  // ~171 ms: still prebuffering
        XCTAssertEqual(engine.pendingBufferFrames, [], "nothing plays before ~200 ms is queued")
        for _ in 0..<2 { engine.enqueue(pcm: frame) }
        XCTAssertEqual(engine.pendingBufferFrames.count, 1, "the prebuffer goes out as one buffer")
        for _ in 0..<40 { engine.enqueue(pcm: frame) }
        XCTAssertTrue(engine.pendingBufferFrames.allSatisfy { $0 >= 3600 }, "buffers are >= 150 ms, not 28 ms frames")
        var drained = false
        engine.finishSpeech { drained = true }
        XCTAssertEqual(engine.pendingReplySamples.count, 48 * 1369 / 2, "every sample is scheduled at the end")
        XCTAssertFalse(drained)
    }

    // MARK: Session loop against fakes

    func testFullLoopBargeInAndStop() async throws {
        let backend = FakeVoiceBackend()
        let player = FakePlayer()
        let session = VoiceSession(backend: backend, player: player)
        var created: String?
        session.onSessionCreated = { created = $0 }
        await session.start()
        XCTAssertEqual(session.phase, .listening)

        session.speechEnded()
        await session.utterance(audio: Data([9]), mimeType: "audio/m4a", caption: "")
        XCTAssertEqual(backend.transcribed, ["key-1"])
        XCTAssertEqual(created, "key-1")
        XCTAssertEqual(backend.calls.map(\.0), ["session.create", "prompt.submit"])
        XCTAssertEqual(backend.calls[1].1, ["session_id": .string("rt-1"), "text": .string("what time is it"), "interrupted": .bool(false)])
        XCTAssertEqual(session.phase, .working(nil))

        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("It is Hermex ")])
        await backend.speakOpened()
        backend.emit("message.delta", ["text": .string("time.")])
        backend.emit("message.complete", ["text": .string("It is Hermex time."), "status": .string("complete")])
        let stream = try XCTUnwrap(backend.speakSockets.first)
        await stream.waitForSent(3)
        XCTAssertEqual(stream.sentJSON, [.object(["text": .string("It is Her-mex ")]), .object(["text": .string("time.")]), .object(["done": .bool(true)])])
        stream.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        stream.push(.data(Data(count: 4800)))
        await waitUntil { session.pcmBytesReceived == 4800 }
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertEqual(player.begun, [24000])

        // Talking over the reply pauses it; words stop it and mark the next submit.
        session.speechStarted()
        XCTAssertEqual(player.stops, 0)
        backend.transcript = "and tomorrow"
        session.speechEnded()
        await session.utterance(audio: Data([9]), mimeType: "audio/m4a", caption: "")
        XCTAssertEqual(player.stops, 1)
        await stream.waitForSent(4)
        XCTAssertEqual(stream.sentJSON.last, .object(["stop": .bool(true)]))
        XCTAssertEqual(backend.calls.last?.1["interrupted"], .bool(true))
        XCTAssertTrue(session.lastSubmitInterrupted)

        // While running, words steer; "stop" interrupts and stays in voice.
        backend.transcript = "use UTC"
        session.speechEnded()
        await session.utterance(audio: Data([9]), mimeType: "audio/m4a", caption: "")
        XCTAssertEqual(backend.calls.last?.0, "session.steer")
        backend.transcript = "stop"
        session.speechEnded()
        await session.utterance(audio: Data([9]), mimeType: "audio/m4a", caption: "")
        XCTAssertEqual(backend.calls.last?.0, "session.interrupt")
        XCTAssertFalse(session.isEnded)

        backend.transcript = "Goodbye."
        session.speechEnded()
        await session.utterance(audio: Data([9]), mimeType: "audio/m4a", caption: "")
        XCTAssertTrue(session.isEnded)
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.close" })
        XCTAssertTrue(backend.closed)
    }

    func testDiscardedSpeechReturnsToListening() async {
        let session = VoiceSession(backend: FakeVoiceBackend(), player: FakePlayer())
        await session.start()
        session.speechStarted()
        XCTAssertEqual(session.phase, .hearing)
        session.speechDiscarded()
        XCTAssertEqual(session.phase, .listening)
    }

    func testEmptyTranscriptKeepsListeningAndOnDeviceSkipsUpload() async {
        let backend = FakeVoiceBackend()
        backend.transcript = ""
        let session = VoiceSession(backend: backend, player: FakePlayer())
        await session.start()
        session.speechEnded()
        await session.utterance(audio: Data([1]), mimeType: "audio/m4a", caption: "")
        XCTAssertEqual(session.phase, .listening)
        XCTAssertEqual(backend.calls.map(\.0), ["session.create"])
        session.settings.useServerTranscription = false
        session.speechEnded()
        await session.utterance(audio: Data([1]), mimeType: "audio/m4a", caption: "hello")
        XCTAssertEqual(backend.transcribed.count, 1)
        XCTAssertEqual(backend.calls.last?.1["text"], .string("hello"))
    }

    func testOnDeviceFailureFallsBackToTheServerForThatUtterance() async {
        let backend = FakeVoiceBackend()
        backend.transcript = "what time is it"
        var settings = VoiceSession.Settings()
        settings.useServerTranscription = false
        let session = VoiceSession(backend: backend, player: FakePlayer(), settings: settings)
        await session.start()
        session.speechEnded()
        await session.utterance(audio: Data([1]), mimeType: "audio/m4a", caption: nil)
        XCTAssertEqual(backend.transcribed.count, 1)
        XCTAssertEqual(session.usedServerFallback, 1)
        XCTAssertEqual(backend.calls.last?.1["text"], .string("what time is it"))
    }

    func testApprovalByVoiceIsOnceOnlyAndCredentialsNeedTheApp() async throws {
        let backend = FakeVoiceBackend()
        let session = VoiceSession(backend: backend, player: FakePlayer())
        var needsApp: [String] = []
        session.onNeedsApp = { needsApp.append($0) }
        await session.start()
        session.speechEnded()
        await session.utterance(text: "clean the build dir")
        backend.onEvent?(.object(["jsonrpc": .string("2.0"), "id": .string("srv-1"), "method": .string("approval"), "params": .object([
            "session_id": .string("rt-1"), "request_id": .string("ap-1"), "command": .string("rm -rf build"),
            "choices": .array([.string("once"), .string("session"), .string("always"), .string("deny")])])]))
        XCTAssertEqual(session.pendingApproval?.requestID, "ap-1")
        session.speechEnded()
        await session.utterance(text: "maybe later")
        XCTAssertNotNil(session.pendingApproval, "unclear answers don't resolve")
        session.speechEnded()
        await session.utterance(text: "Yes.")
        XCTAssertNil(session.pendingApproval)
        XCTAssertEqual(backend.calls.last?.0, "approval.respond")
        XCTAssertEqual(backend.calls.last?.1["choice"], .string("once"))

        backend.onEvent?(.object(["jsonrpc": .string("2.0"), "id": .string("srv-2"), "method": .string("approval"), "params": .object([
            "session_id": .string("rt-1"), "request_id": .string("ap-2"), "choices": .array([.string("once"), .string("deny")])])]))
        session.speechEnded()
        await session.utterance(text: "no")
        XCTAssertEqual(backend.calls.last?.1["choice"], .string("deny"))

        backend.onEvent?(.object(["jsonrpc": .string("2.0"), "id": .string("srv-3"), "method": .string("sudo"), "params": .object([
            "session_id": .string("rt-1")])]))
        XCTAssertEqual(needsApp.count, 1)
        XCTAssertFalse(backend.calls.contains { $0.0 == "request.answer" })
    }

    func testProgressSpokenFromToolStart() async throws {
        let backend = FakeVoiceBackend()
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: FakePlayer(), now: { clock })
        await session.start()
        session.speechEnded()
        await session.utterance(text: "check the disk")
        backend.emit("tool.start", ["name": .string("terminal")])
        XCTAssertEqual(backend.speakSockets.count, 0, "nothing before 6 s")
        clock = clock.addingTimeInterval(7)
        session.tick()
        await backend.speakOpened()
        let stream = try XCTUnwrap(backend.speakSockets.first)
        await stream.waitForSent(2)
        XCTAssertEqual(stream.sentJSON, [.object(["text": .string("Running a command.")]), .object(["done": .bool(true)])])
    }

    // MARK: Round 2: cutting in while a turn runs

    /// Our own submit, one reply delta, and the reply socket playing.
    private func runningReply(_ backend: FakeVoiceBackend, _ session: VoiceSession) async throws -> VoiceScriptedSocket {
        await session.start()
        session.speechEnded()
        await session.utterance(text: "list big files")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("The biggest ")])
        await backend.speakOpened()
        let stream = try XCTUnwrap(backend.speakSockets.first)
        stream.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        stream.push(.data(Data(count: 480)))
        await waitUntil { session.phase == .speaking }
        XCTAssertEqual(session.phase, .speaking)
        return stream
    }

    // MARK: Long utterances

    func testFortyFiveSecondAnswerWithPausesIsOneUtterance() {
        // 15:29:04 / 15:30:13 / 15:31:18: answers were cut at 29.9-30.7 s mid-sentence.
        var vad = VoiceEndpointer()
        _ = run(&vad, level: 0.0005, seconds: 1)
        var events: [VoiceEndpointer.Event] = []
        for i in 0..<9 {  // 9 x (4.5 s talking + 0.5 s normal pause) = 45 s
            events += run(&vad, level: 0.05, seconds: 4.5)
            events += run(&vad, level: 0.0005, seconds: i == 8 ? 2 : 0.5)
        }
        XCTAssertEqual(events, [.speechStarted, .utteranceEnded], "one utterance, ended by the silence after it")
    }

    func testMaximumSpeechIsARunawayGuardOnly() {
        XCTAssertEqual(VoiceEndpointer().maximumSpeech, 180)
        var vad = VoiceEndpointer()
        _ = run(&vad, level: 0.0005, seconds: 1)
        // Talking with short breaths (the floor drops back in each pause, as in real speech).
        func talk(_ seconds: Int) -> [VoiceEndpointer.Event] {
            (0..<seconds / 5).flatMap { _ in run(&vad, level: 0.05, seconds: 4.7) + run(&vad, level: 0.0005, seconds: 0.3) }
        }
        XCTAssertEqual(talk(170), [.speechStarted], "still one utterance at 170 s")
        XCTAssertEqual(talk(15).first, .utteranceEnded, "cut at 180 s")
    }

    func testNoiseOverTheReplyPausesItAndThenResumes() async throws {
        // 15:19:06 and 15:19:39: barge-in fired, the speech transcribed to "", the rest was lost.
        let backend = FakeVoiceBackend(), player = FakePlayer()
        let session = VoiceSession(backend: backend, player: player)
        let stream = try await runningReply(backend, session)
        session.speechStarted()
        XCTAssertEqual(player.pauses, 1, "onset pauses the reply")
        XCTAssertEqual(player.stops, 0, "nothing is dropped yet")
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.interrupt" })
        backend.transcript = ""
        session.speechEnded()
        await session.utterance(audio: Data([1]), mimeType: "audio/m4a", caption: nil)
        XCTAssertEqual(player.resumeReasons, ["resumed"], "empty transcript: the reply plays on from where it paused")
        XCTAssertEqual(player.stops, 0)
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.interrupt" })
        XCTAssertFalse(stream.sentJSON.contains(.object(["stop": .bool(true)])), "the speak-stream is kept")
        // A too-short bump resumes too.
        session.speechStarted()
        session.speechDiscarded()
        XCTAssertEqual(player.resumeReasons, ["resumed", "resumed"])
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertEqual(player.stops, 0)
    }

    func testRealWordsOverTheReplyStopAndInterrupt() async throws {
        // 15:24:05: a real interruption (63 chars) still stops the reply and becomes the next turn.
        let backend = FakeVoiceBackend(), player = FakePlayer()
        let session = VoiceSession(backend: backend, player: player)
        _ = try await runningReply(backend, session)
        session.speechStarted()
        XCTAssertEqual(player.stops, 0)
        backend.transcript = "no wait, just tell me the biggest one"
        session.speechEnded()
        await session.utterance(audio: Data([1]), mimeType: "audio/m4a", caption: nil)
        XCTAssertEqual(player.stopReasons, ["barge-in"])
        XCTAssertTrue(backend.calls.contains { $0.0 == "session.interrupt" })
        backend.emit("message.complete", ["status": .string("interrupted")])
        await waitUntil { self.submits(backend).count == 2 }
        XCTAssertEqual(submits(backend).last?["text"], .string("no wait, just tell me the biggest one"))
        XCTAssertEqual(submits(backend).last?["interrupted"], .bool(true))
        XCTAssertFalse(player.paused, "the player is not left paused")
    }

    func testTapToInterruptStillStopsAtOnce() async throws {
        let backend = FakeVoiceBackend(), player = FakePlayer()
        let session = VoiceSession(backend: backend, player: player)
        _ = try await runningReply(backend, session)
        session.tapToInterrupt()
        XCTAssertEqual(player.stopReasons, ["barge-in"])
        await waitUntil { backend.calls.contains { $0.0 == "session.interrupt" } }
        XCTAssertTrue(backend.calls.contains { $0.0 == "session.interrupt" })
        // Tapping while speech is on hold commits it at once too.
        let b2 = FakeVoiceBackend(), p2 = FakePlayer()
        let s2 = VoiceSession(backend: b2, player: p2)
        _ = try await runningReply(b2, s2)
        s2.speechStarted()
        s2.tapToInterrupt()
        XCTAssertEqual(p2.stopReasons, ["barge-in"])
    }

    func testReplyReadyWhileStillTalkingStartsOnlyAfterSpeechEnds() async throws {
        // 15:29:04-15:29:18: the reply began at 15:29:08 while the user was mid-speech.
        let backend = FakeVoiceBackend(), player = FakePlayer()
        let session = VoiceSession(backend: backend, player: player)
        await session.start()
        session.speechEnded()
        await session.utterance(text: "tell me about the build")
        session.speechStarted()  // the user keeps talking
        XCTAssertEqual(session.phase, .working(nil))
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("The build passed.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        backend.speakSockets[0].push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        backend.speakSockets[0].push(.data(Data(count: 4800)))
        await waitUntil { session.pcmBytesReceived == 4800 }
        XCTAssertTrue(player.paused, "held: the player never starts while the user talks")
        XCTAssertTrue(session.replyHeld)
        XCTAssertNotEqual(session.phase, .speaking)
        // The user's speech turns out to be noise: the held reply starts now.
        session.speechDiscarded()
        XCTAssertFalse(player.paused)
        XCTAssertEqual(player.stops, 0)
        XCTAssertEqual(session.phase, .speaking)
    }

    func testSpeechStartingBeforeThePreviousUtteranceIsDeliveredKeepsItsHold() async throws {
        let backend = FakeVoiceBackend(), player = FakePlayer()
        let session = VoiceSession(backend: backend, player: player)
        await session.start()
        session.speechStarted()
        session.speechEnded()
        session.speechStarted()  // new speech before the first utterance is delivered
        await session.utterance(audio: Data([1]), mimeType: "audio/m4a", caption: nil)
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("Paris.")])
        await backend.speakOpened()
        backend.speakSockets[0].push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        await waitUntil { session.replyHeld }
        XCTAssertTrue(session.replyHeld, "the answer waits while the user is still talking")
        XCTAssertTrue(player.paused)
        XCTAssertNotEqual(session.phase, .speaking)
    }

    func testHeldReplyIsDroppedWhenTheSpeechBecomesATurn() async throws {
        let backend = FakeVoiceBackend(), player = FakePlayer()
        let session = VoiceSession(backend: backend, player: player)
        await session.start()
        session.speechEnded()
        await session.utterance(text: "tell me about the build")
        session.speechStarted()
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("The build passed.")])
        await backend.speakOpened()
        backend.speakSockets[0].push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        await waitUntil { session.replyHeld }
        backend.transcript = "and also check the tests"
        session.speechEnded()
        await session.utterance(audio: Data([1]), mimeType: "audio/m4a", caption: nil)
        XCTAssertEqual(player.stopReasons, ["barge-in"], "dropped the same way a barge-in drops it")
        XCTAssertFalse(player.paused)
        XCTAssertTrue(backend.calls.contains { $0.0 == "session.interrupt" })
    }

    func testLineQueuedWhilePausedStaysBehindTheHeldReply() async throws {
        // While paused, a turn's next line still queues behind it.
        let backend = FakeVoiceBackend(), player = FakePlayer()
        player.holdDrain = true
        let session = VoiceSession(backend: backend, player: player)
        await session.start()
        session.speechEnded()
        await session.utterance(text: "first")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("One.")])
        backend.emit("message.complete", ["status": .string("complete")])
        await backend.speakOpened()
        backend.speakSockets[0].push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        await waitUntil { session.phase == .speaking }
        session.speechStarted()
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("Two.")])
        XCTAssertTrue(session.hasQueuedReply, "the next turn's reply queues behind the paused one")
        XCTAssertEqual(backend.speakSockets.count, 1)
        session.speechDiscarded()
        XCTAssertEqual(player.resumeReasons, ["resumed"])
        XCTAssertTrue(session.hasQueuedReply)
    }

    func testCutInOverRunningReplyInterruptsThenSubmitsInterrupted() async throws {
        let backend = FakeVoiceBackend()
        let player = FakePlayer()
        let session = VoiceSession(backend: backend, player: player)
        _ = try await runningReply(backend, session)
        session.speechStarted()
        session.speechEnded()
        await session.utterance(text: "just the top one")
        XCTAssertEqual(player.stops, 1)
        await waitUntil { backend.calls.contains { $0.0 == "session.interrupt" } }
        XCTAssertTrue(backend.calls.contains { $0.0 == "session.interrupt" }, "the rejected turn is interrupted")
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.steer" }, "words over a rejected reply are not a steer")
        XCTAssertEqual(backend.calls.filter { $0.0 == "prompt.submit" }.count, 1, "waits for the interrupted turn to finish")
        backend.emit("message.delta", ["text": .string("files are")])
        XCTAssertEqual(backend.speakSockets.count, 1, "the rejected turn's leftovers are not spoken")
        backend.emit("message.complete", ["text": .string("The biggest files are"), "status": .string("interrupted")])
        await waitUntil { backend.calls.filter { $0.0 == "prompt.submit" }.count == 2 }
        XCTAssertEqual(backend.calls.last?.0, "prompt.submit")
        XCTAssertEqual(backend.calls.last?.1, ["session_id": .string("rt-1"), "text": .string("just the top one"), "interrupted": .bool(true)])
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("It is disk.iso.")])
        await waitUntil { backend.speakSockets.count == 2 }
        XCTAssertEqual(backend.speakSockets.count, 2, "the new answer is spoken")
        XCTAssertEqual(session.replyText, "It is disk.iso.")
    }

    func testCutInOverProgressLineSteersAndAnswerIsSpoken() async throws {
        let backend = FakeVoiceBackend()
        let player = FakePlayer()
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: player, now: { clock })
        await session.start()
        session.speechEnded()
        await session.utterance(text: "check the disk")
        backend.emit("message.start")
        backend.emit("tool.start", ["name": .string("terminal")])
        clock = clock.addingTimeInterval(7)
        session.tick()
        await backend.speakOpened()
        let line = try XCTUnwrap(backend.speakSockets.first)
        line.push(.string(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        await waitUntil { session.phase == .speaking }
        let stopsBefore = player.stops
        session.speechStarted()
        session.speechEnded()
        await session.utterance(text: "only the home folder")
        XCTAssertEqual(player.stops, stopsBefore + 1, "our progress line stops")
        XCTAssertEqual(backend.calls.last?.0, "session.steer")
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.interrupt" })
        backend.emit("message.delta", ["text": .string("Home uses 40 GB.")])
        await waitUntil { backend.speakSockets.count == 2 }
        XCTAssertEqual(backend.speakSockets.count, 2, "the answer is spoken")
        XCTAssertEqual(session.replyText, "Home uses 40 GB.")
        backend.emit("message.complete", ["text": .string("Home uses 40 GB."), "status": .string("complete")])
        session.speechEnded()
        await session.utterance(text: "and the downloads folder")
        XCTAssertEqual(backend.calls.last?.1["interrupted"], .bool(false), "a cut-in on our own line never sets interrupted")
    }

    func testFollowUpTurnFromRequeuedSteerIsSpoken() async throws {
        let backend = FakeVoiceBackend()
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: FakePlayer(), now: { clock })
        await session.start()
        session.speechEnded()
        await session.utterance(text: "first")
        backend.emit("message.complete", ["status": .string("complete")])
        XCTAssertEqual(session.phase, .listening)
        // The server runs a leftover steer as its own turn.
        backend.emit("message.start")
        backend.emit("tool.start", ["name": .string("terminal")])
        XCTAssertEqual(session.phase, .working("Running a command."))
        clock = clock.addingTimeInterval(7)
        session.tick()
        await backend.speakOpened()
        let line = try XCTUnwrap(backend.speakSockets.first)
        await line.waitForSent(1)
        XCTAssertEqual(line.sentJSON.first, .object(["text": .string("Running a command.")]))
        backend.emit("message.delta", ["text": .string("Done.")])
        await waitUntil { backend.speakSockets.count == 2 }
        XCTAssertEqual(session.replyText, "Done.")
        let reply = try XCTUnwrap(backend.speakSockets.last)
        await reply.waitForSent(1)
        XCTAssertEqual(reply.sentJSON.first, .object(["text": .string("Done.")]))
    }

    func testVoiceCreateOmitsProfile() async {
        let backend = FakeVoiceBackend()
        let session = VoiceSession(backend: backend, player: FakePlayer())
        await session.start()
        session.speechEnded()
        await session.utterance(text: "hello")
        XCTAssertEqual(backend.calls.first?.0, "session.create")
        XCTAssertEqual(backend.calls.first?.1, ["hidden": .bool(false)])
    }

    func testSpokenApproveWithoutOnceStaysPendingAndNeedsTheApp() async throws {
        let backend = FakeVoiceBackend()
        let session = VoiceSession(backend: backend, player: FakePlayer())
        var needsApp: [String] = []
        session.onNeedsApp = { needsApp.append($0) }
        await session.start()
        session.speechEnded()
        await session.utterance(text: "deploy it")
        backend.onEvent?(.object(["jsonrpc": .string("2.0"), "id": .string("srv-9"), "method": .string("approval"), "params": .object([
            "session_id": .string("rt-1"), "request_id": .string("ap-9"), "command": .string("deploy"),
            "choices": .array([.string("session"), .string("deny")])])]))
        session.speechEnded()
        await session.utterance(text: "approve")
        XCTAssertEqual(session.pendingApproval?.requestID, "ap-9", "left pending for the app")
        XCTAssertFalse(backend.calls.contains { $0.0 == "approval.respond" }, "never answered deny for the user")
        XCTAssertEqual(needsApp.count, 1)
        await waitUntil { backend.speakSockets.last?.sentJSON.first == .object(["text": .string("That one needs the app.")]) }
        XCTAssertEqual(backend.speakSockets.last?.sentJSON.first, .object(["text": .string("That one needs the app.")]))
    }

    func testContinueByVoiceResumesColdAndLeaves() async throws {
        let backend = FakeVoiceBackend()
        let session = VoiceSession(backend: backend, player: FakePlayer(), resumeSessionKey: "20260930_001713_997266")
        await session.start()
        XCTAssertEqual(backend.calls.first?.0, "session.resume")
        XCTAssertEqual(backend.calls.first?.1, ["session_id": .string("20260930_001713_997266"),
                                                "close_on_disconnect": .bool(false), "omit_messages": .bool(true)])
        session.speechEnded()
        await session.utterance(text: "and what about tomorrow")
        XCTAssertEqual(backend.calls.last?.1["session_id"], .string("rt-resumed"))
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.create" })
        await session.end()
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.close" })
        XCTAssertTrue(backend.closed)
    }

    func testEndDuringARunningTurnNeitherClosesNorInterrupts() async throws {
        let backend = FakeVoiceBackend()
        let session = VoiceSession(backend: backend, player: FakePlayer())
        await session.start()
        session.speechEnded()
        await session.utterance(text: "run the long job")
        let sent = backend.calls.count
        await session.end()
        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(backend.calls.count, sent, "End sends no gateway RPC at all")
        XCTAssertTrue(backend.closed)
    }

    // MARK: Continue by voice on any chat (r12)

    private func chat(_ key: String = "20260930_120000_abc123", profile: String? = "default", sessionSource: String? = nil,
                      rawSource: String? = nil, readOnly: Bool? = nil, isStreaming: Bool? = nil,
                      pending: Bool? = nil) -> SessionSummary {
        SessionSummary(sessionId: key, title: "Typed chat", profile: profile, isStreaming: isStreaming,
                       hasPendingUserMessage: pending, rawSource: rawSource, sessionSource: sessionSource, readOnly: readOnly)
    }

    func testContinueByVoiceIsOfferedOnAnyTypedChatNotOnlyVoiceStartedOnes() {
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(), isViewingCachedData: false), .available(profile: "default"))
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(sessionSource: "webui"), isViewingCachedData: false),
                       .available(profile: "default"))
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(sessionSource: "cli", rawSource: "cli"), isViewingCachedData: false),
                       .available(profile: "default"), "CLI/TUI chats are allowed")
    }

    func testContinueByVoiceIsHiddenForMessagingPlatformChats() {
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(sessionSource: "messaging"), isViewingCachedData: false), .hidden)
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(rawSource: "telegram"), isViewingCachedData: false), .hidden)
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(rawSource: "slack"), isViewingCachedData: false), .hidden)
    }

    func testContinueByVoiceIsHiddenForReadOnlyAndCachedChats() {
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(readOnly: true), isViewingCachedData: false), .hidden)
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(rawSource: "subagent"), isViewingCachedData: false), .hidden)
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(), isViewingCachedData: true), .hidden)
    }

    func testContinueByVoiceIsDisabledWhileTheChatIsBusy() {
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(isStreaming: true), isViewingCachedData: false), .busy)
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(pending: true), isViewingCachedData: false), .busy)
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(), isViewingCachedData: false, isBusy: true), .busy,
                       "ChatView's live stream wins over the row's flags")
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(isStreaming: true), isViewingCachedData: false, isBusy: false),
                       .available(profile: "default"))
    }

    func testContinueByVoicePassesAnotherProfileAndHidesAnUnknownOne() {
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(profile: "work"), isViewingCachedData: false), .available(profile: "work"))
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(profile: nil), isViewingCachedData: false), .hidden)
        XCTAssertEqual(VoicePreferences.canContinueByVoice(chat(profile: "  "), isViewingCachedData: false), .hidden)
    }

    func testResumeOfAnotherProfilesChatSendsItsProfile() async throws {
        let backend = FakeVoiceBackend()
        let session = VoiceSession(backend: backend, player: FakePlayer(), resumeSessionKey: "k1", resumeProfile: "work")
        await session.start()
        XCTAssertEqual(backend.calls.first?.1, ["session_id": .string("k1"), "close_on_disconnect": .bool(false),
                                                "omit_messages": .bool(true), "profile": .string("work")])
        session.speechEnded()
        await session.utterance(text: "hello")
        XCTAssertFalse(backend.calls.contains { $0.0 == "session.create" })
        XCTAssertNil(backend.calls.first { $0.0 == "prompt.submit" }?.1["profile"], "only the resume names the profile")
    }

    func testResumeOfABusyChatSaysSoInsteadOfAGenericFailure() async {
        let backend = FakeVoiceBackend()
        backend.resumeFailure = .rejected(4009)
        let session = VoiceSession(backend: backend, player: FakePlayer(), resumeSessionKey: "k1")
        await session.start()
        XCTAssertEqual(session.phase, .ended("That chat is busy right now."))
        XCTAssertFalse(backend.calls.contains { $0.0 == "prompt.submit" })
    }

    func testVoiceResumeLeavesTheRuntimeToTheServerOnDisconnect() throws {
        XCTAssertEqual(try HermesCall.voiceSessionResume(sessionID: "k1", profile: nil).params(),
                       ["session_id": .string("k1"), "close_on_disconnect": .bool(false), "omit_messages": .bool(true)])
    }

    // MARK: Round 3: the rejected turn never completes

    private func submits(_ backend: FakeVoiceBackend) -> [[String: BotJSON]] {
        backend.calls.filter { $0.0 == "prompt.submit" }.map(\.1)
    }

    func testRejectedTurnWithoutCompleteSubmitsQueuedWordsAfterFiveSeconds() async throws {
        let backend = FakeVoiceBackend()
        backend.submitStatus = "queued"
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: FakePlayer(), now: { clock })
        _ = try await runningReply(backend, session)
        session.speechStarted()
        session.speechEnded()
        await session.utterance(text: "just the top one")
        XCTAssertEqual(submits(backend).count, 1)
        clock = clock.addingTimeInterval(4.9)
        session.tick()
        XCTAssertEqual(submits(backend).count, 1, "still waiting inside 5 s")
        clock = clock.addingTimeInterval(0.2)
        session.tick()
        await waitUntil { self.submits(backend).count == 2 }
        XCTAssertEqual(submits(backend).last, ["session_id": .string("rt-1"), "text": .string("just the top one"),
                                               "interrupted": .bool(true)])
        await waitUntil { session.phase != .sending }
        XCTAssertNotEqual(session.phase, .sending)
        // Words after the timeout are not queued behind the dead turn any more.
        session.speechEnded()
        await session.utterance(text: "and the second")
        XCTAssertTrue(backend.calls.contains { ($0.0 == "session.steer" || $0.0 == "prompt.submit") && $0.1["text"] == .string("and the second") },
                      "a later utterance is sent, not swallowed by the reject queue")
    }

    func testLateCompleteOfRejectedTurnDoesNotEndOrDropTheNewTurn() async throws {
        let backend = FakeVoiceBackend()
        backend.submitStatus = "queued"
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: FakePlayer(), now: { clock })
        _ = try await runningReply(backend, session)
        session.speechStarted()
        session.speechEnded()
        await session.utterance(text: "just the top one")
        clock = clock.addingTimeInterval(5.1)
        session.tick()
        await waitUntil { self.submits(backend).count == 2 }
        // Server queued our words: the rejected turn's late leftovers and complete come first.
        backend.emit("message.delta", ["text": .string("files are")])
        backend.emit("message.complete", ["text": .string("The biggest files are"), "status": .string("interrupted")])
        XCTAssertEqual(backend.speakSockets.count, 1, "the late complete of the rejected turn is not spoken")
        XCTAssertEqual(session.replyText, "", "nor taken as the new answer")
        XCTAssertNotEqual(session.phase, .listening, "and it does not end the new turn")
        backend.emit("message.start")
        backend.emit("message.delta", ["text": .string("It is disk.iso.")])
        await waitUntil { backend.speakSockets.count == 2 }
        XCTAssertEqual(session.replyText, "It is disk.iso.")
        backend.emit("message.complete", ["text": .string("It is disk.iso."), "status": .string("complete")])
        XCTAssertEqual(session.replyText, "It is disk.iso.")
    }

    func testRedirectedSubmitAfterTimeoutSpeaksTheSameTurnsAnswer() async throws {
        let backend = FakeVoiceBackend()
        backend.submitStatus = "redirected"
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: FakePlayer(), now: { clock })
        _ = try await runningReply(backend, session)
        session.speechStarted()
        session.speechEnded()
        await session.utterance(text: "just the top one")
        clock = clock.addingTimeInterval(5.1)
        session.tick()
        await waitUntil { self.submits(backend).count == 2 }
        // The live turn now carries our words: its output is the answer.
        backend.emit("message.delta", ["text": .string("Only disk.iso.")])
        await waitUntil { backend.speakSockets.count == 2 }
        XCTAssertEqual(session.replyText, "Only disk.iso.")
    }

    func testRejectedTurnTimeoutWithSubmitFailureSaysSoAndListens() async throws {
        let backend = FakeVoiceBackend()
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: FakePlayer(), now: { clock })
        _ = try await runningReply(backend, session)
        session.speechStarted()
        session.speechEnded()
        await session.utterance(text: "just the top one")
        backend.failSubmit = true
        clock = clock.addingTimeInterval(5.1)
        session.tick()
        await backend.speakOpened(count: 2)
        XCTAssertEqual(backend.speakSockets.last?.sentJSON.first,
                       .object(["text": .string("Sorry, I could not reach Hermes for that request.")]), "never silently")
    }

    func testStopDuringRunningTurnRecoversWithoutComplete() async throws {
        let backend = FakeVoiceBackend()
        var clock = Date(timeIntervalSince1970: 0)
        let session = VoiceSession(backend: backend, player: FakePlayer(), now: { clock })
        _ = try await runningReply(backend, session)
        session.speechEnded()
        await session.utterance(text: "stop")
        XCTAssertTrue(backend.calls.contains { $0.0 == "session.interrupt" })
        clock = clock.addingTimeInterval(5.1)
        session.tick()
        XCTAssertEqual(session.phase, .listening)
        session.speechEnded()
        await session.utterance(text: "what time is it")
        XCTAssertEqual(submits(backend).count, 2, "words after a stuck stop are sent, not queued forever")
        // The stopped turn's late complete neither speaks nor ends the new turn.
        backend.emit("message.complete", ["text": .string("The biggest files are"), "status": .string("interrupted")])
        XCTAssertEqual(backend.speakSockets.count, 1)
        XCTAssertNotEqual(session.phase, .listening)
    }

    // MARK: Helpers

    private func assertRefused(_ client: BotClient, _ call: HermesCall, line: UInt = #line) async {
        do { _ = try await client.call(call); XCTFail("dispatched \(call)", line: line) }
        catch { XCTAssertEqual(error as? BotFailure, .unsupported, line: line) }
    }

    private func connectedClient(_ socket: VoiceScriptedSocket, then next: VoiceScriptedSocket? = nil) async throws -> BotClient {
        VoiceHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/profiles/active": return (200, .object(["current": .string("default")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("t")]))
            default: return (200, .object(["ok": .bool(true)]))
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceHTTPFixture.self]
        var opened = 0
        let client = BotClient(connection: connection(), configuration: configuration) { _ in
            opened += 1
            return opened > 1 ? (next ?? socket) : socket
        }
        try await client.connect()
        return client
    }

    private func connection() -> BotConnection {
        BotConnection(id: UUID(), name: "Fixture", address: URL(string: "https://hermes.example")!, username: "user", password: "fixture")
    }
}

import AVFoundation
enum AVAudioFormatFactory {
    static func mono24k() -> AVAudioFormat { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)! }
}

@MainActor func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() { await Task.yield(); try? await Task.sleep(for: .milliseconds(2)) }
}

@MainActor final class FakePlayer: VoicePlayback {
    var begun: [Int] = []
    var pcm = 0
    var stops = 0
    var earcons = 0
    /// Hold `finishSpeech` until `drain()` (reply audio still playing).
    var holdDrain = false
    private(set) var drains: [() -> Void] = []
    func drain() { let d = drains; drains = []; d.forEach { $0() } }
    /// With a clock, the reply plays in real time from the first PCM (24 kHz int16 mono),
    /// so `queuedSpeechSeconds` is what is still left to play.
    var clock: (() -> Date)?
    private var playStart: Date?
    var queuedSpeechSeconds: TimeInterval {
        guard let clock, let playStart else { return 0 }
        return max(0, Double(pcm) / 48000 - clock().timeIntervalSince(playStart))
    }
    func beginSpeech(sampleRate: Int, channels: Int) { begun.append(sampleRate) }
    func enqueue(pcm: Data) {
        if playStart == nil, let clock { playStart = clock() }
        self.pcm += pcm.count
    }
    func finishSpeech(onDrained: @escaping () -> Void) { if holdDrain { drains.append(onDrained) } else { onDrained() } }
    func playClip(_ data: Data, onDrained: @escaping () -> Void) { onDrained() }
    var stopReasons: [String] = []
    func stopSpeech(reason: String) { stops += 1; stopReasons.append(reason) }
    var paused = false
    var pauses = 0
    var resumeReasons: [String] = []
    func pauseSpeech() { paused = true; pauses += 1 }
    func resumeSpeech(reason: String) { guard paused else { return }; paused = false; resumeReasons.append(reason) }
    func earcon() { earcons += 1 }
}

@MainActor final class FakeVoiceBackend: BotVoiceBackend {
    var replayEpoch: String? = "e"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var calls: [(String, [String: BotJSON])] = []
    var marks: [String] = []
    var transcribed: [String] = []
    var transcript = "what time is it"
    /// `prompt.submit` reply status ("streaming" when idle; "queued"/"redirected" while busy).
    var submitStatus = "streaming"
    var failSubmit = false
    /// Deterministic acknowledgement gates for voice end-tail tests; no clock or sleeps.
    var callHook: ((String, [String: BotJSON]) async throws -> BotJSON?)?
    var steerStatus = "queued"
    var resumeFailure: BotFailure?
    /// The next N transcribe calls throw (a proxy 502).
    var failTranscribes = 0
    var speakSockets: [VoiceScriptedSocket] = []
    var closed = false
    /// `connect()` throws, as a dashboard that can't be reached does.
    var failConnect = false
    private var opened = 0

    func connect() async throws { if failConnect { throw BotFailure.transport } }
    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        let method = call.method, params = try call.params()
        calls.append((method, params))
        if let reply = try await callHook?(method, params) { return reply }
        if method == "session.steer" { return .object(["status": .string(steerStatus)]) }
        if method == "session.create" { return .object(["session_id": .string("rt-1"), "stored_session_id": .string("key-1")]) }
        if method == "session.resume" {
            if let resumeFailure { throw resumeFailure }
            return .object(["session_id": .string("rt-resumed")])
        }
        if method == "prompt.submit" {
            if failSubmit { throw BotFailure.transport }
            return .object(["status": .string(submitStatus)])
        }
        return .object(["ok": .bool(true)])
    }
    func close() { closed = true }
    /// Holds `markVoiceSession` until the test lets it go (ordering tests; no clock).
    var markGate: ((String) async -> Void)?
    func markVoiceSession(_ sessionKey: String, active: Bool) async throws {
        await markGate?("\(sessionKey):\(active)")
        marks.append("\(sessionKey):\(active)")
    }
    func transcribeVoice(sessionKey: String, audio: Data, mimeType: String) async throws -> String {
        transcribed.append(sessionKey)
        transcribing += 1
        maxConcurrentTranscribes = max(maxConcurrentTranscribes, transcribing)
        defer { transcribing -= 1 }
        if let transcribeDelay { try? await Task.sleep(for: transcribeDelay) }
        if failTranscribes > 0 { failTranscribes -= 1; throw BotFailure.transport }
        if !transcripts.isEmpty { return transcripts.removeFirst() }
        return transcript
    }
    var transcripts: [String] = []
    var transcribeDelay: Duration?
    private var transcribing = 0
    private(set) var maxConcurrentTranscribes = 0
    func voiceGlossary() async throws -> [String] { [] }
    func saveVoiceGlossary(_ terms: [String]) async throws -> [String] { terms }
    func speakClip(_ text: String) async throws -> Data { Data() }
    func openSpeakStream() async throws -> any BotSocket {
        let socket = VoiceScriptedSocket(); speakSockets.append(socket); opened += 1; return socket
    }
    func speakOpened(count: Int = 1) async {
        await waitUntil { self.speakSockets.count >= count }
        for _ in 0..<5 { await Task.yield() }
    }
    func emit(_ type: String, _ payload: [String: BotJSON] = [:]) {
        onEvent?(.object(["type": .string(type), "session_id": .string("rt-1"), "payload": .object(payload)]))
    }
}

final class VoiceHTTPFixture: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, BotJSON))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: BotFailure.transport); return }
        let (status, value) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Serves the gateway handshake and scripted replies; also stands in for a speak-stream socket.
final class VoiceScriptedSocket: BotSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [URLSessionWebSocketTask.Message] = [
        .string(#"{"method":"event","params":{"type":"gateway.ready","payload":{"replay_epoch":"epoch"}}}"#)]
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var closed = false
    var reply: ((BotJSON) -> BotJSON)?
    private(set) var sentMethods: [String] = []
    private(set) var sentJSON: [BotJSON] = []

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: BotFailure.transport) }
            else if !frames.isEmpty { let f = frames.removeFirst(); lock.unlock(); continuation.resume(returning: f) }
            else { waiter = continuation; lock.unlock() }
        }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message, let json = try? JSONDecoder().decode(BotJSON.self, from: Data(text.utf8)) else { return }
        guard let method = json["method"].text else { lock.lock(); sentJSON.append(json); lock.unlock(); return }
        if method == "gateway.ping" { return }
        if method != "client.capabilities" { lock.lock(); sentMethods.append(method); lock.unlock() }
        let response = method == "client.capabilities" ? .object(["id": json["id"], "result": .object([:])])
            : (reply?(json) ?? .object(["id": json["id"], "result": .object([:])]))
        push(.string(String(decoding: try JSONEncoder().encode(response), as: UTF8.self)))
    }
    func push(_ frame: URLSessionWebSocketTask.Message) {
        lock.lock()
        let w = waiter; waiter = nil
        if w == nil { frames.append(frame) }
        lock.unlock()
        w?.resume(returning: frame)
    }
    func waitForSent(_ count: Int) async {
        for _ in 0..<500 {
            lock.lock(); let n = sentJSON.count; lock.unlock()
            if n >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
    func cancel() {
        lock.lock(); closed = true
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume(throwing: BotFailure.transport)
    }
}
