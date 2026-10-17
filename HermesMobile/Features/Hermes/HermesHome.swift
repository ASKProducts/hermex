import SwiftUI

/// The two sides of a Hermes server's home (#709): the Bots inbox and the session list.
enum HermesHomeTab: String {
    case bots, sessions
}

/// What both sides of a Hermes server's home share: the server's name, which titles a pushed
/// screen's back button, the server's avatar in the header, and the switch between the sides.
struct HermesHome {
    let title: String
    let avatar: SessionsHeader.Avatar
    let tab: Binding<HermesHomeTab>
    let server: URL
    var voiceChat: Binding<ConversationTarget?>
}

/// The Hermes home's bar chrome (#709), the same on both sides: no top bar, since each side's
/// list leads with the session list's header (`SessionsHeader`), and a bottom bar of
/// `(filter) [Bots | Sessions] (voice) (new chat)` whose ends each side fills; the voice button
/// shows while no call runs and the server offers voice. The title names a pushed
/// screen's back button, and stays inline so a pushed screen such as Tasks keeps the one-line bar.
/// On iOS 26 the bar's glass pills float over the list: the system's bottom scroll edge effect
/// read as a solid band behind them, so it is hidden.
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
                    // The segmented control is its own pill; a glass one around it would double it.
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

/// The home bar's new-call button: a tap starts a call in the default mode, a hold offers both.
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

/// `[Bots | Sessions]`. It keeps a system bar's size at accessibility text sizes; a long press
/// shows the Large Content Viewer instead.
private struct HermesHomeSwitch: View {
    @Binding var tab: HermesHomeTab

    var body: some View {
        // The segments name themselves; the picker needs no label of its own.
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
