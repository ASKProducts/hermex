import Foundation
import Observation

/// The calls `TerminalSessionController` makes. `APIClient` is the real one;
/// tests use a fake.
protocol TerminalAPI: Sendable {
    func terminalStart(sessionID: String, rows: Int, cols: Int, restart: Bool) async throws -> TerminalStartResponse
    func terminalInput(sessionID: String, data: String) async throws -> TerminalOKResponse
    func terminalResize(sessionID: String, rows: Int, cols: Int) async throws -> TerminalOKResponse
}

extension APIClient: TerminalAPI {}

/// Chats (per server) for which this app run has had a shell open. Used only to
/// tell "reopened after the old shell was cleaned up" apart from a first open.
@MainActor
enum TerminalShellRegistry {
    private static var known: Set<String> = []

    static func key(server: URL, sessionID: String) -> String { "\(server.absoluteString)|\(sessionID)" }
    static func isKnown(_ key: String) -> Bool { known.contains(key) }
    static func markKnown(_ key: String) { known.insert(key) }
    static func reset() { known.removeAll() }
}

/// Owns one chat's terminal while its screen is open: start/attach, the serial
/// input queue, debounced resize, output replay and reconnect, and the ended
/// state. Dismissing the screen only detaches; the server keeps the shell alive
/// (its idle reaper kills it after 15 min with no viewer).
@MainActor
@Observable
final class TerminalSessionController {
    enum EndReason: Equatable {
        case exited(Int?)
        case gone
        case error(String)
    }

    enum State: Equatable {
        case idle
        case connecting
        case live
        case reconnecting
        case ended(EndReason)
        /// Start failed (e.g. remote backend, network). No terminal is shown.
        case failed(String)
    }

    /// The server accepts up to 8192 chars per `input`, but it writes each POST to
    /// the PTY in one go, and a macOS PTY drops input past its small line buffer
    /// when a big write lands at once (a 20 KB paste in 8192-char POSTs arrived as
    /// 2,972 bytes; 1024-char POSTs lost 820 bytes; 256-char POSTs arrived intact).
    /// So pastes go out in 256-char POSTs, one at a time.
    static let maxInputChunk = 256
    static let previousSessionNotice = "Previous session ended, new shell started"

    private(set) var state: State = .idle
    private(set) var workspace: String?

    /// Receives PTY output (raw ANSI text) in order; the view feeds it to SwiftTerm.
    @ObservationIgnored var onOutput: ((String) -> Void)?

    @ObservationIgnored let sessionID: String
    @ObservationIgnored private let server: URL
    @ObservationIgnored private let api: any TerminalAPI
    @ObservationIgnored private let stream: any TerminalOutputStreaming
    @ObservationIgnored private let resizeDebounce: Duration
    @ObservationIgnored private let reconnectDelay: (Int) -> Duration

    @ObservationIgnored private(set) var lastSeq: Int?
    @ObservationIgnored private var size: (rows: Int, cols: Int) = (24, 80)
    @ObservationIgnored private var pendingInput = ""
    @ObservationIgnored private var isSendingInput = false
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var isSuspended = false

    init(
        sessionID: String,
        server: URL,
        api: any TerminalAPI,
        stream: (any TerminalOutputStreaming)? = nil,
        resizeDebounce: Duration = .milliseconds(150),
        reconnectDelay: @escaping (Int) -> Duration = { attempt in .milliseconds(min(8000, 500 << min(attempt, 4))) }
    ) {
        self.sessionID = sessionID
        self.server = server
        self.api = api
        self.stream = stream ?? TerminalOutputStream()
        self.resizeDebounce = resizeDebounce
        self.reconnectDelay = reconnectDelay
    }

    private var registryKey: String { TerminalShellRegistry.key(server: server, sessionID: sessionID) }

    // MARK: - Lifecycle

    /// Starts (or re-joins) the shell at the view's measured size, then attaches.
    func open(rows: Int, cols: Int) async {
        guard state == .idle || isFailed else { return }
        size = (max(rows, 1), max(cols, 1))
        state = .connecting
        // A shell this app knew about that no longer answers a resize is gone
        // (reaped, exited, or closed server-side): the start below makes a new one.
        var previousGone = false
        if TerminalShellRegistry.isKnown(registryKey) {
            do {
                _ = try await api.terminalResize(sessionID: sessionID, rows: size.rows, cols: size.cols)
            } catch let error as APIError {
                if case .http(404, _) = error { previousGone = true }
            } catch {}
        }
        await start(restart: false, notice: previousGone)
    }

    /// Kills the shell and starts a fresh one (menu "Restart shell", ended-state Restart).
    func restart() async {
        stream.stop()
        reconnectTask?.cancel()
        state = .connecting
        await start(restart: true, notice: false)
    }

