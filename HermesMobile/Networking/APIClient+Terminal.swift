import Foundation

// The terminal server contract is hermes-webui's
// `api/terminal.py` + `_handle_terminal_*` in `api/routes.py`: one PTY per chat
// session id, raw keystrokes in via `input` (max 8192 chars per POST), output
// out via the `/api/terminal/output` SSE stream (see `TerminalOutputStream`).
extension APIClient {
    /// Starts (or re-joins) the chat's terminal. A live terminal with the same
    /// workspace is just resized and returned; `restart` kills it first.
    func terminalStart(sessionID: String, rows: Int, cols: Int, restart: Bool = false) async throws -> TerminalStartResponse {
        try await send(
            endpoint: .terminalStart,
            method: "POST",
            body: TerminalStartRequest(sessionID: sessionID, rows: rows, cols: cols, restart: restart ? true : nil)
        )
    }

    func terminalInput(sessionID: String, data: String) async throws -> TerminalOKResponse {
        try await send(endpoint: .terminalInput, method: "POST", body: TerminalInputRequest(sessionID: sessionID, data: data))
    }

    func terminalResize(sessionID: String, rows: Int, cols: Int) async throws -> TerminalOKResponse {
        try await send(endpoint: .terminalResize, method: "POST", body: TerminalResizeRequest(sessionID: sessionID, rows: rows, cols: cols))
    }

    func terminalClose(sessionID: String) async throws -> TerminalOKResponse {
        try await send(endpoint: .terminalClose, method: "POST", body: TerminalSessionRequest(sessionID: sessionID))
    }
}

struct TerminalStartResponse: Decodable, Equatable {
    let ok: Bool?
    let sessionId: String?
    let workspace: String?
    let running: Bool?
}

struct TerminalOKResponse: Decodable, Equatable {
    let ok: Bool?
    let closed: Bool?
}

struct TerminalStartRequest: Encodable {
    let sessionID: String
    let rows: Int
    let cols: Int
    let restart: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", rows, cols, restart
    }
}

struct TerminalInputRequest: Encodable {
    let sessionID: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", data
    }
}

struct TerminalResizeRequest: Encodable {
    let sessionID: String
    let rows: Int
    let cols: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", rows, cols
    }
}

struct TerminalSessionRequest: Encodable {
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

extension APIError {
    /// 400 `remote_terminal_backend_unsupported`: the server runs terminals on a
    /// remote backend, which has no PTY for the app to attach to.
    var indicatesRemoteTerminalBackend: Bool {
        guard case .http(let statusCode, let body) = self, statusCode == 400 else { return false }
        return serverCode == "remote_terminal_backend_unsupported"
            || body?.contains("remote_terminal_backend_unsupported") == true
    }
}
