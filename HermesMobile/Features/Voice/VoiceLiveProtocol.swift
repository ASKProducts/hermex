import Foundation

/// GPT-Live wire rules (events, append chunking, history, text cleaned for speech), free of
/// WebRTC so every rule is unit-tested. They match hermes-agent's desktop client
/// (`apps/desktop/src/lib/voice-live.ts`, `lib/speech-text.ts` `sanitizeTextForSpeech`). Vendor contract:
/// https://developers.openai.com/api/docs/guides/live-delegation
enum VoiceLive {
    /// Vendor cap: 500 tokens per append. ~4 chars/token, keep headroom.
    static let appendCharLimit = 1_400
    static let closeTimeout: TimeInterval = 15
    static let iceGatherTimeout: TimeInterval = 10
    /// Hermes keeps `voice_context[:6000]` (tui_gateway/methods_prompt.py), so the app cuts first,
    /// at a turn boundary, keeping the newest turns.
    static let contextCharLimit = 6_000
    static let contextCutMarker = "[earlier part of the conversation cut]"

    /// How much of the spoken conversation goes to Hermes with each request (Settings → Voice).
    enum ContextMode: Equatable {
        /// Every fragment after the previous request's cut point (the whole session for the first).
        case sinceLastRequest
        /// The last `n` minutes, by time only.
        case lastMinutes(Int)

        /// UserDefaults key; values `"since"`, `"1"`, `"2"`, `"5"`, `"10"`.
        static let defaultsKey = "voice.live.context"
        static let minuteChoices = [1, 2, 5, 10]
        /// The longest window any mode can ask for (the transcript trim keeps at least this much).
        static let longestWindowMs = Double(minuteChoices.max()! * 60_000)

        /// Unknown or missing values fall back to `.sinceLastRequest`.
        init(stored: String?) {
            if let minutes = stored.flatMap(Int.init), Self.minuteChoices.contains(minutes) { self = .lastMinutes(minutes) }
            else { self = .sinceLastRequest }
        }

        var stored: String {
            switch self {
            case .sinceLastRequest: "since"
            case .lastMinutes(let minutes): String(minutes)
            }
        }

        static func current(_ defaults: UserDefaults) -> ContextMode { ContextMode(stored: defaults.string(forKey: defaultsKey)) }
    }