    /// Stops the output stream. Never closes the shell.
    func detach() {
        reconnectTask?.cancel()
        resizeTask?.cancel()
        stream.stop()
        if state == .live || state == .reconnecting || state == .connecting { state = .idle }
    }

    /// App went to the background: iOS drops the stream anyway.
    func suspend() {
        guard state == .live || state == .reconnecting else { return }
        isSuspended = true
        reconnectTask?.cancel()
        stream.stop()
        state = .reconnecting
    }

    /// App came back: reattach with Last-Event-ID so only missed output replays.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        guard state == .reconnecting else { return }
        reconnectAttempts = 0
        attach()
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func start(restart: Bool, notice: Bool) async {
        do {
            let response = try await api.terminalStart(sessionID: sessionID, rows: size.rows, cols: size.cols, restart: restart)
            workspace = response.workspace?.nilIfBlank ?? workspace
        } catch let error as APIError where error.indicatesRemoteTerminalBackend {
            state = .failed(String(localized: "This server runs terminals on a remote backend, which the app can't attach to."))
            return
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }
        TerminalShellRegistry.markKnown(registryKey)
        // A new shell numbers its output from 1 again; replay all of it.
        if restart || notice { lastSeq = nil }
        if notice {
            onOutput?("\u{1B}[2m\(Self.previousSessionNotice)\u{1B}[0m\r\n")
        }
        reconnectAttempts = 0
        attach()
    }

    private func attach() {
        let url = Endpoint.terminalOutput(sessionID: sessionID).url(relativeTo: server)
        stream.start(url: url, lastEventID: lastSeq.map(String.init)) { [weak self] event in
            self?.handle(event)
        }
        if state != .live { state = .live }
    }

    func handle(_ event: TerminalStreamEvent) {
        switch event {
        case let .output(text, seq):
            if let seq {
                if let lastSeq, seq <= lastSeq { return }
                lastSeq = seq
            }
            reconnectAttempts = 0
            if state != .live { state = .live }
            onOutput?(text)
        case let .closed(exitCode):
            end(.exited(exitCode))
        case .gone:
            end(.gone)
        case let .serverError(message):
            end(.error(message))
        case .disconnected:
            guard !isSuspended, case .live = state else { return }
            scheduleReconnect()
        case .ignored:
            break
        }
    }

    private func end(_ reason: EndReason) {
        reconnectTask?.cancel()
        stream.stop()
        pendingInput = ""
        state = .ended(reason)
    }

    private func scheduleReconnect() {
        state = .reconnecting
        let delay = reconnectDelay(reconnectAttempts)
        reconnectAttempts += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.state == .reconnecting, !self.isSuspended else { return }
            self.attach()
        }
    }

    // MARK: - Input

    /// Queues keystrokes. One POST at a time, in order; keys typed while a POST
    /// is in flight are coalesced into the next one (≤ `maxInputChunk` chars each).
    func send(_ text: String) {
        guard !text.isEmpty else { return }
        switch state {
        case .live, .reconnecting, .connecting: break
        default: return
        }
        pendingInput += text
        guard !isSendingInput else { return }
        isSendingInput = true
        Task { await pumpInput() }
    }

    private func pumpInput() async {
        defer { isSendingInput = false }
        while !pendingInput.isEmpty {
            let chunk = Self.takeChunk(from: &pendingInput)
            var attempt = 0
            while true {
                do {
                    _ = try await api.terminalInput(sessionID: sessionID, data: chunk)
                    break
                } catch let error as APIError where Self.is404(error) {
                    end(.gone)
                    return
                } catch {
                    attempt += 1
                    if attempt >= 3 { pendingInput = ""; return }
                    try? await Task.sleep(for: .milliseconds(300 * attempt))
                }
            }
        }
    }

    /// Removes and returns the first ≤ `maxInputChunk` characters. Counted in Unicode scalars,
    /// which is how the server (Python `len`) measures the limit.
    static func takeChunk(from buffer: inout String) -> String {
        let scalars = buffer.unicodeScalars
        guard scalars.count > maxInputChunk else {
            defer { buffer = "" }
            return buffer
        }
        let cut = scalars.index(scalars.startIndex, offsetBy: maxInputChunk)
        let chunk = String(scalars[scalars.startIndex..<cut])
        buffer = String(scalars[cut...])
        return chunk
    }

    private static func is404(_ error: APIError) -> Bool {
        if case .http(404, _) = error { return true }
        return false
    }

    // MARK: - Resize

    /// Called from SwiftTerm's `sizeChanged`; sent after a short debounce.
    func resize(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return }
        size = (rows, cols)
        resizeTask?.cancel()
        guard state == .live || state == .reconnecting else { return }
        let debounce = resizeDebounce
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled else { return }
            _ = try? await self.api.terminalResize(sessionID: self.sessionID, rows: rows, cols: cols)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
