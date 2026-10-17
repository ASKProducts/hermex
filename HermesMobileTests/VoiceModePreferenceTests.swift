import XCTest
@testable import HermesMobile

@MainActor final class VoiceModePreferenceTests: XCTestCase {
    func testHostValuesAndUnknownFallback() {
        XCTAssertEqual(VoiceMode(hostValue: "gpt-live"), .live)
        XCTAssertEqual(VoiceMode(hostValue: "chained"), .normal)
        XCTAssertEqual(VoiceMode(hostValue: nil), .normal)
        XCTAssertEqual(VoiceMode(hostValue: "future-mode"), .normal)
        XCTAssertEqual(VoiceMode.live.hostValue, "gpt-live")
        XCTAssertEqual(VoiceMode.normal.hostValue, "chained")
    }

    func testPickerUsesTheHostsReadbackNotTheOptimisticPick() async {
        var sent: [VoiceMode] = []
        let model = VoiceModePreferenceModel(fetch: { .normal }, save: { sent.append($0); return .normal })
        await model.load()
        await model.select(.live)
        XCTAssertEqual(sent, [.live])
        XCTAssertEqual(model.state, .loaded(.normal))
        XCTAssertNil(model.saving)
    }

    func testRefusedPickPreservesTheHostValueAndReportsFailure() async {
        let model = VoiceModePreferenceModel(fetch: { .normal }, save: { _ in throw BotFailure.transport })
        await model.load()
        await model.select(.live)
        XCTAssertEqual(model.state, .loaded(.normal))
        XCTAssertNotNil(model.failure)
        XCTAssertNil(model.saving)
    }

    func testUnreachableSettingDoesNotWriteAnything() async {
        var writes = 0
        let model = VoiceModePreferenceModel(fetch: { throw BotFailure.transport }, save: { mode in writes += 1; return mode })
        await model.load()
        await model.select(.live)
        XCTAssertEqual(model.state, .unreachable)
        XCTAssertEqual(writes, 0)
    }

    func testModeAndVoiceRequestsAreProfileScopedAndPatchOneField() throws {
        let base = URL(string: "https://hermes.example")!
        let request = try HermesREST.setVoiceMode(profile: "work", mode: .live).request(base: base)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/api/config")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "profile", value: "work")])
        XCTAssertEqual(try JSONDecoder().decode(BotJSON.self, from: request.httpBody!),
                       .object(["config": .object(["voice": .object(["voice_chat_mode": .string("gpt-live")])])]))
        XCTAssertThrowsError(try HermesREST.setVoiceMode(profile: "", mode: .normal).request(base: base))
        for route in [HermesREST.voiceLiveStatus(profile: "work")] {
            let request = try route.request(base: base)
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "profile", value: "work")])
        }
    }

    func testClientSavesAndReadsBackTheDashboardCurrentProfileNotCLIActive() async throws {
        var mode = "chained"
        var reads: [String?] = []
        var writes: [String] = []
        VoiceHTTPFixture.handler = { request in
            let profile = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "profile" }?.value
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object(["ok": .bool(true)]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("t")]))
            case "/api/profiles/active": return (200, .object(["active": .string("cli-default"), "current": .string("work")]))
            case "/api/config":
                XCTAssertEqual(request.httpMethod, "PUT", "Never read unredacted config for this setting")
                XCTAssertEqual(profile, "work")
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(buffer, count: count)
                    }
                }
                guard let body = try? JSONDecoder().decode(BotJSON.self, from: data),
                      let sentMode = body["config"]["voice"]["voice_chat_mode"].text else {
                    XCTFail("Missing voice-mode request body")
                    return (400, .null)
                }
                XCTAssertEqual(body, .object(["config": .object(["voice": .object(["voice_chat_mode": .string("gpt-live")])])]))
                mode = sentMode
                writes.append(profile ?? "<missing>")
                return (200, .object(["ok": .bool(true)]))
            case "/api/audio/voice-live/status":
                reads.append(profile)
                return (200, .object(["ok": .bool(true), "mode": .string(mode), "available": .bool(true)]))
            default: XCTFail("Unexpected route"); return (404, .null)
            }
        }
        defer { VoiceHTTPFixture.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceHTTPFixture.self]
        let saved = BotConnection(id: UUID(), name: "Fixture", address: URL(string: "https://hermes.example")!, username: "user", password: "fixture")
        let client = BotClient(connection: saved, configuration: configuration) { _ in VoiceScriptedSocket() }
        defer { client.close() }
        try await client.connect()
        let first = try await client.voiceMode(profile: "work")
        XCTAssertEqual(first, .normal)
        let after = try await client.saveVoiceMode(.live, profile: nil)
        XCTAssertEqual(after, .live)
        XCTAssertEqual(writes, ["work"])
        XCTAssertEqual(reads, ["work", "work"], "the successful PUT is verified with a fresh status GET")
    }

    func testHostModeIsIndependentOfLegacyDevicePreference() throws {
        let key = "voice.defaultMode"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("live", forKey: key)
        let connection = BotConnection(id: UUID(), name: "Fixture", address: URL(string: "http://127.0.0.1:9")!, username: "u", password: "p")
        let model = VoiceScreenModel(server: connection.address, connection: connection, resumeSessionKey: nil)
        XCTAssertEqual(model.mode, .normal, "no local default is treated as host authority")
        model.applyLiveStatus(.init(mode: "gpt-live", available: true, reason: nil, model: nil, voice: nil))
        XCTAssertEqual(model.mode, .live)
        model.applyLiveStatus(.init(mode: "chained", available: true, reason: nil, model: nil, voice: nil))
        XCTAssertEqual(model.mode, .normal)
    }

    func testExplicitOverrideDoesNotReplaceTheHostMode() {
        let connection = BotConnection(id: UUID(), name: "Fixture", address: URL(string: "http://127.0.0.1:9")!, username: "u", password: "p")
        let model = VoiceScreenModel(server: connection.address, connection: connection, resumeSessionKey: "chat-1", resumeProfile: "work", requestedMode: .normal)
        model.applyLiveStatus(.init(mode: "gpt-live", available: true, reason: nil, model: nil, voice: nil))
        XCTAssertEqual(model.mode, .normal)
        XCTAssertEqual(model.hostPreferredMode, .live)
    }

    func testOldProfileReadCannotEnableTheNewProfilesLiveOption() async {
        let saved = BotConnection(id: UUID(), name: "Fixture", address: URL(string: "https://hermes.example")!, username: "u", password: "p")
        let first = VoiceStartScope(server: saved.address, connection: saved, profile: "first")
        let second = VoiceStartScope(server: saved.address, connection: saved, profile: "second")
        let availability = VoiceStartAvailability()
        let suspended = expectation(description: "first profile request")
        var reply: CheckedContinuation<VoiceLive.Status?, Never>?
        let task = Task {
            await availability.refresh(scope: first, load: { _ in
                await withCheckedContinuation { reply = $0; suspended.fulfill() }
            }, currentScope: { first })
        }
        await fulfillment(of: [suspended], timeout: 2)
        await availability.refresh(scope: second, load: { _ in
            .init(mode: "chained", available: false, reason: "No provider", model: nil, voice: nil)
        }, currentScope: { second })
        reply?.resume(returning: .init(mode: "gpt-live", available: true, reason: nil, model: nil, voice: nil))
        await task.value
        XCTAssertEqual(availability.scope, second)
        XCTAssertEqual(availability.state, .unavailable("No provider"))
    }
}
