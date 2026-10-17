import Foundation

/// Which of a voice turn's parts the voice transcript draws (the call's "Show in transcript").
struct TranscriptSegmentFilter: Equatable {
    var appends = true
    var thinkingAndTools = true

    static let all = TranscriptSegmentFilter()

    init(appends: Bool = true, thinkingAndTools: Bool = true) {
        self.appends = appends
        self.thinkingAndTools = thinkingAndTools
    }
}
