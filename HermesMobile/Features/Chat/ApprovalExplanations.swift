import Foundation
import Observation

/// This server's optional explanations use its existing Hermes (Bots) connection.
enum ApprovalExplanationSetting {
    static func key(for server: URL) -> String { "approvalExplanations.enabled|\(server.absoluteString)" }

    static func isEnabled(server: URL, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(for: server)) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, server: URL, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key(for: server))
    }
}

/// One explanation per approval lifetime. Showing a card starts its request without
/// blocking the choices. Navigation cancels unfinished work and retains a terminal state;
/// only removal from the actual pending approvals drops the cached result.
@MainActor @Observable final class ApprovalExplanations {
    enum State: Equatable {
        case loading
        case ready(String)
        case failed
    }

    struct Key: Hashable {
        let scope: String
        let approvalID: String
    }

    typealias Explain = @MainActor (String) async throws -> String
    static let deadline: Duration = .seconds(20)

    private(set) var states: [Key: State] = [:]
    @ObservationIgnored private var requests: [Key: Request] = [:]
    @ObservationIgnored private var explain: Explain
    @ObservationIgnored private var release: (@MainActor () -> Void)?
    @ObservationIgnored private let waitForDeadline: @MainActor () async throws -> Void

    private struct Request {
        let token: UUID
        let task: Task<Void, Never>
        let deadline: Task<Void, Never>
    }

    /// `waitForDeadline` scripts the deadline in tests; production measures the entire
    /// request, including sign-in and socket attachment, from the moment the card asks.
    init(explain: @escaping Explain, release: (@MainActor () -> Void)? = nil,
         waitForDeadline: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(for: ApprovalExplanations.deadline)
         }) {
        self.explain = explain
        self.release = release
        self.waitForDeadline = waitForDeadline
    }

    static func input(description: String?, command: String?, workingDirectory: String?) -> String? {
        guard let command = trimmed(command) else { return nil }
        var lines: [String] = []
        if let description = trimmed(description) { lines.append("Why it was flagged: \(description)") }
        lines.append("Command: \(command)")
        if let workingDirectory = trimmed(workingDirectory) { lines.append("Working directory: \(workingDirectory)") }
        return lines.joined(separator: "\n")
    }

    func state(for key: Key, input: String?) -> State? {
        guard input != nil else { return nil }
        return states[key] ?? .loading
    }

    /// A cached terminal state prevents a second model request for the same approval.
    func show(_ key: Key, input: String?) {
        guard states[key] == nil, let input else { return }
        let token = UUID(), explain = self.explain, waitForDeadline = self.waitForDeadline
        states[key] = .loading
        let task = Task { [weak self] in
            let outcome: State
            do {
                let text = try await explain(input).trimmingCharacters(in: .whitespacesAndNewlines)
                outcome = text.isEmpty ? .failed : .ready(text)
            } catch {
                outcome = .failed
            }
            guard !Task.isCancelled, let self, self.requests[key]?.token == token else { return }
            self.requests.removeValue(forKey: key)?.deadline.cancel()
            self.states[key] = outcome
            self.releaseIfIdle()
        }
        let deadline = Task { [weak self] in
            do { try await waitForDeadline() } catch { return }
            guard !Task.isCancelled, let self, self.requests[key]?.token == token else { return }
            self.cancelRequest(key)
            self.states[key] = .failed
            self.releaseIfIdle()
        }
        requests[key] = Request(token: token, task: task, deadline: deadline)
    }

    /// `pending == nil` means no authoritative snapshot has arrived, not that approvals
    /// ended. Preserve lifetime state across that gap. A known set describes approval
    /// lifetime independently of presentation order (a question can cover an approval).
    func retain(_ current: Key?, inScope scope: String, pending: Set<Key>?) {
        let keys = Set(states.keys).union(requests.keys)
        for key in keys where key.scope == scope {
            if let pending, !pending.contains(key) {
                cancelRequest(key)
                states[key] = nil
            } else if key != current, requests[key] != nil {
                cancelRequest(key)
                states[key] = .failed
            }
        }
        releaseIfIdle()
    }

    func leave(scope: String) {
        for key in Array(requests.keys) where key.scope == scope {
            cancelRequest(key)
            states[key] = .failed
        }
        releaseIfIdle()
    }

    /// A server/setting/connection change stops work without making pending approvals
    /// eligible for another request when the user returns.
    func pauseAll() {
        for key in Array(requests.keys) {
            cancelRequest(key)
            states[key] = .failed
        }
        release?()
    }

    /// Replaces the consumer after saved credentials or headers change. Cached states
    /// belong to approvals, not to that consumer, so they remain.
    func replaceTransport(explain: @escaping Explain, release: @escaping @MainActor () -> Void) {
        pauseAll()
        self.explain = explain
        self.release = release
    }

    func cancelAll() {
        pauseAll()
        states.removeAll()
    }

    var inFlightCount: Int { requests.count }

    private func cancelRequest(_ key: Key) {
        guard let request = requests.removeValue(forKey: key) else { return }
        request.task.cancel()
        request.deadline.cancel()
    }

    private func releaseIfIdle() {
        if requests.isEmpty { release?() }
    }

    private static func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}