    /// Split a reply into append-sized chunks on sentence boundaries (`chunkForCommentary`).
    static func chunkForCommentary(_ text: String, limit: Int = appendCharLimit) -> [String] {
        let clean = collapse(text)
        guard !clean.isEmpty else { return [] }
        guard clean.count > limit else { return [clean] }
        var chunks: [String] = []
        var current = ""
        for sentence in splitSentences(clean) {
            if sentence.count > limit {
                if !current.isEmpty { chunks.append(current); current = "" }
                var rest = Substring(sentence)
                while !rest.isEmpty { chunks.append(String(rest.prefix(limit))); rest = rest.dropFirst(limit) }
                continue
            }
            let candidate = current.isEmpty ? sentence : current + " " + sentence
            if candidate.count > limit { chunks.append(current); current = sentence } else { current = candidate }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// `clean.split(/(?<=[.!?])\s+/)` on already-collapsed text.
    static func splitSentences(_ clean: String) -> [String] {
        var out: [String] = []
        var current = ""
        var previous: Character?
        for ch in clean {
            if ch == " ", let p = previous, ".!?".contains(p) { out.append(current); current = ""; previous = ch; continue }
            current.append(ch)
            previous = ch
        }
        out.append(current)
        return out
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Live `session.input` accepts 128 messages / 8,192 combined tokens:
    /// https://developers.openai.com/api/docs/guides/live-conversations
    /// 16,000 UTF-8 bytes is roughly 4–5k English tokens, leaving headroom below that token cap.
    static let historyByteLimit = 16_000
    static let historyCutMarker = "[rest of this message cut]"

    /// Seed text turns in chronological order, selecting newest first and dropping oldest whole
    /// messages. Only an oversized newest message keeps its start plus an explicit cut marker.
    /// Keep briefing-sized messages whole while they fit the history byte limit.
    static func history(_ turns: [(role: String, text: String)], maxMessages: Int = 24,
                        maxBytes: Int = historyByteLimit) -> [BotJSON] {
        precondition(maxBytes >= historyCutMarker.utf8.count + 1)
        var out: [BotJSON] = []
        var budget = maxBytes
        for turn in turns.reversed() {
            var text = turn.text
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if out.count >= maxMessages { break }
            let oversized = text.utf8.count > budget
            if oversized {
                guard out.isEmpty else { break }
                var prefixBudget = budget - historyCutMarker.utf8.count - 1
                var prefix = ""
                for character in text {
                    let next = String(character)
                    if next.utf8.count > prefixBudget { break }
                    prefixBudget -= next.utf8.count
                    prefix += next
                }
                text = prefix + "\n" + historyCutMarker
            }
            budget -= text.utf8.count
            let assistant = turn.role == "assistant"
            out.insert(.object(["type": .string("message"), "role": .string(assistant ? "assistant" : "user"),
                                "content": .array([.object(["type": .string(assistant ? "output_text" : "input_text"),
                                                            "text": .string(text)])])]), at: 0)
            if oversized { break }
        }
        return out
    }

    /// The Hermes turn from transcript fragments (`delegationPrompt`): `prompt` is what the user
    /// last said (the stored user row), `context` the recent spoken exchange (model input only).
    static func delegationPrompt(_ context: [Fragment]) -> (prompt: String, context: String) {
        let built = delegationContext(context)
        return (built.prompt, built.context)
    }

    /// Every user turn in `context`, oldest first, one space apart: the prompt for follow-ups
    static func userWords(_ context: [Fragment]) -> String {
        var turns: [(speaker: Fragment.Speaker, text: String)] = []
        for fragment in context {
            if let last = turns.last, last.speaker == fragment.speaker { turns[turns.count - 1].text += fragment.joining(after: last.text) }
            else { turns.append((fragment.speaker, fragment.text)) }
        }
        return turns.filter { $0.speaker == .user }.map { collapse($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `delegationPrompt` plus how many characters of the oldest turns the `contextCharLimit` cut dropped.
    /// The context is at most `contextCharLimit` characters: whole turns, newest kept, and
    /// `contextCutMarker` as the first line when any were dropped (a single newest turn longer
    /// than the limit keeps its end).
    static func delegationContext(_ context: [Fragment]) -> (prompt: String, context: String, trimmedChars: Int) {
        var turns: [(speaker: Fragment.Speaker, text: String)] = []
        for fragment in context {
            if let last = turns.last, last.speaker == fragment.speaker { turns[turns.count - 1].text += fragment.joining(after: last.text) }
            else { turns.append((fragment.speaker, fragment.text)) }
        }
        let prompt = collapse(turns.last(where: { $0.speaker == .user })?.text ?? "")
        let lines = turns.map { "\($0.speaker == .user ? "User" : "Voice assistant"): \(collapse($0.text))" }
            .filter { !$0.hasSuffix(": ") }
        let full = lines.joined(separator: "\n")
        guard full.count > contextCharLimit else { return (prompt.isEmpty ? String(full.suffix(400)) : prompt, full, 0) }
        // Newest first, whole lines, while marker + "\n" + kept lines fit.
        var budget = contextCharLimit - contextCutMarker.count - 1
        var kept: [String] = []
        for line in lines.reversed() {
            let cost = line.count + (kept.isEmpty ? 0 : 1)
            if cost > budget {
                if kept.isEmpty { kept.append(String(line.suffix(budget))) }
                break
            }
            budget -= cost
            kept.insert(line, at: 0)
        }
        let keptText = kept.joined(separator: "\n")
        let transcript = contextCutMarker + "\n" + keptText
        return (prompt.isEmpty ? String(transcript.suffix(400)) : prompt, transcript, full.count - keptText.count)
    }

    struct Fragment: Equatable {
        enum Speaker: String { case user, assistant }
        var speaker: Speaker
        var text: String
        var startMs: Double
        var endMs: Double
        /// First delta of a new output item / response (or utterance) for this speaker. The server
        /// sends no item ids; a new segment's first delta starts after a time gap (`start_ms` past the
        /// previous delta's `end_ms`) and carries no leading space, unlike later deltas of the same
        /// segment ("Okay." then "Lighth" at +1,000 ms; "Lighth" then "ouses" contiguous).
        /// Set by `VoiceLiveEvents`, which sees the whole sequence.
        var startsSegment = false

        /// This delta's text as appended after `previous` of the same speaker: segments are joined
        /// with one space unless the previous text already ends in whitespace (or this starts with it).
        func joining(after previous: String) -> String {
            // Only a finished piece (ends in punctuation) followed by a word: the user's deltas
            // also arrive with gaps between words (" okay" … ", then"), and those carry their own spacing.
            guard startsSegment, let last = previous.last, !last.isWhitespace, !last.isLetter, !last.isNumber,
                  let first = text.first, first.isLetter || first.isNumber else { return text }
            return " " + text
        }
    }

    enum ServerEvent: Equatable {
        case started(sessionID: String?)
        case transcript(Fragment)
        case delegation(id: String)
        case error(code: String, message: String)
        case closed(reason: String, seconds: Double?)
        case other(String)

        /// nil for anything that isn't a JSON object with a `type`.
        static func parse(_ raw: String) -> ServerEvent? {
            guard let data = raw.data(using: .utf8), let json = try? JSONDecoder().decode(BotJSON.self, from: data),
                  let type = json["type"].text else { return nil }
            switch type {
            case "session.started":
                return .started(sessionID: json["session"]["id"].text)
            case "session.input_transcript.delta", "session.output_transcript.delta":
                return .transcript(Fragment(speaker: type == "session.input_transcript.delta" ? .user : .assistant,
                                            text: json["delta"].text ?? "", startMs: json["start_ms"].number ?? 0,
                                            endMs: json["end_ms"].number ?? 0))
            case "session.delegation.created":
                guard let id = json["delegation"]["id"].text, !id.isEmpty else { return .other(type) }
                return .delegation(id: id)
            case "error":
                return .error(code: json["error"]["code"].text ?? "", message: json["error"]["message"].text ?? "GPT-Live error")
            case "session.closed":
                return .closed(reason: json["reason"].text ?? "closed", seconds: json["usage"]["seconds"].number)
            default:
                return .other(type)
            }
        }
    }

    /// `GET /api/audio/voice-live/status` → `{ok, mode, available, reason, model, voice}`.
    struct Status: Equatable {
        var mode: String
        var available: Bool
        var reason: String?
        var model: String?
        var voice: String?

        init(mode: String, available: Bool, reason: String?, model: String?, voice: String?) {
            self.mode = mode; self.available = available; self.reason = reason; self.model = model; self.voice = voice
        }

        /// nil when the reply isn't `ok` (an older backend: no GPT-Live).
        init?(_ json: BotJSON) {
            guard json["ok"].flag == true else { return nil }
            mode = json["mode"].text == "gpt-live" ? "gpt-live" : "chained"
            available = json["available"].flag == true
            reason = json["reason"].text
            model = json["model"].text
            voice = json["voice"].text
        }

        /// What the screen shows when the mode can't be offered; nil when it can.
        var unavailableReason: String? {
            available ? nil : (reason?.isEmpty == false ? reason : String(localized: "GPT-Live isn't available on this Hermes."))
        }
    }
}

// MARK: Speech cleanup (`sanitizeTextForSpeech`)

extension VoiceLive {
    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    private static func replace(_ text: String, _ regex: NSRegularExpression, _ template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static let emoji = re("(?:[\\x{1F000}-\\x{1FAFF}\\x{2600}-\\x{27BF}]|[\\x{FE0F}\\x{200D}]|[\\x{E0020}-\\x{E007F}])+")
    private static let fencedCode = re("```[\\s\\S]*?(?:```|$)")
    private static let inlineCode = re("`([^`]+)`")
    private static let markdownLink = re("\\[([^\\]]+)\\]\\(([^)]+)\\)")
    private static let paragraphBreak = re("[ \\t]*\\n{2,}[ \\t]*")
    private static let punctuatedParagraphBreak = re("([.!?])([*_~`>\"'’”)}\\]]*)[ \\t]*\\n{2,}[ \\t]*")
    private static let softBreak = re("[ \\t]*\\n[ \\t]*")
    private static let mediaPath = re("[ \\t]*MEDIA:\\S+?(?=[.,;:!?)\\]]*(?:\\s|$))")
    private static let lineFinalColon = re(":\\s*$", .anchorsMatchLines)
    private static let thinkingPrefix = re("^\\s*(?:\\([^)\\n]{1,48}\\)\\s*)?(?:processing|thinking|reasoning|analyzing|pondering|contemplating|musing|cogitating|ruminating|deliberating|mulling|reflecting|computing|synthesizing|formulating|brainstorming)\\.\\.\\.\\s*", .caseInsensitive)
    private static let url = re("\\bhttps?://\\S+", .caseInsensitive)
    private static let hyphenBreak = re("(\\p{L})-\\n(\\p{L})")
    private static let heading = re("^#{1,6}\\s+", .anchorsMatchLines)
    private static let symbols = re("[*_~>#]")
    private static let bullet = re("^\\s*[-+*]\\s+", .anchorsMatchLines)
    private static let finalColon = re(":\\s*$")
    private static let whitespace = re("\\s+")

    static func sanitizeForSpeech(_ text: String) -> String {
        let pre = replace(summarizeMarkdownTables(text), lineFinalColon, ".")
        var s = pre.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = replace(s, hyphenBreak, "$1$2")
        s = replace(s, punctuatedParagraphBreak, "$1$2 ")
        s = replace(s, paragraphBreak, ". ")
        s = replace(s, softBreak, " ")
        s = replace(s, fencedCode, "")
        s = replace(s, thinkingPrefix, " ")
        s = replace(s, markdownLink, "$1")
        s = replace(s, inlineCode, "$1")
        s = replace(s, url, "")
        s = replace(s, mediaPath, "")
        s = replace(s, emoji, " ")
        s = replace(s, heading, "")
        s = replace(s, symbols, "")
        s = replace(s, bullet, "")
        s = replace(s, finalColon, ".")
        s = replace(s, whitespace, " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct TableRow { var depth: Int; var cells: [String] }

    private static func isUnescapedPipe(_ row: [Character], _ index: Int) -> Bool {
        var slashes = 0
        var cursor = index - 1
        while cursor >= 0, row[cursor] == "\\" { slashes += 1; cursor -= 1 }
        return slashes % 2 == 0
    }

    private static func tableRow(_ line: String) -> TableRow? {
        var row = Substring(line)
        var depth = 0
        while true {
            let indent = row.prefix { $0 == " " || $0 == "\t" }
            if indent.contains("\t") || indent.count > 3 { return nil }
            row = row.dropFirst(indent.count)
            guard row.hasPrefix(">") else { break }
            depth += 1
            row = row.dropFirst()
            if row.hasPrefix(" ") { row = row.dropFirst() }
        }
        var chars = Array(String(row).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        let pipes = chars.indices.filter { chars[$0] == "|" && isUnescapedPipe(chars, $0) }
        guard let first = pipes.first, let last = pipes.last else { return nil }
        let leading = first == 0
        let trailing = last == chars.count - 1
        if leading { chars.removeFirst() }
        if trailing, !chars.isEmpty { chars.removeLast() }
        var cells: [String] = []
        var start = 0
        for i in chars.indices where chars[i] == "|" && isUnescapedPipe(chars, i) {
            cells.append(String(chars[start..<i]).trimmingCharacters(in: .whitespaces)); start = i + 1
        }
        cells.append(String(chars[start...]).trimmingCharacters(in: .whitespaces))
        if cells.count < 2, !(leading && trailing && cells.count == 1) { return nil }
        return TableRow(depth: depth, cells: cells)
    }

    private static func summarizeMarkdownTables(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var tableLines = Set<Int>()
        var headers: [Int: String] = [:]
        var index = 1
        while index < lines.count {
            guard let delimiter = tableRow(lines[index]), let header = tableRow(lines[index - 1]),
                  delimiter.cells.allSatisfy({ $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }),
                  header.cells.count == delimiter.cells.count, header.depth == delimiter.depth else { index += 1; continue }
            tableLines.formUnion([index - 1, index])
            let joined = header.cells.map { $0.replacingOccurrences(of: "\\|", with: " ").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: ", ")
            headers[index - 1] = joined.isEmpty || ".!?:".contains(joined.last!) ? joined : joined + "."
            var rowIndex = index + 1
            while rowIndex < lines.count, let body = tableRow(lines[rowIndex]), body.depth == delimiter.depth {
                tableLines.insert(rowIndex); rowIndex += 1
            }
            index = rowIndex
        }
        return lines.enumerated().flatMap { i, line -> [String] in
            guard tableLines.contains(i) else { return [line] }
            if let header = headers[i], !header.isEmpty { return [header] }
            return []
        }.joined(separator: "\n")
    }
}

// MARK: Events core (transport-free)

/// Parses `oai-events` frames and builds client events; the WebRTC session wraps it.
/// `send` returns false when the data channel isn't open.
@MainActor final class VoiceLiveEvents {
    private(set) var started = false
    private(set) var sessionID: String?
    private(set) var transcript: [VoiceLive.Fragment] = []
    private(set) var activeDelegationID: String?
    private(set) var finalized = false
    private var counter = 0
    /// Per speaker, the previous delta's `end_ms` (segment boundaries, see `Fragment.startsSegment`).
    private var lastEndMs: [VoiceLive.Fragment.Speaker: Double] = [:]
    /// Fragments received before the previous request's context ended, counted from session start.
    private(set) var cutPoint = 0
    /// Fragments removed from the front of `transcript` by the memory bound.
    private(set) var trimmedFragments = 0
    private let send: (String) -> Bool

    /// Where the `ContextMode` setting is read, at each request.
    var defaults: UserDefaults = .standard
    /// `voice-live-context {mode, fragments, chars, trimmed}` per request (mode 0 = since the last
    /// request, else minutes; trimmed = characters cut by `contextCharLimit`). Set by the screen.

    /// Own the receiver until real transport finalization, even after UI dismissal.

    func appendSent(_ observation: VoiceAppendObservation, to transcript: VoiceTranscriptModel) {
        transcript.recordAppend(observation)
    }

    var onAppend: ((VoiceAppendObservation) -> Void)?
    private var appendCallID: String { callID }
    private let callID = UUID().uuidString
    private var appendOrdinal = 0

    var onStarted: (() -> Void)?
    var onTranscript: ((VoiceLive.Fragment) -> Void)?
    var onDelegation: ((String, [VoiceLive.Fragment]) -> Void)?
    var onError: ((String) -> Void)?
    /// Exactly once: `session.closed`, a lost transport, or our own close timing out.
    var onClosed: ((String, Double?) -> Void)?
    var transportOutput: (() -> Void)?
    var transportFinished: (() -> Void)?

    init(send: @escaping (String) -> Bool) { self.send = send }

    func nextEventID(_ prefix: String) -> String { counter += 1; return "\(prefix)_\(counter)" }

    /// Recent conversation for the next request, oldest first, by `ContextMode`: everything after
    /// the previous request's cut point, or the last N minutes (by the newest fragment's `end_ms`).
    func contextWindow(_ mode: VoiceLive.ContextMode) -> [VoiceLive.Fragment] {
        switch mode {
        case .sinceLastRequest:
            return Array(transcript[max(0, cutPoint - trimmedFragments)...])
        case .lastMinutes(let minutes):
            guard let last = transcript.last else { return [] }
            let floor = last.endMs - Double(minutes * 60_000)
            return transcript.filter { $0.endMs >= floor }
        }
    }

    /// Absolute receipt boundary, captured before submitting a request to Hermes.
    var receivedFragments: Int { trimmedFragments + transcript.count }

    /// Only an accepted Hermes request consumes its captured transcript boundary. Fragments
    /// received while its acknowledgement was in flight remain in the next request's tail.
    func acceptContext(through boundary: Int) {
        precondition(boundary <= receivedFragments)
        cutPoint = max(cutPoint, boundary)
    }

    /// Snapshot for a request. Receiving a vendor delegation alone does not consume the tail.
    func takeContext() -> [VoiceLive.Fragment] {
        let mode = VoiceLive.ContextMode.current(defaults)
        let context = contextWindow(mode)

        return context
    }

    /// Bounds the in-memory transcript (2,000 → 1,500) without dropping anything a later request
    /// can still ask for: only fragments before the cut point AND older than the longest minutes window.
    private func trimTranscript() {
        guard transcript.count > 2_000, let last = transcript.last else { return }
        let beforeCut = cutPoint - trimmedFragments
        let floor = last.endMs - VoiceLive.ContextMode.longestWindowMs
        let outsideWindow = transcript.firstIndex { $0.endMs >= floor } ?? transcript.count
        let drop = min(transcript.count - 1_500, beforeCut, outsideWindow)
        guard drop > 0 else { return }
        transcript.removeFirst(drop)
        trimmedFragments += drop
    }

    func handle(_ raw: String) {
        guard !finalized else { return }
        guard let event = VoiceLive.ServerEvent.parse(raw) else { return }
        switch event {
        case .started(let id):
            started = true
            sessionID = id ?? sessionID
            onStarted?()
        case .transcript(var fragment):
            if let end = lastEndMs[fragment.speaker] { fragment.startsSegment = fragment.startMs > end }
            else { fragment.startsSegment = true }
            lastEndMs[fragment.speaker] = fragment.endMs
            transcript.append(fragment)
            trimTranscript()
            if fragment.speaker == .assistant { transportOutput?() }
            onTranscript?(fragment)
        case .delegation(let id):
            activeDelegationID = id
            onDelegation?(id, takeContext())
        case .error(let code, let message):
            // Late appends after our own close are expected noise.
            if code == "context_injection_incomplete" { return }
            onError?(message)
        case .closed(let reason, let seconds):
            finish(reason, seconds)
        case .other:
            break
        }
    }

    @discardableResult private func emit(_ fields: [String: BotJSON]) -> Bool {
        guard let data = try? JSONEncoder().encode(BotJSON.object(fields)) else { return false }
        let raw = String(decoding: data, as: UTF8.self)
        let kind = fields["type"]?.text.flatMap(VoiceAppendObservation.Kind.init(rawValue:))
        if kind != nil { appendOrdinal += 1 }
        let ordinal = appendOrdinal
        let ok = send(raw)
        if let kind {
            onAppend?(VoiceAppendObservation(callID: appendCallID, ordinal: ordinal, kind: kind,
                                             eventID: Self.appendIdentifier(fields["event_id"]),
                                             delegationID: Self.appendIdentifier(fields["delegation_id"]),
                                             content: fields["content"]?.text ?? "", rawJSON: raw, locallySent: ok))
        }
        return ok
    }

    private static func appendIdentifier(_ value: BotJSON?) -> VoiceAppendObservation.Identifier {
        guard let value else { return .absent }
        if let text = value.text { return .value(text) }
        return .null
    }

    private func delegation(_ id: String?) -> BotJSON { id.map(BotJSON.string) ?? .null }

    /// Quiet progress for the live model ("Hermes is running the tests…").
    func think(_ delegationID: String?, _ content: String) {
        let text = String(VoiceLive.collapse(content).prefix(VoiceLive.appendCharLimit))
        guard !text.isEmpty else { return }
        emit(["type": .string("session.thinking.append"), "content": .string(text),
              "delegation_id": delegation(delegationID), "event_id": .string(nextEventID("think"))])
    }

    /// A result the voice should say aloud (paraphrased), in ≤1,400-char sentence chunks.
    func speak(_ delegationID: String?, _ content: String) {
        for chunk in VoiceLive.chunkForCommentary(content) {
            emit(["type": .string("session.commentary.append"), "content": .string(chunk),
                  "delegation_id": delegation(delegationID), "event_id": .string(nextEventID("say"))])
        }
    }

    /// Steer the live persona mid-conversation (session-wide).
    func instruct(_ content: String) {
        let text = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(VoiceLive.appendCharLimit))
        guard !text.isEmpty else { return }
        emit(["type": .string("session.instructions.append"), "content": .string(text),
              "delegation_id": .null, "event_id": .string(nextEventID("instr"))])
    }

    func mute(_ muted: Bool) {
        emit(["type": .string(muted ? "session.input_audio.mute" : "session.input_audio.unmute"),
              "event_id": .string(nextEventID(muted ? "mute" : "unmute"))])
    }

    /// Asks for `session.closed`; false when the channel is already gone (caller finishes at once).
    func requestClose() -> Bool { emit(["type": .string("session.close")]) }

    func finish(_ reason: String, _ seconds: Double?) {
        guard !finalized else { return }
        finalized = true
        transportFinished?()
        onClosed?(reason, seconds)
    }
}
