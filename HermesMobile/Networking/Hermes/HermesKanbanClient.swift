import Foundation

/// Kanban on a Hermes host (#1043): the host's Kanban plugin under `/api/plugins/kanban`, read
/// and written (#1044) over the sign-in, cookie jar and headers (#898) the server's Bot screens
/// share. It reads configuration, Boards, a Board, stats, assignee history, Card detail and the
/// worker log, writes Cards, comments, prerequisites, Bulk Actions, the Dispatcher and Boards,
/// and adapts each reply to the Kanban models webui fills:
/// - host paths and process data (`workspace_path`, `stored_path`, a log's `path`, `db_path`,
///   `default_workdir`, an archived Board's `new_path`, `worker_pid`, `claim_lock`) are dropped
///   before decoding, so no view or log can show them;
/// - every reply reads `read_only: false`, because the host has no read-only mode;
/// - the Assigned Profile filter runs here, because the host's `/board` takes none;
/// - block and unblock are Status changes, a prerequisite reply is filled with the request's
///   ids, because the host echoes none, and a 400 or 409 throws `KanbanWriteRefusal` with
///   the host's `detail`.
///
/// A 404 on `/config` is a host without the Kanban plugin. Live updates come over the Board's
/// Kanban socket (`KanbanWebSocketEventClient`, #1045). The host has no REST events route, so
/// `kanbanEvents` throws; the feature state's polling fallback reloads the Board instead, and
/// a `since` request reads as unchanged while the Board's `latest_event_id` still equals it.
struct HermesKanbanClient: KanbanDataClient {
    let http: HermesConnection

    var backend: KanbanBackend { .hermes }

    @MainActor func makeEventStream(server: URL) -> any KanbanEventStreamingClient {
        KanbanWebSocketEventClient(http: http)
    }

    func kanbanConfiguration() async throws -> KanbanConfiguration {
        do {
            return try await read(.kanbanConfig)
        } catch BotFailure.rejected(404) {
            throw KanbanCapabilityError.kanbanUnavailable
        }
    }

    func kanbanBoards() async throws -> KanbanBoardsResponse {
        try await read(.kanbanBoards)
    }

    func kanbanBoard(_ request: KanbanBoardRequest) async throws -> KanbanBoardSnapshot {
        let snapshot: KanbanBoardSnapshot = try await read(.kanbanBoard(
            board: request.board,
            tenant: request.tenant,
            includeArchived: request.includeArchived
        ))
        // The host's `/board` takes no `since`, so the reply's `latest_event_id` answers it the
        // way webui's `changed` does: a poll or a foreground check keeps an unchanged Board.
        let changed = request.since.map { $0 != snapshot.latestEventID } ?? snapshot.changed
        let assignee = request.assignee.flatMap { $0.isEmpty ? nil : $0 }
        guard assignee != nil || changed != snapshot.changed else { return snapshot }
        return KanbanBoardSnapshot(
            columns: assignee.map { assignee in
                snapshot.columns?.map { column in
                    KanbanColumn(name: column.name, cards: column.cards?.filter { $0.assignee == assignee })
                }
            } ?? snapshot.columns,
            tenants: snapshot.tenants,
            assignees: snapshot.assignees,
            filters: snapshot.filters,
            changed: changed,
            latestEventID: snapshot.latestEventID,
            readOnly: snapshot.readOnly
        )
    }

    func kanbanStats(board: String) async throws -> KanbanStats {
        try await read(.kanbanStats(board: board))
    }

    func kanbanAssignees(board: String) async throws -> KanbanAssigneeHistory {
        try await read(.kanbanAssignees(board: board))
    }

    func kanbanEvents(_ request: KanbanEventsRequest) async throws -> KanbanEventsEnvelope {
        throw BotFailure.unsupported
    }

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async throws -> KanbanCardDetailEnvelope {
        try await read(.kanbanTask(id: request.cardID, board: request.board))
    }

    func kanbanWorkerLog(_ request: KanbanWorkerLogRequest) async throws -> KanbanWorkerLog {
        try await read(.kanbanTaskLog(
            id: request.cardID,
            board: request.board,
            tailBytes: min(max(1, request.tailBytes), 2_000_000)
        ))
    }

