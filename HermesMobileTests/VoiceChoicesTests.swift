import XCTest
@testable import HermesMobile

@MainActor final class VoiceChoicesTests: XCTestCase {
    static let capturedGET = #"{"ok": true, "live": {"voice": "marin", "choices": ["marin", "cedar", "quartz", "ripple", "vesper", "willow", "stone", "gleam", "meridian", "bossa", "tempo", "beacon", "delta", "cinder"]}, "cascade": {"voice": "marin", "choices": ["alloy", "ash", "ballad", "cedar", "coral", "echo", "fable", "marin", "nova", "onyx", "sage", "shimmer", "verse"]}}"#
    /// The box's reply to `PUT {"mode": "live", "voice": "alloy"}`: 400.
    static let captured400 = #"{"detail":"Voice not available for this mode"}"#

    private static func captured() throws -> VoiceChoices {
        try XCTUnwrap(VoiceChoices(try JSONDecoder().decode(BotJSON.self, from: Data(capturedGET.utf8))))
    }

    func testDecodesTheCapturedReplyInTheHostsOrder() throws {
        let choices = try Self.captured()
        XCTAssertEqual(choices.live.voice, "marin")
        XCTAssertEqual(choices.live.choices, ["marin", "cedar", "quartz", "ripple", "vesper", "willow", "stone", "gleam",
                                              "meridian", "bossa", "tempo", "beacon", "delta", "cinder"])
        XCTAssertEqual(choices.cascade.voice, "marin")
        XCTAssertEqual(choices.cascade.choices, ["alloy", "ash", "ballad", "cedar", "coral", "echo", "fable", "marin",
                                                 "nova", "onyx", "sage", "shimmer", "verse"])
        XCTAssertEqual(VoiceChoices.title("meridian"), "Meridian")
        XCTAssertNil(VoiceChoices(.object(["ok": .bool(false)])))
        XCTAssertNil(VoiceChoices(.object(["ok": .bool(true), "live": .object(["voice": .string("marin")])])))
    }

    func testRoutesAskForTheDashboardsOwnProfile() throws {
        let base = URL(string: "https://hermes.example")!
        let get = try HermesREST.voiceChoices().request(base: base)
        XCTAssertEqual(get.httpMethod, "GET")
        XCTAssertEqual(get.url?.absoluteString, "https://hermes.example/api/plugins/hermex-push/voice/voices")
        let put = try HermesREST.saveVoiceChoice(mode: "cascade", voice: "cedar").request(base: base)
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.absoluteString, "https://hermes.example/api/plugins/hermex-push/voice/voices")
        XCTAssertEqual(try JSONDecoder().decode(BotJSON.self, from: put.httpBody ?? Data()),
                       .object(["mode": .string("cascade"), "voice": .string("cedar")]))
    }

    func testPickShowsTheVoiceTheHostAnswered() async throws {
        let start = try Self.captured()
        var answered = start
        answered.cascade.voice = "cedar"
        var sent: [(VoiceChoices.Mode, String)] = []
        let model = VoiceChoicesModel(fetch: { start }, save: { mode, voice in sent.append((mode, voice)); return answered })
        await model.load()
        await model.select("cedar", for: .cascade)
        XCTAssertEqual(sent.map(\.0), [.cascade])
        XCTAssertEqual(sent.map(\.1), ["cedar"])
        XCTAssertEqual(model.state, .loaded(answered))
        XCTAssertNil(model.failure)
        XCTAssertNil(model.saving)
    }

    /// A refused pick (the host's real 400 through `BotClient`) leaves the picker on the host's
    /// voice, with the short error line; the next good pick clears the line.
    func testRefusedPickStaysOnTheHostsVoiceWithAnErrorLine() async throws {
        VoiceHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object(["ok": .bool(true)]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("t")]))
            case "/api/plugins/hermex-push/capabilities":
                return (200, .object(["routes": .array([.string("GET /voice/voices")])]))
            case "/api/plugins/hermex-push/voice/voices":
                let body = request.httpMethod == "PUT" ? Self.captured400 : Self.capturedGET
                let value = try! JSONDecoder().decode(BotJSON.self, from: Data(body.utf8))
                return (request.httpMethod == "PUT" ? 400 : 200, value)
            default: XCTFail("Unexpected " + request.url!.path); return (404, .null)
            }
        }
        defer { VoiceHTTPFixture.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceHTTPFixture.self]
        let connection = BotConnection(id: UUID(), name: "Fixture", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "fixture")
        func client() async throws -> BotClient {
            let client = BotClient(connection: connection, configuration: configuration) { _ in VoiceScriptedSocket() }
            try await client.connect()
            return client
        }
        let model = VoiceChoicesModel(fetch: {
            let c = try await client(); defer { c.close() }
            return try await c.voiceChoices()
        }, save: { mode, voice in
            let c = try await client(); defer { c.close() }
            return try await c.saveVoiceChoice(mode: mode, voice: voice)
        })

        await model.load()
        let start = try Self.captured()
        XCTAssertEqual(model.state, .loaded(start))
        await model.select("cedar", for: .live)
        XCTAssertEqual(model.state, .loaded(start), "the picker returns to marin, the host's voice")
        XCTAssertEqual(model.failure, VoiceChoicesModel.failureText)
        XCTAssertNil(model.saving)
    }

    func testVoicePickersRequireAnAdvertisedCompanionReadRoute() async throws {
        defer { VoiceHTTPFixture.handler = nil }
        for (status, routes, shown) in [(404, [String](), false), (200, ["PUT /voice/voices"], false),
                                         (200, ["GET /voice/voices"], true)] {
            var reads = 0
            VoiceHTTPFixture.handler = { request in
                switch request.url!.path {
                case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
                case "/auth/password-login": return (200, .object(["ok": .bool(true)]))
                case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
                case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("t")]))
                case "/api/plugins/hermex-push/capabilities":
                    return (status, .object(["routes": .array(routes.map(BotJSON.string))]))
                case "/api/plugins/hermex-push/voice/voices":
                    reads += 1
                    return (200, try! JSONDecoder().decode(BotJSON.self, from: Data(Self.capturedGET.utf8)))
                default: XCTFail("Unexpected " + request.url!.path); return (404, .null)
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [VoiceHTTPFixture.self]
            let connection = BotConnection(id: UUID(), name: "Fixture", address: URL(string: "https://hermes.example")!,
                                           username: "user", password: "fixture")
            let client = BotClient(connection: connection, configuration: configuration) { _ in VoiceScriptedSocket() }
            defer { client.close() }
            try await client.connect()
            let model = VoiceChoicesModel(fetch: { try await client.voiceChoices() },
                                          save: { _, _ in throw BotFailure.transport })
            await model.load()
            XCTAssertEqual(model.showsSection, shown)
            XCTAssertEqual(reads, shown ? 1 : 0, "An absent companion route must not be probed")
            XCTAssertEqual(model.state, shown ? .loaded(try Self.captured()) : .unavailable)
        }
    }

    func testUnreachableHostShowsTheSetOnYourHermesText() async {
        let model = VoiceChoicesModel(fetch: { throw BotFailure.missingChat }, save: { _, _ in throw BotFailure.transport })
        XCTAssertEqual(model.state, .loading)
        await model.load()
        XCTAssertEqual(model.state, .unreachable)
        XCTAssertEqual(VoiceChoicesModel.unreachableText, "Set on your Hermes")
        await model.select("cedar", for: .live)
        XCTAssertEqual(model.state, .unreachable, "nothing is sent without the host's list")
    }
}
