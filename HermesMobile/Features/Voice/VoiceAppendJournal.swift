import Foundation

struct VoiceAppendJournal {
    struct Entry: Equatable {
        let observation: VoiceAppendObservation
        let exchangeKey: String?
        /// Sent inside the exchange `exchangeKey`. False = sent between exchanges.
        let placedInExchange: Bool
        /// The ids of the exchange's segments drawn before it when it was sent, in order.
        let preceding: [ChatTurnSegmentID]
        /// The delegation it was sent for: its own `delegation_id`, else the exchange's last
        /// delegation card before it.
        let delegation: String?
        /// The saved row ids Hermes had reported for that delegation's turn when it was sent
        /// (`persisted_turn.row_ids` of its `message.complete`): it goes after those rows.
        let savedRowsBefore: [Int]
        /// The saved user row of that delegation's turn, when Hermes had reported it by then.
        var anchorUserRow: Int? = nil
        /// Sent between exchanges: the saved user row of the last saved turn before it.
        var afterUserRow: Int? = nil
    }
    struct Projection: Equatable {
        let observation: VoiceAppendObservation
        /// nil is the leading boundary; the transcript adapter maps it to beforeFirstTurn.
        let afterTurnKey: String?
    }
    enum ExchangeWindow {
        case all
        case only(String?)
    }

    private(set) var entries: [Entry] = []
    /// The saved row ids Hermes reported for each delegation's turn (`saved`).
    private(set) var savedRows: [String: [Int]] = [:]
    /// The saved user row id of each delegation's turn (`persisted_turn.user_row_id`).
    private(set) var userRows: [String: Int] = [:]

    init() {}

    /// Hermes saved a delegation's turn: the row ids of its `message.complete` receipt.
    mutating func saved(delegation: String, userRowID: Int?, rowIDs: [Int]) {
        if let userRowID { userRows[delegation] = userRowID }
        savedRows[delegation, default: []] += rowIDs
    }

    /// This journal's appends, then `later`'s (this screen's own, sent after them).

    /// The id prefix of a delegation's card segment (`VoiceTranscriptModel.delegationStarted`).
    static let delegationCardPrefix = "tool:delegation:"

    /// Sent with no exchange on screen: drawn after the exchange `key` (the last one), between
    /// turns; `afterUserRow` is that turn's saved user row, if it is a saved turn.
    @discardableResult
    mutating func append(_ observation: VoiceAppendObservation, afterExchange key: String?, afterUserRow: Int? = nil) -> Entry {
        let entry = Entry(observation: observation, exchangeKey: key, placedInExchange: false,
                          preceding: [], delegation: Self.ownDelegation(observation), savedRowsBefore: [],
                          afterUserRow: afterUserRow)
        entries.append(entry)
        return entry
    }

    /// Sent during the exchange `key`, after its segments `preceding` (the fold holds it too).
    @discardableResult
    mutating func append(_ observation: VoiceAppendObservation, inExchange key: String, preceding: [ChatTurnSegmentID]) -> Entry {
        let delegation = Self.ownDelegation(observation) ?? Self.lastCard(preceding)
        let entry = Entry(observation: observation, exchangeKey: key, placedInExchange: true,
                          preceding: preceding, delegation: delegation,
                          savedRowsBefore: delegation.flatMap { savedRows[$0] } ?? [],
                          anchorUserRow: delegation.flatMap { userRows[$0] })
        entries.append(entry)
        return entry
    }

    private static func ownDelegation(_ observation: VoiceAppendObservation) -> String? {
        if case .value(let id) = observation.delegationID, !id.isEmpty { return id }
        return nil
    }

    private static func lastCard(_ preceding: [ChatTurnSegmentID]) -> String? {
        preceding.last { $0.rawValue.hasPrefix(delegationCardPrefix) }
            .map { String($0.rawValue.dropFirst(delegationCardPrefix.count)) }
    }

    /// The saved row a settled segment was built from (`ChatTurnSegmentID.message`), if any.
    private static func savedRow(_ id: ChatTurnSegmentID) -> Int? {
        let parts = id.rawValue.split(separator: ":")
        guard parts.count == 3, parts[0] == "msg" else { return nil }
        return Int(parts[1])
    }

    /// The key of the drawn turn that holds `entry`, or nil when none does. `drawnKeys`: the
    /// keys of the turns on screen; `savedTurnKey`: the key of the drawn saved turn whose user
    /// row has this id, if any.
    func home(_ entry: Entry, drawnKeys: Set<String>, savedTurnKey: (Int) -> String?) -> String? {
        guard entry.placedInExchange else { return nil }
        if let key = entry.exchangeKey, drawnKeys.contains(key) { return key }
        return (entry.delegation.flatMap { userRows[$0] } ?? entry.anchorUserRow).flatMap(savedTurnKey)
    }

    /// `turn` with the appends whose home it is, each right after the last segment of the turn
    /// that was drawn or saved before it was sent: a segment it followed on screen (the voice's
    /// own speech and cards are not in a saved turn; Hermes's tools are, under the same
    /// `tool:<tool_id>`), or one built from a saved row Hermes had reported by then.
    /// Send order is never reversed: an append never goes above the one sent before it.
    func weave(into turn: ChatTurn, key: String, home: (Entry) -> String?) -> ChatTurn {
        let mine = entries.filter { home($0) == key }
        guard !mine.isEmpty else { return turn }
        var segments = turn.segments
        var floor = 0
        for entry in mine {
            var at = floor
            let followed = Set(entry.preceding)
            let saved = Set(entry.savedRowsBefore)
            if let index = segments.lastIndex(where: { segment in
                followed.contains(segment.id) || Self.savedRow(segment.id).map(saved.contains) == true
            }) {
                at = max(floor, index + 1)
            }
            segments.insert(ChatTurnSegment(id: ChatTurnLiveFold.appendSegmentID(entry.observation),
                                            kind: .append(entry.observation)), at: at)
            floor = at + 1
        }
        var woven = turn
        woven.segments = segments
        return woven
    }

    func project(turnKeys: [String], visibleTurnKeys: [String]? = nil, showsAppends: Bool,
                 aliases: [String: String] = [:], currentExchange: ExchangeWindow = .all,
                 home: (Entry) -> String? = { _ in nil },
                 savedTurnKey: (Int) -> String? = { _ in nil }) -> [Projection] {
        guard showsAppends else { return [] }
        let indices = Dictionary(uniqueKeysWithValues: turnKeys.enumerated().map { ($0.element, $0.offset) })
        let window = (visibleTurnKeys ?? turnKeys).compactMap { key in indices[key].map { (key: key, index: $0) } }
        var windowBoundary = -1
        var preceding = -1
        var result: [Projection] = []
        for entry in entries {
            let resolvedKey = entry.exchangeKey.map { aliases[$0] ?? $0 } ?? entry.afterUserRow.flatMap(savedTurnKey)
            let boundary = max(preceding, resolvedKey.flatMap { indices[$0] } ?? preceding)
            preceding = boundary
            if home(entry) != nil { continue }
            if case .only(let key) = currentExchange {
                let current = key.map { aliases[$0] ?? $0 }
                // Membership is the captured exchange, not the clamped display location.
                guard resolvedKey == current else { continue }
            }
            while windowBoundary + 1 < window.count, window[windowBoundary + 1].index <= boundary {
                windowBoundary += 1
            }
            result.append(Projection(observation: entry.observation,
                                     afterTurnKey: windowBoundary < 0 ? nil : window[windowBoundary].key))
        }
        return result
    }
}
