import SwiftUI

enum HermesHomeTab: String {
    case bots, sessions
}

struct HermesHome {
    let title: String
    let avatar: SessionsHeader.Avatar
    let tab: Binding<HermesHomeTab>
    let server: URL
    var voiceChat: Binding<ConversationTarget?>
}

struct HermesHomeChrome<Filter: View, NewChat: View>: ViewModifier {
    let home: HermesHome
    var isVoiceDisabled = false
    @State private var voiceAvailability = VoiceStartAvailability()
    @ViewBuilder let filter: Filter
    @ViewBuilder let newChat: NewChat

    func body(content: Content) -> some View {
        content
            .modifier(HiddenBottomScrollEdge())
            .navigationTitle(home.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .bottomBar) { filter }
                if #available(iOS 26, *) {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) { HermesHomeSwitch(tab: home.tab) }
                        .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                } else {
                    ToolbarItem(placement: .bottomBar) { HermesHomeSwitch(tab: home.tab) }
                }
                if !VoiceCallController.shared.isRunning,
                   voiceAvailability.offersVoice(for: VoiceStartScope.current(server: home.server)) {
                    ToolbarItem(placement: .bottomBar) {
                        HermesHomeVoiceButton(server: home.server, isDisabled: isVoiceDisabled, availability: voiceAvailability)
                    }
                }
                ToolbarItem(placement: .bottomBar) { newChat }
            }
            .task(id: VoiceStartScope.current(server: home.server)) {
                let scope = VoiceStartScope.current(server: home.server)
                await voiceAvailability.refresh(scope: scope, currentScope: { VoiceStartScope.current(server: home.server) })
            }
    }
}

struct HermesHomeVoiceButton: View {
    let server: URL
    let isDisabled: Bool
    @State private var voiceCalls = VoiceCallController.shared
    let availability: VoiceStartAvailability
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    var body: some View {
        Menu {
            VoiceStartMenu(availability: availability, scope: VoiceStartScope.current(server: server)) { mode in
                voiceCalls.start(VoiceCallPresentation(server: server, requestedMode: mode))
            }
        } label: {
            Label("Talk to Hermes", systemImage: "waveform")
        } primaryAction: {
            HapticButtonHaptics.tap(style: .medium, isEnabled: isHapticsEnabled)
            voiceCalls.start(VoiceCallPresentation(server: server))
        }
        .disabled(isDisabled)
        .accessibilityIdentifier("voice-start")
    }
}

private struct HiddenBottomScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            content
        }
    }
}

private struct HermesHomeSwitch: View {
    @Binding var tab: HermesHomeTab

    var body: some View {
        Picker(selection: $tab) {
            Text("Bots").tag(HermesHomeTab.bots)
            Text("Sessions").tag(HermesHomeTab.sessions)
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
    }
}
