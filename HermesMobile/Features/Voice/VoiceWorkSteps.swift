import Foundation

/// from its gateway events, and when to say them.
///
/// A step is one tool call with the detail the app's tool cards already derive
/// (`ToolCallSummaryFormatter`: the file name, the search query, the site, the command), a
/// subagent starting or finishing, a background job finishing, or one of Hermes's own
/// remarks. Raw tool names never appear: a tool the formatter doesn't recognise is told by
/// its detail alone, or not at all.
enum VoiceWorkStep {
    /// The step for a `tool.start` payload, or nil when it says nothing a person would.
    static func tool(_ payload: BotJSON) -> String? {
        let name = payload["name"].text
        let args = payload["args"].argumentDictionary
        let kind = ToolCallSummaryFormatter.kind(forToolNamed: name)
        if kind == .delegate {
            let goal = args.flatMap { firstText($0, ["goal", "task", "prompt"]) } ?? payload["context"].text
            return goal.map { "asking a helper to \(short($0))" } ?? "handing part of it to a helper"
        }
        let call = ToolCall(name: name, preview: nil, args: args)
        let detail = ToolCallSummaryFormatter.row(for: call, isLive: true)?.detail.map { short($0) }
        switch kind {
        case .shell: return detail.map { "running \($0)" } ?? "running a command"
        case .read: return detail.map { "reading \($0)" } ?? "reading a file"
        case .write: return detail.map { "editing \($0)" } ?? "editing a file"
        case .search: return detail.map { "searching for \($0)" } ?? "searching"
        case .web: return detail.map { "looking at \($0)" } ?? "looking something up online"
        case .list: return detail.map { "listing \($0)" } ?? "listing files"
        case .skill: return detail.map { "loading the \($0) instructions" } ?? "loading instructions"
        case .memory: return "saving a note to memory"
        case .delegate: return nil
        case .unknown: return detail.map { "working on \($0)" }
        }
    }

    /// The step for a subagent or background event, or nil for the ones that aren't steps
    /// (a subagent's thinking or batched tool names).
    static func event(_ type: String, _ payload: BotJSON) -> String? {
        switch type {
        case "subagent.start":
            return payload["goal"].text.map { "a helper started on \(short($0))" } ?? "a helper started"
        case "subagent.complete":
            let failed = payload["status"].text.map { $0 != "completed" && $0 != "success" && $0 != "ok" } ?? false
            let goal = payload["goal"].text.map { short($0) }
            if failed { return goal.map { "a helper couldn't finish \($0)" } ?? "a helper couldn't finish" }
            return goal.map { "a helper finished \($0)" } ?? "a helper finished"
        case "background.complete":
            return "a background job finished"
        default:
            return nil
        }
    }

    /// One of Hermes's own remarks between steps (`message.interim`).
    static func remark(_ text: String) -> String? {
        let said = VoiceLive.sanitizeForSpeech(text).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return said.isEmpty ? nil : "Hermes said: \(short(said, limit: 200))"
    }

    private static func firstText(_ args: [String: JSONValue], _ keys: [String]) -> String? {
        for key in keys {
            if case .string(let value)? = args[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }

    /// One line, at most `limit` characters.
    static func short(_ text: String, limit: Int = 90) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

/// The steps of one voice request and when an unprompted update is due.
///
/// - Every step is kept for the request, so "what are you doing?" is answered from the same
///   list (`context`), with the switch on or off.
/// - An update (`dueUpdate`) carries the steps since the last one, and is due only when all
///   hold: the switch is on; at least `firstDelay` since the request; at least `interval`
///   since the last update; new steps since it; nobody talking; the answer not started.
struct VoiceWorkLog {
    static let firstDelay: TimeInterval = 12
    static let interval: TimeInterval = 25
    /// How many of the newest steps the context and an update name.
    static let shownSteps = 8

    private(set) var startedAt: Date?
    private(set) var steps: [String] = []
    private(set) var reported = 0
    private(set) var lastUpdateAt: Date?

    /// A new request began at `at`: the list starts empty.
    mutating func begin(at: Date) {
        self = VoiceWorkLog()
        startedAt = at
    }

    /// Adds a step; the same step twice in a row is one step that is still going on.
    /// Returns whether the list changed.
    @discardableResult mutating func add(_ step: String?) -> Bool {
        guard startedAt != nil, let step, !step.isEmpty, steps.last != step else { return false }
        steps.append(step)
        return true
    }

    /// The steps for an update now, or nil when none is due (see the type's rules). Marks
    /// them told.
    mutating func dueUpdate(now: Date, enabled: Bool, quiet: Bool, answerStarted: Bool) -> String? {
        guard enabled, quiet, !answerStarted, let startedAt, steps.count > reported,
              now.timeIntervalSince(startedAt) >= Self.firstDelay else { return nil }
        if let lastUpdateAt, now.timeIntervalSince(lastUpdateAt) < Self.interval { return nil }
        let new = Array(steps[reported...].suffix(Self.shownSteps))
        reported = steps.count
        lastUpdateAt = now
        return Self.summary(new)
    }

    /// The silent context GPT-Live keeps while Hermes works: every step so far (newest last).
    var context: String? {
        guard !steps.isEmpty else { return nil }
        let shown = steps.suffix(Self.shownSteps)
        let earlier = steps.count - shown.count
        let list = (earlier > 0 ? ["\(earlier) earlier steps"] : []) + shown
        return "Background for you only, not to be said: Hermes is still working, not done yet. Its steps so far, newest last: \(list.joined(separator: "; ")). "
            + "Do not mention these steps on your own. Only if the user asks what Hermes is doing, answer from them in a few plain words."
    }

    /// The steps since the last update, as one line for GPT-Live to put in a few plain words.
    static func summary(_ steps: [String]) -> String {
        steps.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.joined(separator: "; ") + "."
    }
}
