import SwiftUI

/// The "In plain words (AI summary)" area on an approval card: a small spinner until the
/// explanation arrives, then its text, or a quiet line when it could not be had. The
/// command above it stays the thing being approved; this only helps read it.
struct ApprovalExplanationView: View {
    let state: ApprovalExplanations.State

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("In plain words (AI summary)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("approval-explanation")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            HStack(spacing: 6) {
                if reduceMotion {
                    // A still glyph instead of the spinning indicator.
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Getting a plain-English summary"))
        case .ready(let text):
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed:
            Text("Couldn’t get a summary.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
