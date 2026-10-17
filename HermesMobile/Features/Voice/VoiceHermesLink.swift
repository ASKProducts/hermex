import Foundation

/// own one: GPT-Live (`VoiceLiveConversation`) and Cascade (`VoiceSession`).
///
/// When the call's client hears its socket end (`lost(_:)`), the link reconnects on the
/// backoff Bot screens use (`HermesConversation`'s 1, 2, 4… s, `HermesReconnectBackoff`) and,
/// once connected, runs the owner's `reattach` (`session.resume` on the call's stored key,
/// as "Continue by voice" does). Requests the call makes meanwhile wait in `ready()` and go
/// out once it is back. After `maxAttempts` failed attempts, or a failure that cannot clear
/// on its own (the connection was replaced, the session is gone), the call is ended with
/// the reason (`onGaveUp`).
@MainActor final class VoiceHermesLink {
    enum State: Equatable { case connected, reconnecting, failed }

    /// Reconnect attempts before the call ends: with the backoff, ~31 s of waiting.
    static let maxAttempts = 5

    private(set) var state = State.connected
    /// Attempts made in the current gap (diagnostics, tests).
    private(set) var attempts = 0
    /// Gaps recovered from since the call started (diagnostics, tests).
    private(set) var recoveries = 0

    private let backend: any BotTransport
    private let delay: (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    /// The newest `seq` the call has seen on its runtime, so a re-attach replays only what
    /// the gap missed (`session.events.since`, the host's replay ring).
    private(set) var lastSeq = 0

    /// Re-attaches the call's chat on the new socket: the owner's `session.resume`.
    var reattach: () async throws -> Void = {}
    /// The socket dropped and reconnecting began.
    var onLost: () -> Void = {}
    /// The chat is attached again.
    var onRestored: () -> Void = {}
    /// Reconnecting stopped for good; the owner ends the call.
    var onGaveUp: (Error) -> Void = { _ in }

    init(backend: any BotTransport,
         delay: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.backend = backend
        self.delay = delay
    }

    /// The call's chat sent `frame`: remembers its `seq` when it is the call's runtime's.
    func saw(_ frame: BotJSON, runtime: String?) {
        guard let runtime, frame["session_id"].text == runtime, let seq = frame["seq"].integer, seq > lastSeq else { return }
        lastSeq = seq
    }

    /// Attaches the call's chat on the new socket: `session.resume` on its stored key (as
    /// "Continue by voice" does), then, when the host kept the same runtime, the events
    /// after `lastSeq` from its replay ring, oldest first. A new runtime (the old one was
    /// reaped) has no events for this call, so none are replayed.
    func resume(key: String, profile: String?, runtime: String?) async throws -> (runtime: String, missed: [BotJSON]) {
        let reply = try await backend.call(.voiceSessionResume(sessionID: key, profile: profile), validateDispatch: nil)
        guard let live = reply["session_id"].text, !live.isEmpty else { throw BotFailure.unsupported }
        guard live == runtime else { lastSeq = 0; return (live, []) }
        let replay = try await backend.call(.sessionEventsSince(sessionID: live, lastSeen: lastSeq), validateDispatch: nil)
        let missed = (replay["events"].list ?? []).filter { $0["session_id"].text == live }
        return (live, missed)
    }

    /// The call's client heard its socket end. Starts reconnecting unless already doing so.
    func lost(_ error: Error) {
        guard state == .connected else { return }
        state = .reconnecting
        attempts = 0
        onLost()
        task = Task { [weak self] in await self?.reconnect() }
    }

    /// True once the chat is attached (at once when it is); false when reconnecting gave up
    /// or the call ended.
    func ready() async -> Bool {
        switch state {
        case .connected: return true
        case .failed: return false
        case .reconnecting: return await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// The call ended: stop reconnecting; anything waiting hears false.
    func cancel() {
        task?.cancel(); task = nil
        finish(.failed)
    }

    private func reconnect() async {
        var lastError: Error = BotFailure.transport
        while attempts < Self.maxAttempts {
            attempts += 1
            do { try await delay(HermesReconnectBackoff.delay(attempt: attempts)) } catch { return }
            guard state == .reconnecting, !Task.isCancelled else { return }
            do {
                try await backend.connect()
                try await reattach()
                guard state == .reconnecting, !Task.isCancelled else { return }
                recoveries += 1
                finish(.connected)
                onRestored()
                return
            } catch {
                guard state == .reconnecting, !Task.isCancelled else { return }
                lastError = error
                if !HermesReconnectBackoff.mayClear(error) { break }
            }
        }
        task = nil
        finish(.failed)
        onGaveUp(lastError)
    }

    private func finish(_ state: State) {
        self.state = state
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: state == .connected) }
    }
}

/// The reconnect schedule and retry rule Bot screens use after a lost socket
/// (`HermesConversation.scheduleReconnect`/`disconnect`): 1 s, doubling to 30 s; a lost
/// transport, a timeout, a rate limit, a 5xx and the host's passing `session.resume`
/// refusals (4007 while it swaps a runtime, 4009 while a client-gone interrupt settles)
/// may clear on their own.
enum HermesReconnectBackoff {
    static func delay(attempt: Int) -> Duration {
        .seconds(min(1 << min(max(attempt - 1, 0), 5), 30))
    }

    static func mayClear(_ error: Error) -> Bool {
        switch error as? BotFailure ?? .transport {
        case .transport: return true
        case .rejected(let code): return [408, 429, 4007, 4009].contains(code) || (500...599).contains(code)
        default: return false
        }
    }
}
