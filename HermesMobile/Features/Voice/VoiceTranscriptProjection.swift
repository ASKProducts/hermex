import Foundation

@MainActor enum VoiceTranscriptProjection {
    struct Rows {
        var settled: [ChatMessage]
        var live: [ChatMessage]
        var all: [ChatMessage] { settled + live }
    }

    static func rows(_ model: VoiceTranscriptModel, mode: VoiceTranscriptModel.Mode,
                     filter: TranscriptSegmentFilter) -> Rows {
        let shown = model.display(mode)
        let appends = model.appendEvents(mode, showsAppends: filter.appends)
        var settled = appends.filter { $0.afterTurnKey == nil }.map { appendRow($0.observation) }
        for turn in shown.turns {
            let key = TranscriptItems.turnKey(turn)
            let user = turn.userRowIndex.flatMap { index -> ChatMessage? in
                let local = index - shown.offset
                return shown.messages.indices.contains(local) ? shown.messages[local] : nil
            }
            settled += rows(user: user, turn: turn, key: key, filter: filter)
            settled += appends.filter { $0.afterTurnKey == key }.map { appendRow($0.observation) }
        }
        let liveKey = model.liveTurn.map(TranscriptItems.turnKey)
        var live = rows(user: model.liveUserMessage, turn: model.liveTurn,
                        key: liveKey ?? model.activeRunID ?? "voice", filter: filter)
        if let liveKey {
            live += appends.filter { $0.afterTurnKey == liveKey }.map { appendRow($0.observation) }
        }
        return Rows(settled: settled, live: live)
    }

    private static func rows(user: ChatMessage?, turn: ChatTurn?, key: String,
                             filter: TranscriptSegmentFilter) -> [ChatMessage] {
        var result = user.map { [$0] } ?? []
        guard var turn else { return result }
        let timestamp = user?.timestamp ?? 0
        let segments = turn.segments.filter(filter.shows)
        var chunk: [ChatTurnSegment] = []
        var ordinal = 0
        func flush() {
            guard !chunk.isEmpty else { return }
            turn.segments = chunk
            result += VoiceTranscriptModel.localRows(user: nil, turn: turn,
                runID: "\(key)-\(ordinal)", at: timestamp)
            ordinal += 1
            chunk.removeAll(keepingCapacity: true)
        }
        for segment in segments {
            switch segment.kind {
            case .append(let observation):
                flush()
                result.append(appendRow(observation))
            case .steer(let text):
                flush()
                result.append(ChatMessage(role: "user", content: text, timestamp: timestamp,
                    messageId: segment.id.rawValue, displayKind: ChatMessage.steerDisplayKind))
            case .delegationCompletion(let report):
                flush()
                var metadata: [String: JSONValue] = [
                    "task_count": .number(Double(report.taskCount)),
                    "completed_count": .number(Double(report.completedCount)),
                    "failed_count": .number(Double(report.failedCount))]
                if let id = report.delegationID { metadata["delegation_id"] = .string(id) }
                if let duration = report.durationSeconds { metadata["duration_seconds"] = .number(duration) }
                result.append(ChatMessage(role: "system", content: report.report, timestamp: timestamp,
                    messageId: report.id, displayKind: HermesDelegationCompletion.displayKind, displayMetadata: metadata))
            case .text, .thinking, .tool:
                chunk.append(segment)
            }
        }
        flush()
        return result
    }

    private static func appendRow(_ append: VoiceAppendObservation) -> ChatMessage {
        var message = ChatMessage(role: "local_notice", content: append.rawJSON, timestamp: nil,
                                  messageId: append.id)
        message.voiceAppend = append
        return message
    }
}