    func createKanbanCard(_ request: KanbanCreateCardRequest) async throws -> KanbanCardMutationEnvelope {
        // `status` would be ignored: the host starts a Card in Triage, To Do or Ready by its own
        // rule. No Assigned Profile is null, because `""` is a 400.
        var body: [String: BotJSON] = [
            "title": .string(request.title),
            "assignee": request.assignee.map(BotJSON.string) ?? .null,
            "triage": .bool(request.status == "triage"),
            "idempotency_key": .string(request.idempotencyKey)
        ]
        body["body"] = request.body.map(BotJSON.string)
        body["tenant"] = request.tenant.map(BotJSON.string)
        body["priority"] = request.priority.map { .number(Double($0)) }
        body["workspace_kind"] = request.workspaceKind.map(BotJSON.string)
        body["parents"] = request.prerequisiteID.map { .array([.string($0)]) }
        body["skills"] = request.skills.map { .array($0.map(BotJSON.string)) }
        body["max_runtime_seconds"] = request.maxRuntimeSeconds.map { .number(Double($0)) }
        return try await write(.kanbanCreateTask(board: request.board, body: body))
    }

    /// Never sends `tenant`, which the host can't change after create. An unassigned Card is
    /// `""`, because null leaves the assignee as it is.
    func editKanbanCard(_ request: KanbanEditCardRequest) async throws -> KanbanCardMutationEnvelope {
        var body: [String: BotJSON] = [
            "title": .string(request.title),
            "body": .string(request.body),
            "priority": .number(Double(request.priority))
        ]
        if request.changesAssignee { body["assignee"] = .string(request.assignee ?? "") }
        body["status"] = request.status.map(BotJSON.string)
        return try await write(.kanbanUpdateTask(id: request.cardID, board: request.board, body: body))
    }

    func setKanbanCardStatus(_ request: KanbanCardStatusRequest) async throws -> KanbanCardMutationEnvelope {
        guard request.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "running" else {
            throw KanbanRequestError.runningStatusRequiresDispatcher
        }
        return try await write(.kanbanUpdateTask(id: request.cardID, board: request.board,
                                                 body: ["status": .string(request.status)]))
    }

    /// Blocked is a Status here, which the host may turn into Triage after repeat blocks.
    func blockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope {
        var body: [String: BotJSON] = ["status": .string("blocked")]
        body["block_reason"] = request.reason.map(BotJSON.string)
        return try await write(.kanbanUpdateTask(id: request.cardID, board: request.board, body: body))
    }

    /// Ready from Blocked unblocks, landing the Card in Ready, To Do or Review by the host's rule.
    func unblockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope {
        try await write(.kanbanUpdateTask(id: request.cardID, board: request.board, body: ["status": .string("ready")]))
    }

    func addKanbanComment(_ request: KanbanAddCommentRequest) async throws -> KanbanAddCommentResponse {
        try await write(.kanbanComment(id: request.cardID, board: request.board, body: request.body))
    }

    func addKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope {
        try await write(.kanbanLink(board: request.board, parent: request.prerequisiteID, child: request.dependentID),
                        echoing: request)
    }

    func removeKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope {
        try await write(.kanbanUnlink(board: request.board, parent: request.prerequisiteID, child: request.dependentID),
                        echoing: request)
    }

    /// The same body webui takes: an unassigned Card is `""`, and only Archive sends `archive`.
    func performKanbanBulkAction(_ request: KanbanBulkActionRequest) async throws -> KanbanBulkActionEnvelope {
        var body: [String: BotJSON] = ["ids": .array(request.cardIDs.map(BotJSON.string))]
        switch request.action {
        case .changeStatus(let status): body["status"] = .string(status)
        case .assignProfile(let profile): body["assignee"] = .string(profile ?? "")
        case .setPriority(let priority): body["priority"] = .number(Double(priority))
        case .archiveCards: body["archive"] = .bool(true)
        }
        return try await write(.kanbanBulk(board: request.board, body: body))
    }

    func dispatchKanban(_ request: KanbanDispatchRequest) async throws -> KanbanDispatchResult {
        let result: KanbanDispatchResult = try await write(.kanbanDispatch(board: request.board, dryRun: request.dryRun))
        guard result.hasKnownCategory else { throw KanbanDispatchResponseError.missingResultCategories }
        return result
    }

    func createKanbanBoard(_ request: KanbanCreateBoardRequest) async throws -> KanbanBoardMutationEnvelope {
        try await write(.kanbanCreateBoard(body: [
            "slug": .string(request.slug), "name": .string(request.name), "description": .string(request.description),
            "icon": .string(request.icon), "color": .string(request.color)
        ]))
    }

    func editKanbanBoard(_ request: KanbanEditBoardRequest) async throws -> KanbanBoardMutationEnvelope {
        try await write(.kanbanEditBoard(slug: request.slug, body: [
            "name": .string(request.name), "description": .string(request.description),
            "icon": .string(request.icon), "color": .string(request.color)
        ]))
    }

    func archiveKanbanBoard(_ request: KanbanBoardMutationRequest) async throws -> KanbanBoardMutationEnvelope {
        try await write(.kanbanArchiveBoard(slug: request.slug))
    }

    func makeKanbanBoardActive(_ request: KanbanBoardMutationRequest) async throws -> KanbanBoardMutationEnvelope {
        try await write(.kanbanSwitchBoard(slug: request.slug))
    }

