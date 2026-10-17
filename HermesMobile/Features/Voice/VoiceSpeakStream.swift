import Foundation

/// One reply's speech over `/api/audio/speak-stream`: text frames in, int16 PCM out.
/// Frames: client `{"text"}`, `{"done":true}`, `{"stop":true}`; server
/// `{"type":"start","sample_rate","channels"}`, binary PCM, `{"type":"end"}` or
/// `{"type":"fallback"}` (`hermes_cli/web_routers/audio.py speak_stream_ws`).
@MainActor final class VoiceSpeakStream {
    enum Event: Equatable {
        case start(sampleRate: Int, channels: Int)
        case pcm(Data)
        case end
        case fallback
        case failed
    }

    private let socket: any BotSocket
    private var reader: Task<Void, Never>?
    private(set) var sentText = ""
    private(set) var finished = false
    private(set) var stopped = false
    var onEvent: ((Event) -> Void)?

    init(socket: any BotSocket) { self.socket = socket }

    func start() {
        let socket = self.socket
        reader = Task { [weak self] in
            while !Task.isCancelled {
                let frame: URLSessionWebSocketTask.Message
                do { frame = try await socket.receive() } catch {
                    self?.deliver(.failed); return
                }
                guard let self else { return }
                switch frame {
                case .data(let pcm): self.deliver(.pcm(pcm))
                case .string(let text):
                    guard let json = try? JSONDecoder().decode(BotJSON.self, from: Data(text.utf8)) else { continue }
                    switch json["type"].text {
                    case "start":
                        self.deliver(.start(sampleRate: json["sample_rate"].integer ?? 24000, channels: json["channels"].integer ?? 1))
                    case "end": self.deliver(.end); return
                    case "fallback": self.deliver(.fallback); return
                    default: continue
                    }
                @unknown default: continue
                }
            }
        }
    }

    private func deliver(_ event: Event) {
        guard !stopped else { return }
        if event == .end || event == .fallback || event == .failed { finished = true }
        onEvent?(event)
    }

    func send(text: String) {
        guard !stopped, !text.isEmpty else { return }
        sentText += text
        transmit(.object(["text": .string(text)]))
    }

    func done() {
        guard !stopped else { return }
        doneSent = true
        transmit(.object(["done": .bool(true)]))
    }
    private(set) var doneSent = false

    /// Barge-in: nothing more is delivered after this.
    func stop() {
        guard !stopped else { return }
        stopped = true
        transmit(.object(["stop": .bool(true)]))
        reader?.cancel()
        let socket = self.socket
        let pending = sendChain
        Task { await pending?.value; socket.cancel() }
    }

    func close() {
        stopped = true
        reader?.cancel()
        socket.cancel()
    }

    /// Frames go out strictly in order: each send waits for the previous one.
    private var sendChain: Task<Void, Never>?

    private func transmit(_ json: BotJSON) {
        guard let data = try? JSONEncoder().encode(json) else { return }
        let text = String(decoding: data, as: UTF8.self)
        let socket = self.socket
        let previous = sendChain
        sendChain = Task { await previous?.value; try? await socket.send(.string(text)) }
    }
}
