import Foundation
import LDSwiftEventSource

/// One event from `GET /api/terminal/output`.
enum TerminalStreamEvent: Equatable {
    /// PTY output. `seq` is the SSE `id:` sequence number (nil if the server sent none).
    case output(text: String, seq: Int?)
    /// The shell exited; the server then ends the stream.
    case closed(exitCode: Int?)
    /// The server reported a terminal error; the stream then ends.
    case serverError(String)
    /// 404 on connect: no terminal is running for this chat.
    case gone
    /// The connection dropped (network, idle proxy, backgrounding). The caller
    /// decides whether and when to reconnect.
    case disconnected(String?)
    case ignored
}

enum TerminalStreamEventDecoder {
    static func decode(eventType: String, data: String, lastEventID: String?) -> TerminalStreamEvent {
        let json = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any]
        switch eventType {
        case "output":
            guard let text = json?["text"] as? String else { return .ignored }
            let seq = lastEventID.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return .output(text: text, seq: seq)
        case "terminal_closed":
            let code = (json?["exit_code"] as? NSNumber)?.intValue
            return .closed(exitCode: code)
        case "terminal_error":
            return .serverError((json?["error"] as? String) ?? "Terminal error")
        default:
            return .ignored
        }
    }
}

/// Seam over the output stream so the session controller can be tested with a
/// scripted stream.
@MainActor
protocol TerminalOutputStreaming: AnyObject {
    /// Opens the stream. `lastEventID` is sent as `Last-Event-ID` so a reconnect
    /// only replays output newer than what was already rendered.
    func start(url: URL, lastEventID: String?, onEvent: @escaping @MainActor (TerminalStreamEvent) -> Void)
    func stop()
}

/// Terminal output SSE client, configured like `SSEClient` (shared cookies,
/// custom headers, `Accept-Encoding: identity`). Unlike `SSEClient` it never lets
/// LDSwiftEventSource retry on its own: every drop is reported once as
/// `.disconnected` (or `.gone` for a 404) and the controller owns retry/backoff,
/// so each reconnect carries the controller's own last rendered seq.
@MainActor
final class TerminalOutputStream: TerminalOutputStreaming {
    private let baseConfiguration: URLSessionConfiguration
    private let customHeaderProvider: @MainActor () -> [CustomHeader]
    private var eventSource: EventSource?
    private var generation = 0

    init(
        urlSessionConfiguration: URLSessionConfiguration = .default,
        customHeaderProvider: @escaping @MainActor () -> [CustomHeader] = { CustomHeaderStore.shared.snapshot() }
    ) {
        baseConfiguration = urlSessionConfiguration
        self.customHeaderProvider = customHeaderProvider
    }

    func start(url: URL, lastEventID: String?, onEvent: @escaping @MainActor (TerminalStreamEvent) -> Void) {
        stop()
        generation += 1
        let current = generation
        // Deliver at most one terminal event (end/drop) per connection, and nothing
        // once a newer connection or stop() has replaced this one.
        var finished = false
        let deliver: @MainActor (TerminalStreamEvent) -> Void = { [weak self] event in
            guard let self, self.generation == current, !finished else { return }
            switch event {
            case .closed, .serverError, .gone, .disconnected:
                finished = true
                self.stop()
            default:
                break
            }
            onEvent(event)
        }

        var config = EventSource.Config(handler: TerminalEventHandler(deliver: deliver), url: url)
        config.connectionErrorHandler = { error in
            let code = (error as? UnsuccessfulResponseError)?.responseCode
            Task { @MainActor in
                deliver(code == 404 ? .gone : .disconnected(code.map { "HTTP \($0)" } ?? error.localizedDescription))
            }
            return .shutdown
        }
        if let lastEventID, !lastEventID.isEmpty {
            config.lastEventId = lastEventID
        }
        config.headers = customHeaderProvider().merged(under: [
            "Accept": "text/event-stream",
            "Cache-Control": "no-cache, no-transform",
            "Accept-Encoding": "identity"
        ])
        let configuration = baseConfiguration.copy() as? URLSessionConfiguration ?? .default
        configuration.httpCookieStorage = .shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlSessionConfiguration = configuration

        let source = EventSource(config: config)
        eventSource = source
        source.start()
    }

    func stop() {
        generation += 1
        eventSource?.stop()
        eventSource = nil
    }
}

private final class TerminalEventHandler: EventHandler, @unchecked Sendable {
    private let deliver: @MainActor (TerminalStreamEvent) -> Void

    init(deliver: @escaping @MainActor (TerminalStreamEvent) -> Void) {
        self.deliver = deliver
    }

    func onOpened() {}

    /// A normal end of stream (server closed, proxy idle cut). LDSwiftEventSource
    /// would reconnect on its own; the deliver closure stops it and reports the drop.
    func onClosed() {
        Task { @MainActor in deliver(.disconnected(nil)) }
    }

    func onMessage(eventType: String, messageEvent: MessageEvent) {
        let event = TerminalStreamEventDecoder.decode(
            eventType: eventType,
            data: messageEvent.data,
            lastEventID: messageEvent.lastEventId
        )
        guard event != .ignored else { return }
        Task { @MainActor in deliver(event) }
    }

    func onComment(comment _: String) {}

    func onError(error _: Error) {}
}