    private func read<Response: Decodable>(_ rest: HermesREST) async throws -> Response {
        try Self.decoded(try Self.adapted(try await http.data(rest)))
    }

    /// Sends a write and decodes a 2xx reply. A prerequisite write passes its request as `echo`:
    /// the host names neither Card, so the reply is filled with them, and its 200 means the
    /// link is now there or gone. A 400 or 409 whose body has a `detail` throws
    /// `KanbanWriteRefusal` with it; any other status throws `BotFailure.rejected`, as a read does.
    private func write<Response: Decodable>(
        _ rest: HermesREST,
        echoing echo: KanbanDependencyMutationRequest? = nil
    ) async throws -> Response {
        let reply = try await http.reply(rest)
        guard (200..<300).contains(reply.status) else {
            let detail = (try? JSONDecoder().decode(BotJSON.self, from: reply.body))?["detail"].text
            if reply.status == 400 || reply.status == 409, let detail, !detail.isEmpty {
                throw KanbanWriteRefusal(status: reply.status, message: detail)
            }
            throw BotFailure.rejected(reply.status)
        }
        let filled: [String: Any] = echo.map { ["ok": true, "parent_id": $0.prerequisiteID, "child_id": $0.dependentID] } ?? [:]
        return try Self.decoded(try Self.adapted(reply.body, filling: filled))
    }

    private static func decoded<Response: Decodable>(_ data: Data) throws -> Response {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }

    /// Keys whose values are host paths or process data, dropped at every depth.
    static let hostOnlyKeys: Set<String> = [
        "workspace_path", "stored_path", "path", "db_path", "default_workdir", "new_path", "worker_pid", "claim_lock"
    ]

    /// A reply without `hostOnlyKeys`, marked writable, with `filling`'s top-level keys set.
    /// `JSONSerialization` keeps the host's integers integers on the way back out. A body that
    /// is not a JSON object is an incompatible reply.
    static func adapted(_ data: Data, filling: [String: Any] = [:]) throws -> Data {
        guard var reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw KanbanResponseError.nonJSONContentType
        }
        reply = reply.filter { !hostOnlyKeys.contains($0.key) }.mapValues(withoutHostOnlyKeys)
        reply.merge(filling) { _, fill in fill }
        reply["read_only"] = false
        return try JSONSerialization.data(withJSONObject: reply)
    }

    private static func withoutHostOnlyKeys(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.filter { !hostOnlyKeys.contains($0.key) }.mapValues(withoutHostOnlyKeys)
        case let array as [Any]:
            return array.map(withoutHostOnlyKeys)
        default:
            return value
        }
    }
}

/// A socket `KanbanWebSocketEventClient` reads: the gateway's socket boundary and a WebSocket
/// ping. Production wraps `URLSessionWebSocketTask` (`NativeBotSocket`); tests script one.
protocol KanbanSocket: BotSocket {
    /// Sends one ping frame and returns when its pong arrives. A refused upgrade throws what
    /// `receive()` throws for it.
    func ping() async throws
    var closeCode: Int { get }
}

extension KanbanSocket { var closeCode: Int { 0 } }

extension NativeBotSocket: KanbanSocket {
    var closeCode: Int { task.closeCode.rawValue }
    func ping() async throws {
        let task = task
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            if let status = (task.response as? HTTPURLResponse)?.statusCode, let refusal = BotFailure(upgradeStatus: status) {
                throw refusal
            }
            throw error
        }
    }
}

/// Ticketed plugin sockets share admission, keepalive and fresh-ticket recovery.
@MainActor final class PluginWebSocketClient {
    struct Options {
        var keepalive: Duration = .seconds(25)
        var sleep: @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var socketFactory: ((URLRequest) -> any KanbanSocket)?
    }

    private let http: HermesConnection
    private let name: String
    private let options: Options
    private var upgrade: (() async throws -> URLRequest)?
    private var onOpen: (() async -> Void)?
    private var onMessage: ((URLSessionWebSocketTask.Message) async -> Void)?
    private var onFailure: ((Error, Int) async -> Void)?
    private var mayRetryRefusal = false
    private var generation = 0
    private var socket: (any KanbanSocket)?
    private var opener: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var input: AsyncStream<URLSessionWebSocketTask.Message>.Continuation?
    private var isOpen = false
    private var awaitingPong = false

    init(http: HermesConnection, name: String, options: Options = Options()) {
        self.http = http; self.name = name; self.options = options
    }

    deinit {
        opener?.cancel(); reader?.cancel(); writer?.cancel(); keepalive?.cancel(); pingTask?.cancel()
        input?.finish(); socket?.cancel()
    }

