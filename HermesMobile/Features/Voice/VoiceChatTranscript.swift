import SwiftUI

struct VoiceChatTranscript: View {
    let model: VoiceTranscriptModel
    let mode: VoiceTranscriptModel.Mode
    let filter: TranscriptSegmentFilter
    let bottomInset: CGFloat
    let namespace: String
    let onLoadOlder: () async -> Bool
    let onReload: () async -> Void
    var onHiddenContext: ((Int) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followLatch = ChatScrollPolicy.FollowLatch()
    @State private var isScrolledNearBottom = true

    static let bottomAnchorID = "voice-bottom-anchor"

    var body: some View {
        let shown = model.display(mode)
        let streaming = model.activeRunID != nil
        let liveRows = VoiceTranscriptModel.localRows(user: model.liveUserMessage, turn: model.liveTurn,
            runID: model.activeRunID ?? "voice", at: model.liveUserMessage?.timestamp ?? 0)
        let rows = shown.messages + liveRows
        let reasoning = ChatViewModel.reasoningDisplayGroups(messages: shown.messages, messageOffset: shown.offset, archivedGroups: [])
        let tools = ToolCallGroup.groups(persistedToolCalls: [], messages: shown.messages, messageOffset: shown.offset)

        let liveTools = model.liveTurn?.segments.compactMap { segment -> ToolCall? in
            if case .tool(let tool) = segment.kind { return tool.presentation(saved: nil) }
            return nil
        } ?? []
        let liveThinking = model.liveTurn?.segments.compactMap { segment -> String? in
            if case .thinking(let text) = segment.kind { return text.string }
            return nil
        }.joined(separator: "\n\n") ?? ""
        let liveAnchor = liveRows.last(where: { $0.role == "assistant" })?.messageId
        ChatTranscriptView(
            isLoading: model.isLoadingHistory,
            errorMessage: nil,
            messages: rows,
            displayedTranscriptMessages: ChatViewModel.transcriptMessages(from: rows, messageOffset: shown.offset),
            compressionReferenceCard: nil,
            reasoningGroupsByAnchorID: Dictionary(grouping: reasoning, by: \.anchorMessageID),
            completedToolCallGroupsForAnchor: { anchor in tools.filter { $0.anchorMessageID == anchor } },
            liveReasoningText: liveThinking,
            reasoningAnchorMessageID: liveAnchor,
            liveToolCalls: liveTools,
            isReplayingLiveToolCalls: false,
            toolCallAnchorMessageID: liveAnchor,
            streamingAssistantMessageID: liveAnchor,
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
            latestTranscriptMessageRole: model.fold == nil && model.liveUserMessage != nil ? "user" : shown.messages.last?.role,
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
            onLoadMessages: onReload,
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
