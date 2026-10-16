import Foundation

/// Voice mode's rules and routes on the Hermes layer. The voice RPCs are typed
/// `HermesCall` cases (`voiceSessionCreate`, `voiceSessionResume`,
/// `voicePromptSubmit`, `voiceLivePromptSubmit`; steer, interrupt, approvals and answers use
/// the shared cases) and the HTTP routes are `HermesREST` cases sent over the connection's
/// signed-in session. Voice chats are ordinary visible Hermes chats, so they get their own
/// narrow shapes instead of widening the Bot Chat ones:
///
/// - `session.create` exactly `{hidden: false}`: no title (Hermes derives one) and no
///   profile, so the dashboard's own launch profile (its voice config, key and the
///   ariex-voice plugin) owns the chat.
/// - `prompt.submit` with `interrupted` only as `{session_id, text, interrupted}`, a Bool.
/// - never `session.close`: End leaves the socket, so the chat's turn, subagents and
///
/// The companion plugin's voice module marks a
/// session as spoken, transcribes with the session's vocabulary, and keeps the
/// glossary. Speech out is `/api/audio/speak-stream` (fresh `?ticket=` per socket).
enum BotVoiceRPC {

    /// Session keys the plugin accepts (`ariex_voice.valid_session_key`).
    static func isValidSessionKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    static func speakURL(base: URL) -> URL { base.appendingPathComponent("api/audio/speak") }

    /// `ws(s)://…/api/audio/speak-stream?ticket=…`. No `profile`: the dashboard's
    /// own launch profile speaks (its TTS config and key). The route accepts the
    /// socket without selecting a subprotocol, so the ticket rides in the query
    /// (the desktop client does the same), never in `Sec-WebSocket-Protocol`.
    static func speakStreamURL(base: URL, ticket: String) throws -> URL {
        guard !ticket.isEmpty,
              var parts = URLComponents(url: base.appendingPathComponent("api/audio/speak-stream"), resolvingAgainstBaseURL: false)
        else { throw BotFailure.unsupported }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return url
    }

    /// Glossary terms as the plugin stores them: trimmed, non-empty, deduplicated, ≤200.

}

/// What voice mode needs from the dashboard connection: typed calls (`BotTransport.call`)
/// and the voice routes. `BotClient` is the production conformer; tests script it.
@MainActor protocol BotVoiceBackend: BotTransport {
    /// Host transcription (`/api/audio/transcribe`). "" means no speech.
    func transcribeVoice(sessionKey: String, audio: Data, mimeType: String) async throws -> String
    /// Whole-reply clip for the speak-stream `fallback`; returns audio bytes.
    func speakClip(_ text: String) async throws -> Data
    /// A new speak-stream socket, authenticated with a fresh single-use ticket.
    func openSpeakStream() async throws -> any BotSocket
}

extension BotVoiceBackend {
    /// Decodes a `data:<mime>;base64,<bytes>` URL; nil for anything else.
    static func decodeDataURL(_ text: String) -> Data? {
        guard text.hasPrefix("data:"), let comma = text.firstIndex(of: ","),
              text[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(text[text.index(after: comma)...]))
    }
}