    func start(upgrade: @escaping () async throws -> URLRequest, onOpen: @escaping () async -> Void,
               onMessage: @escaping (URLSessionWebSocketTask.Message) async -> Void,
               onFailure: @escaping (Error, Int) async -> Void) {
        stop()
        self.upgrade = upgrade; self.onOpen = onOpen; self.onMessage = onMessage; self.onFailure = onFailure
        mayRetryRefusal = true
        connect()
    }

    func stop() {
        close()
        upgrade = nil; onOpen = nil; onMessage = nil; onFailure = nil
    }

    private func connect() {
        guard let upgrade else { return }
        let owner = generation
        opener = Task { [weak self] in
            do { let request = try await upgrade(); self?.open(request, owner: owner) }
            catch { self?.fail(error, owner: owner) }
        }
    }

    private func open(_ request: URLRequest, owner: Int) {
        guard owner == generation else { return }
        guard !http.isRetired else { fail(BotFailure.stale, owner: owner); return }
        let socket: any KanbanSocket
        if let factory = options.socketFactory { socket = factory(request) } else {
            let task = http.session.webSocketTask(with: request)
            task.maximumMessageSize = 16 * 1024 * 1024
            task.resume()
            socket = NativeBotSocket(task: task, label: label(owner))
        }
        self.socket = socket
        let stream = AsyncStream<URLSessionWebSocketTask.Message>.makeStream()
        input = stream.continuation
        writer = Task { [weak self] in
            for await message in stream.stream {
                guard self?.generation == owner else { return }
                do { try await socket.send(message) } catch { self?.fail(error, owner: owner); return }
            }
        }
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.generation == owner else { return }
                    try await self.markAlive()
                    await self.onMessage?(message)
                }
            } catch { self?.fail(error, owner: owner) }
        }
        let sleep = options.sleep, interval = options.keepalive
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard let self, self.generation == owner else { return }
                if self.awaitingPong { self.fail(BotFailure.transport, owner: owner); return }
                self.ping(socket, owner: owner)
            }
        }
        ping(socket, owner: owner)
    }

    private func ping(_ socket: any KanbanSocket, owner: Int) {
        awaitingPong = true
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            do {
                try await socket.ping()
                guard let self, self.generation == owner, !Task.isCancelled else { return }
                self.pingTask = nil
                try await self.markAlive()
            } catch {
                if !Task.isCancelled { self?.fail(error, owner: owner) }
            }
        }
    }

    private func markAlive() async throws {
        guard !http.isRetired else { throw BotFailure.stale }
        awaitingPong = false
        guard !isOpen else { return }
        isOpen = true; mayRetryRefusal = false
        HermesConnectionLog.logger.notice("\(self.label(self.generation), privacy: .public) open")
        await onOpen?()
    }

    func send(_ message: URLSessionWebSocketTask.Message) {
        guard isOpen, !http.isRetired else { return }
        input?.yield(message)
    }

    private func fail(_ error: Error, owner: Int) {
        guard owner == generation else { return }
        let retry = mayRetryRefusal && error as? BotFailure == .upgradeRefused(403)
        let code = socket?.closeCode ?? 0
        let name = label(owner), reason = HermesConnectionLog.reason(error)
        close()
        if retry { mayRetryRefusal = false; connect(); return }
        HermesConnectionLog.logger.error("\(name, privacy: .public) failed: \(reason, privacy: .public)")
        let callback = onFailure
        stop()
        let reported = generation
        Task { [weak self] in
            guard self?.generation == reported else { return }
            await callback?(error, code)
        }
    }

    private func close() {
        generation += 1
        opener?.cancel(); opener = nil
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        keepalive?.cancel(); keepalive = nil
        pingTask?.cancel(); pingTask = nil
        input?.finish(); input = nil
        socket?.cancel(); socket = nil
        isOpen = false; awaitingPong = false
    }

    private func label(_ number: Int) -> String { "c\(http.serial) \(name) socket s\(number)" }
}

@MainActor final class KanbanWebSocketEventClient: KanbanEventStreamingClient {
    typealias Options = PluginWebSocketClient.Options
    private let http: HermesConnection
    private let socket: PluginWebSocketClient
    init(http: HermesConnection, options: Options = Options()) {
        self.http = http; socket = PluginWebSocketClient(http: http, name: "kanban", options: options)
    }
    func start(board: String, since: Int, onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
               onFailure: @escaping @MainActor () -> Void) {
        socket.start(upgrade: { [http] in try await http.kanbanEventsUpgrade(board: board, since: since) },
                     onOpen: { onFrame(.opened) }, onMessage: { message in
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: return
            }
            onFrame(KanbanStreamFrameDecoder.decodeSocketFrame(data))
        }, onFailure: { _, _ in onFailure() })
    }
    func stop() { socket.stop() }
}