/// Server-keyed caches stay in memory while approvals are pending. Disabled or inactive
/// entries expose no summary area and hold no active socket consumer.
@MainActor @Observable final class ApprovalExplanationRegistry {
    static let shared = ApprovalExplanationRegistry()

    private struct Entry {
        let connection: BotConnection?
        let enabled: Bool
        let explanations: ApprovalExplanations?
    }
    private var entries: [URL: Entry] = [:]
    private var activeServer: URL?
    private var hasServerSelection = false
    @ObservationIgnored private let makeExplain: (BotConnection, URL) -> (ApprovalExplanations.Explain, @MainActor () -> Void)

    init(makeExplain: @escaping (BotConnection, URL) -> (ApprovalExplanations.Explain, @MainActor () -> Void)
            = ApprovalExplanationRegistry.liveExplain) {
        self.makeExplain = makeExplain
    }

    func explanations(for server: URL) -> ApprovalExplanations? {
        guard (!hasServerSelection || server == activeServer), let entry = entries[server],
              entry.enabled, entry.connection != nil else { return nil }
        return entry.explanations
    }

    func activate(server: URL?) {
        activeServer = server
        hasServerSelection = true
        for (key, entry) in entries where key != server { entry.explanations?.pauseAll() }
        if server == nil {
            for entry in entries.values { entry.explanations?.cancelAll() }
            entries.removeAll()
        }
    }

    /// Compare the full saved connection in memory, never credentials in a string key.
    /// Recreate its consumer when credentials/headers change, retaining approval states.
    func refresh(server: URL, store: BotConnectionStore? = nil, defaults: UserDefaults = .standard) {
        let store = store ?? BotConnectionStore()
        let enabled = ApprovalExplanationSetting.isEnabled(server: server, defaults: defaults)
        let connection = (try? store.load(server: server)) ?? nil
        let prior = entries[server]
        if let prior, prior.connection == connection, prior.enabled == enabled { return }
        var explanations = prior?.explanations
        if enabled, let connection {
            let (explain, release) = makeExplain(connection, server)
            if let explanations { explanations.replaceTransport(explain: explain, release: release) }
            else { explanations = ApprovalExplanations(explain: explain, release: release) }
        } else {
            explanations?.pauseAll()
        }
        entries[server] = Entry(connection: connection, enabled: enabled, explanations: explanations)
    }

    /// Attach to the saved connection's shared socket. The controller owns one 20-second
    /// deadline across attachment and RPC; the gateway's normal transport guard remains.
    private static func liveExplain(connection: BotConnection, server: URL)
        -> (ApprovalExplanations.Explain, @MainActor () -> Void) {
        let client = BotClient(saved: connection, server: server)
        return explain(using: client)
    }

    /// Also used by scripted transport tests of attachment cancellation and timeout.
    static func explain(using client: BotClient)
        -> (ApprovalExplanations.Explain, @MainActor () -> Void) {
        var attaching: Task<Void, Error>?
        let explain: ApprovalExplanations.Explain = { input in
            if !client.isAttached {
                let attach = attaching ?? Task { @MainActor in try await client.connect() }
                attaching = attach
                defer { attaching = nil }
                try await attach.value
            }
            try Task.checkCancellation()
            return try await explanation(input, over: client)
        }
        return (explain, { attaching?.cancel(); attaching = nil; client.close() })
    }

    static func explanation(_ input: String, over transport: any BotTransport) async throws -> String {
        let reply = try await transport.call(.approvalExplanation(input: input), validateDispatch: nil)
        guard let text = reply["text"].text else { throw BotFailure.unsupported }
        return text
    }
}
