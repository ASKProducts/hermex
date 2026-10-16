import Foundation

/// Pure text rules for voice mode: stop phrases, spoken approval answers,
/// pronunciations and spoken progress. Kept free of audio and networking so
/// every rule is unit-tested.
enum VoiceText {
    /// `apps/desktop/src/lib/voice-stop-word.ts` STOP_PHRASES, same order.
    static let stopPhrases = ["stop", "stop listening", "stop it", "stop please", "please stop", "stop stop",
                              "that is all", "that's all", "never mind", "nevermind", "end conversation",
                              "end the conversation", "goodbye", "good bye", "bye", "cancel"].map(normalize)
    static let addressPrefixes = ["hey hermes", "hermes", "ok", "okay", "hey"]

    /// NFKC, lowercase, punctuation to spaces, collapsed whitespace (desktop `normalize`).
    static func normalize(_ text: String) -> String {
        let composed = text.precomposedStringWithCompatibilityMapping.lowercased()
        let spaced = String(composed.unicodeScalars.map { CharacterSet.punctuationCharacters.contains($0) ? " " : Character($0) })
        return spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func candidates(_ transcript: String) -> Set<String> {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return [] }
        var out: Set<String> = [normalized]
        for prefix in addressPrefixes where normalized != prefix && normalized.hasPrefix(prefix + " ") {
            out.insert(String(normalized.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces))
            break
        }
        return out
    }

    /// True only when the whole utterance is a stop command, optionally addressed.
    static func isStopCommand(_ transcript: String) -> Bool {
        !candidates(transcript).isDisjoint(with: stopPhrases)
    }

    enum ApprovalAnswer: Equatable { case approve, deny }
    private static let approveWords = Set(["approve", "approved", "yes", "yes please", "yeah", "yep", "go ahead", "do it", "allow", "okay", "ok", "sure"].map(normalize))
    private static let denyWords = Set(["deny", "denied", "no", "nope", "don't", "do not", "reject", "no thanks", "don't do it"].map(normalize))

    /// A whole-utterance spoken answer to an approval; nil when it is neither.
    /// Never maps to "always" or "session": voice approves once only.
    static func approvalAnswer(_ transcript: String) -> ApprovalAnswer? {
        let options = candidates(transcript)
        if !options.isDisjoint(with: denyWords) { return .deny }
        if !options.isDisjoint(with: approveWords) { return .approve }
        return nil
    }

    /// A spoken choice for a clarify question: a number ("2", "two", "option two")
    /// or the whole choice text. Returns the zero-based index.
    static func choiceIndex(_ transcript: String, choices: [String]) -> Int? {
        let said = normalize(transcript)
        let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        var word = said
        for prefix in ["option ", "number ", "choice "] where word.hasPrefix(prefix) { word = String(word.dropFirst(prefix.count)) }
        if let n = Int(word), (1...choices.count).contains(n) { return n - 1 }
        if let n = numbers.firstIndex(of: word), n < choices.count { return n }
        return choices.firstIndex { normalize($0) == said }
    }

    struct Pronunciation: Codable, Equatable, Hashable {
        var written: String
        var spoken: String
    }

    static let defaultPronunciations = [
        Pronunciation(written: "CalDAV", spoken: "cal-dav"),
        Pronunciation(written: "Hermex", spoken: "Her-mex")]

    /// Replaces whole words only, case-insensitively.
    static func applyPronunciations(_ text: String, _ list: [Pronunciation]) -> String {
        var out = text
        for entry in list where !entry.written.isEmpty {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: entry.written) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: NSRegularExpression.escapedTemplate(for: entry.spoken))
        }
        return out
    }

    /// Plan step 6: the fixed spoken status per tool. Never invented text.
    static func progressPhrase(tool: String) -> String {
        switch tool {
        case "terminal", "process": return String(localized: "Running a command.")
        case "read_file", "search_files": return String(localized: "Reading files.")
        case "patch", "write_file": return String(localized: "Editing files.")
        case "web_search", "web_extract": return String(localized: "Searching the web.")
        case "delegate_task": return String(localized: "Handing it to a helper.")
        default: return tool.hasPrefix("browser_") ? String(localized: "Using the browser.") : String(localized: "Still working.")
        }
    }
}

/// When to speak a progress line: not before `firstDelay` after the send, at most
/// every `interval`, and only when the tool changed since the last line.
struct VoiceProgressPacer {
    var firstDelay: TimeInterval = 6
    var interval: TimeInterval = 20
    private(set) var sentAt: Date?
    private(set) var lastSpokenAt: Date?
    private(set) var lastSpokenTool: String?

    mutating func reset(sentAt: Date) { self.sentAt = sentAt; lastSpokenAt = nil; lastSpokenTool = nil }

    /// The phrase to speak now for the latest tool, or nil.
    mutating func phrase(latestTool: String?, now: Date, replyStarted: Bool) -> String? {
        guard let sentAt, let tool = latestTool, !replyStarted, now.timeIntervalSince(sentAt) >= firstDelay else { return nil }
        let phrase = VoiceText.progressPhrase(tool: tool)
        if let last = lastSpokenAt, now.timeIntervalSince(last) < interval { return nil }
        if let lastTool = lastSpokenTool, VoiceText.progressPhrase(tool: lastTool) == phrase { return nil }
        lastSpokenAt = now
        lastSpokenTool = tool
        return phrase
    }
}
