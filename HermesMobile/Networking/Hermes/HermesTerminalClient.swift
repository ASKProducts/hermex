import Foundation

@MainActor struct HermesTerminalTarget: Identifiable {
    let server: URL
    let http: HermesConnection
    let sessionID: String
    let profile: String
    var id: String { [server.absoluteString, String(http.serial), profile, sessionID].joined(separator: "\0") }

    static func listed(_ session: SessionSummary, server: URL, http: HermesConnection, profile: String?) -> Self? {
        guard let metadata = session.hermes, !metadata.isBotChat,
              let key = session.sessionId, !key.isEmpty,
              let profile = session.profile ?? profile, !profile.isEmpty else { return nil }
        return Self(server: server, http: http, sessionID: key, profile: profile)
    }
}

struct TerminalSize: Equatable, Sendable {
    let columns: Int
    let rows: Int
    init(columns: Int = 80, rows: Int = 24) {
        self.columns = min(2000, max(1, columns))
        self.rows = min(1000, max(1, rows))
    }
    var frame: URLSessionWebSocketTask.Message { .string("\u{1b}[RESIZE:\(columns);\(rows)]") }
}

enum HermesTerminalFailure: Error, Equatable {
    case exited, replaced, refused, lost, connection(BotFailure)
    var canReconnect: Bool {
        switch self {
        case .lost: return true
        case .connection(.stale), .connection(.missingChat): return false
        case .connection(let error): return BotConnectionAdvice.isRetryable(error)
        default: return false
        }
    }
    static func read(_ error: Error, closeCode: Int) -> Self {
        if let failure = error as? BotFailure, failure != .transport { return .connection(failure) }
        if error is DecodingError { return .connection(.unsupported) }
        switch closeCode {
        case 4410: return .exited
        case 4409: return .replaced
        case 4400...4408: return .refused
        default: return .lost
        }
    }
}

enum HermesTerminalEvent: Equatable {
    case opened, replayStarted(unseen: Int), replayEnded, output(Data), failed(HermesTerminalFailure)
}

@MainActor final class HermesTerminalClient {
    typealias Options = PluginWebSocketClient.Options
    let target: HermesTerminalTarget
    private let socket: PluginWebSocketClient
    init(target: HermesTerminalTarget, options: Options = Options()) {
        self.target = target
        socket = PluginWebSocketClient(http: target.http, name: "terminal", options: options)
    }
    static func isAvailable(on http: HermesConnection) async -> Bool {
        guard !http.isRetired else { return false }
        if http.companionRouteProbe == nil {
            http.companionRouteProbe = Task { try await BotDashboardClient(http: http).companionRoutes() }
        }
        do {
            let routes = try await http.companionRouteProbe?.value
            return !http.isRetired && routes?.supportsTerminal == true
        } catch {
            http.invalidateCompanionRoutes()
            return false
        }
    }
    func status() async throws -> Bool? {
        struct Status: Decodable { let running: Bool? }
        return try JSONDecoder().decode(Status.self, from: await target.http.data(
            .terminalStatus(sessionID: target.sessionID, profile: target.profile))).running
    }
    func start(size: TerminalSize, event: @escaping @MainActor (HermesTerminalEvent) async -> Void) {
        socket.start(upgrade: { [target] in
            try await target.http.terminalUpgrade(sessionID: target.sessionID, profile: target.profile, size: size)
        }, onOpen: { await event(.opened) }, onMessage: { message in
            switch message {
            case .data(let data): await event(.output(data))
            case .string(let text):
                struct Control: Decodable { let type: String?; let state: String?; let unseen: Int? }
                guard let control = try? JSONDecoder().decode(Control.self, from: Data(text.utf8)), control.type == "replay" else { return }
                if control.state == "start" { await event(.replayStarted(unseen: max(0, control.unseen ?? 0))) }
                if control.state == "end" { await event(.replayEnded) }
            @unknown default: break
            }
        }, onFailure: { error, code in await event(.failed(.read(error, closeCode: code))) })
    }
    func send(_ message: URLSessionWebSocketTask.Message) { socket.send(message) }
    func stop() { socket.stop() }
}
