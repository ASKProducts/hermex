import SwiftUI

struct VoiceAppendRow: View {
    let append: VoiceAppendObservation
    @State private var expanded = false
    var body: some View { Self.appendRow(append, expansion: $expanded) }

    static func appendRow(_ append: VoiceAppendObservation, expansion: Binding<Bool>) -> some View {
        let row = VoiceAppendLogRowContent(observation: append)
        return TranscriptLogRowView(
            summary: row.summary,
            detail: row.detail,
            isFailure: row.isFailure,
            isExpanded: expansion.wrappedValue,
            accessibilityLabel: row.accessibilityLabel,
            copyText: { row.copyText },
            toggleExpansion: { expansion.wrappedValue.toggle() }
        ) {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(row.isFailure ? Color.red : Color.secondary)
        } status: {
            if row.isFailure {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
            }
        } expandedBody: {
            Text(verbatim: row.copyText)
                .font(AppFont.mono(style: .caption))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .chatTimelineAccessoryInsetSurface()
        }
        .forcedLeftToRight()
    }
}
