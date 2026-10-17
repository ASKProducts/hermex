import SwiftUI

struct VoiceChatTranscript: View {
    let model: VoiceTranscriptModel
    let mode: VoiceTranscriptModel.Mode
    let filter: TranscriptSegmentFilter
    let bottomInset: CGFloat
    let namespace: String
    let onLoadOlder: () async -> Bool
    var onHiddenContext: ((Int) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followLatch = ChatScrollPolicy.FollowLatch()
    @State private var isScrolledNearBottom = true

    static let bottomAnchorID = "voice-bottom-anchor"

    var body: some View {
        let shown = model.display(mode, filter)
        let streaming = model.activeRunID != nil
        let rows = shown.messages
        ChatTranscriptView(
            isLoading: model.isLoadingHistory,
            errorMessage: nil,
            messages: rows,
            displayedTranscriptMessages: ChatViewModel.transcriptMessages(from: rows, messageOffset: shown.offset,
                                                                          renderedActivityAnchorIDs: shown.activityAnchors),
            compressionReferenceCard: nil,
            reasoningGroupsByAnchorID: Dictionary(grouping: shown.reasoningGroups, by: \.anchorMessageID),
            completedToolCallGroupsForAnchor: { anchor in shown.toolCallGroups.filter { $0.anchorMessageID == anchor } },
            liveReasoningText: shown.liveThinking,
            reasoningAnchorMessageID: shown.liveAnchor,
            liveToolCalls: shown.liveTools,
            isReplayingLiveToolCalls: false,
            toolCallAnchorMessageID: shown.liveAnchor,
            streamingAssistantMessageID: shown.liveAnchor,
            liveTokensPerSecond: nil,
            activeStreamRecoveryState: .idle,
            clarificationPromptID: nil,
            hidesRunStatusAccessibility: false,
            showsThinkingAndToolCards: filter.thinkingAndTools,
            workingRowStartedAt: model.workingSince,
            requestWithdrawal: nil,
            showsScrollToBottomButton: ChatScrollPolicy.showsScrollToBottomButton(
                isNearBottom: isScrolledNearBottom, isStreaming: streaming, isFollowing: followLatch.isFollowing),
            shouldFollowLatestMessage: followLatch.isFollowing,

            isDisclosureSettling: false,
            latestTranscriptMessageRole: rows.last?.role,
            isScrolledNearBottom: isScrolledNearBottom,
            activeStreamID: model.activeRunID,
            streamingScrollTrigger: { model.liveRevision },
            transcriptRelayoutScrollToken: model.settledRevision,
            completedResponseRenderID: nil,
            bottomAnchorID: Self.bottomAnchorID,
            transcriptSpacing: 8,
            transcriptBottomInsetHeight: bottomInset,
            scrollToBottomButtonBottomPadding: bottomInset + 8,
            localAttachmentPreviews: [:],
            listeningMessageID: nil,
            isViewingCachedData: false,
            hasOlderMessages: model.hasOlder && mode == .full,
            isLoadingOlderMessages: false,
            isRegeneratingMessage: false,
            isEditingMessage: false,
            isForkingMessage: false,
            loadAttachmentImage: { _ in nil },
            attachmentAudio: nil,
            loadTranscriptMediaImage: { _ in nil },
            loadTranscriptMediaData: { _ in nil },
            transcriptMediaCacheNamespace: namespace,
            actionContext: { _, _ in nil },
            shouldRenderMessageRow: { _ in true },
            // The pull loads an older page only: with none it has nothing to do. A call keeps
            // its own transcript current, and GPT-Live's spoken words are kept only here (Hermes
            // saves none of them), so reading the saved rows again would drop them.
            onLoadMessages: {},
            onLoadOlderMessages: onLoadOlder,
            onUpdateScrollMetrics: updateScrollMetrics,
            onFollowEvent: follow,
            onDisclosureToggle: {},
            turnFolds: .none,
            terminalReplyRenderIDs: [],
            expandedTurnKeys: [],
            onToggleTurnFold: { _ in },
            onDismissKeyboard: {},
            onScrollToBottom: { scroll($0, animated: !streaming, userInitiated: true, reason: "bottom") },
            onScrollToLatestTranscriptMessage: { scroll($0, animated: true, userInitiated: false, reason: "bottom") },
            onScrollToLatestContent: { scroll($0, animated: $1, userInitiated: false, reason: "follow") },
            onPreviewAttachment: { _, _ in },
            onPreviewTranscriptMedia: { _ in },
            onAskHermex: { _ in },
            onToggleListening: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: { _ in }

        )
        .accessibilityIdentifier("voice-transcript")
    }

    private func follow(_ event: ChatScrollPolicy.FollowEvent) {
        let resolved = ChatScrollPolicy.resolveFollow(current: followLatch, event: event)
        if resolved != followLatch { followLatch = resolved }
    }

    private func updateScrollMetrics(_ metrics: ChatScrollMetrics) {
        let near = ChatScrollPolicy.isNearBottom(distanceFromBottom: metrics.distanceFromBottom,
                                                 isStreaming: model.activeRunID != nil)
        let was = isScrolledNearBottom
        isScrolledNearBottom = near
        follow(.contentScrolled(isAtBottom: ChatScrollPolicy.isAtBottom(distanceFromBottom: metrics.distanceFromBottom),
                                isUserScrolling: metrics.isUserInteracting,
                                movedAwayFromBottom: metrics.movedAwayFromBottom,
                                wasNearBottom: was))
    }

    private func scroll(_ scroller: ScrollViewProxy, animated: Bool, userInitiated: Bool, reason: String) {
        if userInitiated { follow(.reset) } else if !followLatch.isFollowing { return }
        if animated && !reduceMotion {
            withAnimation(.smooth) { scroller.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
        } else {
            scroller.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }
}
