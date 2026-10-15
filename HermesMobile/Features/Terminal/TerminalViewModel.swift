import Foundation
import Observation

@MainActor protocol TerminalDisplay: AnyObject {
    func reset()
    func feed(_ data: ArraySlice<UInt8>)
}

@MainActor @Observable final class TerminalViewModel {
    enum State: Equatable { case paused, connecting, connected, failed(HermesTerminalFailure) }
    private(set) var state = State.paused
    @ObservationIgnored weak var display: (any TerminalDisplay)?
    @ObservationIgnored private let client: HermesTerminalClient
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var size = TerminalSize()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var hasAttached = false
    @ObservationIgnored private var healthySince: Date?
    @ObservationIgnored private var needsReset = false
    @ObservationIgnored private var unseen: Int?
    @ObservationIgnored private(set) var feedingHistory = false

    init(client: HermesTerminalClient, now: @escaping () -> Date = Date.init,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client; self.sleep = sleep; self.now = now
    }

    deinit { recovery?.cancel() }

    func attach(_ display: any TerminalDisplay) {
        self.display = display
        if active { connect(checkStatus: hasAttached) }
    }

    func activate() {
        guard !active else { return }
        active = true
        if case .failed(let failure) = state, !failure.canReconnect { return }
        connect(checkStatus: hasAttached)
    }

    func suspend() {
        active = false
        generation += 1
        recovery?.cancel(); recovery = nil
        client.stop()
        if state == .connected || state == .connecting { state = .paused }
    }

    func reconnect() {
        attempt = 0
        connect(checkStatus: false)
    }

    private func connect(checkStatus: Bool) {
        guard active, display != nil else { return }
        generation += 1
        let owner = generation
        recovery?.cancel()
        client.stop()
        state = .connecting
        unseen = nil; healthySince = nil; needsReset = true
        if checkStatus {
            recovery = Task { [weak self, client] in
                do {
                    let running = try await client.status()
                    guard let self, self.active, self.generation == owner, !Task.isCancelled else { return }
                    if running == false { self.state = .failed(.exited) }
                    else { self.start(owner: owner) }
                } catch {
                    guard let self, self.active, self.generation == owner, !Task.isCancelled else { return }
                    self.failed(.read(error, closeCode: 0), owner: owner)
                }
            }
        } else { start(owner: owner) }
    }

    private func start(owner: Int) {
        client.start(size: size) { [weak self] event in
            guard let self, self.active, self.generation == owner, !Task.isCancelled else { return }
            switch event {
            case .opened:
                self.state = .connected; self.hasAttached = true
                self.client.send(self.size.frame)
            case .replayStarted(let unseen):
                self.display?.reset(); self.needsReset = false; self.unseen = unseen
            case .replayEnded:
                self.unseen = nil; self.healthySince = self.now()
            case .output(let data):
                if self.needsReset { self.display?.reset(); self.needsReset = false }
                // The server sends its bounded replay in one binary frame, followed by live frames.
                let suppressed = self.unseen.map { max(0, data.count - $0) } ?? 0
                let bytes = Array(data)
                var offset = 0
                while offset < bytes.count {
                    guard self.active, self.generation == owner, !Task.isCancelled else { return }
                    let boundary = offset < suppressed ? suppressed : bytes.count
                    let end = min(boundary, offset + 16384)
                    self.feedingHistory = offset < suppressed
                    self.display?.feed(bytes[offset..<end])
                    self.feedingHistory = false
                    offset = end
                    if offset < bytes.count { await Task.yield() }
                }
            case .failed(let failure): self.failed(failure, owner: owner)
            }
        }
    }

    private func failed(_ failure: HermesTerminalFailure, owner: Int) {
        if let healthySince, now().timeIntervalSince(healthySince) >= 5 { attempt = 0 }
        state = .failed(failure)
        guard failure.canReconnect, attempt < 6 else { return }
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
        let delay = delays[attempt]
        attempt += 1
        recovery = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let self, self.active, self.generation == owner, !Task.isCancelled else { return }
            self.connect(checkStatus: self.hasAttached)
        }
    }

    func resize(columns: Int, rows: Int) {
        size = TerminalSize(columns: columns, rows: rows)
        if state == .connected { client.send(size.frame) }
    }

    func send(_ data: Data) {
        guard state == .connected, !feedingHistory else { return }
        client.send(.data(data))
    }

    var isReplaying: Bool { unseen != nil }

    var message: String {
        switch state {
        case .paused: String(localized: "Paused")
        case .connecting: String(localized: "Connecting…")
        case .connected: String(localized: "Connected")
        case .failed(.exited): String(localized: "Shell exited")
        case .failed(.replaced): String(localized: "Shell opened elsewhere")
        case .failed(.refused): String(localized: "Terminal connection refused. Check your Hermes sign-in and host policy.")
        case .failed(.connection(let failure)): BotConnectionAdvice.message(for: failure, address: client.target.server)
        case .failed(.lost): String(localized: "Connection lost")
        }
    }
}
