import Foundation

/// Dashboard gateway frames (`/api/ws` events of one voice turn) as the chat's stream
/// events, so the voice screen's live turn is built by the chat's own `ChatTurnLiveFold`.
/// Pure: the same frame always gives the same events.
///
/// | gateway event | `SSEEvent` |
/// |---|---|
/// | `message.delta {text}` | `.token` |
/// | `reasoning.delta {text}` | `.reasoning` |
/// | `thinking.delta {text}` | nothing: the spinner's status text ("(°□°) reflecting..."), not reasoning (`BotConversation` shows it as status) |
/// | `message.interim {text, already_streamed}` | `.interimAssistant` |
/// | `tool.start {tool_id, name, context, preview, args}` | `.toolStarted` (stable id = `tool_id`) |
/// | `tool.complete {tool_id, name, duration_s}` | `.toolCompleted` |
/// | `message.complete {status, text}` | `complete` → `.done` (text first when nothing streamed), `interrupted` → `.cancelled`, `error` → `.error` |
enum VoiceTurnMapper {
    static func events(type: String, payload: BotJSON, streamedReply: Bool) -> [SSEEvent] {
        switch type {
        case "message.delta":
            guard let text = payload["text"].text, !text.isEmpty else { return [] }
            return [.token(text)]
        case "reasoning.delta":
            guard let text = payload["text"].text, !text.isEmpty else { return [] }
            return [.reasoning(text)]
        case "message.interim":
            guard let text = payload["text"].text, !text.isEmpty else { return [] }
            return [.interimAssistant(InterimAssistantStreamEvent(text: text, alreadyStreamed: payload["already_streamed"].flag))]
        case "tool.start":
            return [.toolStarted(tool(payload, eventType: type))]
        case "tool.complete":
            return [.toolCompleted(tool(payload, eventType: type))]
        case "message.complete":
            switch payload["status"].text {
            case "interrupted":
                return [.cancelled]
            case "error":
                return [.error(payload["text"].text ?? "")]
            default:
                var events: [SSEEvent] = []
                if !streamedReply, let text = payload["text"].text, !text.isEmpty { events.append(.token(text)) }
                events.append(.done(DoneStreamEvent()))
                return events
            }
        default:
            return []
        }
    }

    private static func tool(_ payload: BotJSON, eventType: String) -> ToolStreamEvent {
        let preview = [payload["context"].text, payload["preview"].text, payload["summary"].text]
            .compactMap { $0 }.first { !$0.isEmpty }
        return ToolStreamEvent(
            eventType: eventType,
            name: payload["name"].text,
            preview: eventType == "tool.start" ? preview : nil,
            args: payload["args"].argumentDictionary,
            duration: payload["duration_s"].number,
            isError: payload["is_error"].flag ?? (payload["error"].text?.isEmpty == false ? true : nil),
            stableID: payload["tool_id"].text.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
