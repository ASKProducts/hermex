import SwiftUI

/// round liquid-glass button of its own.
struct VoiceHeaderButton: View {
    static let size: CGFloat = 52

    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.size, height: Self.size)
                .adaptiveGlass(isInteractive: true, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// or background, then the call's settings and minimize at the far right. `orb` is the orb's
/// slot (`VoiceScreen.headerOrb`), laid out to fill the row up to the buttons.
struct VoiceTopBar<Orb: View>: View {
    static var buttonIdentifiers: [String] { ["voice-settings", "voice-minimize"] }

    let orb: Orb
    let disabled: Bool
    let minimize: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            orb
            VoiceHeaderButton(systemImage: "gearshape.fill", title: String(localized: "Call settings"), action: settings)
                .disabled(disabled)
                .accessibilityIdentifier(Self.buttonIdentifiers[0])
            VoiceHeaderButton(systemImage: "chevron.down", title: String(localized: "Minimize"), action: minimize)
                .disabled(disabled)
                .accessibilityIdentifier(Self.buttonIdentifiers[1])
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// visible and updating above it, and the call keeps running. Every switch is the same
/// stored setting Settings › Voice edits.
struct VoiceCallSettingsSheet: View {
    /// The system's half-height detent: the title bar and the three rows fit in it.
    static let detent = PresentationDetent.medium
    /// The keys this sheet's switches write, in order (Settings › Voice writes the same ones).
    static let storageKeys = [VoicePreferences.showsThinkingAndToolsKey, VoicePreferences.showsAppendsKey]

    let mode: VoiceMode
    @AppStorage(VoicePreferences.showsThinkingAndToolsKey) private var showsThinkingAndTools = true
    @AppStorage(VoicePreferences.showsAppendsKey) private var showsAppends = true

    var body: some View {
        // A navigation bar with the sheet's title, as system sheets (and the app's model picker)
        NavigationStack {
            Form {
                Section {
                    Label(mode.modeLine, systemImage: mode.systemImage)
                        .accessibilityIdentifier("voice-call-mode")
                }
                Section(String(localized: "Show in transcript")) {
                    Toggle(String(localized: "Thinking and tool calls"), isOn: $showsThinkingAndTools)
                        .accessibilityIdentifier("voice-show-thinking-tools")
                    Toggle(String(localized: "GPT-Live appends"), isOn: $showsAppends)
                        .accessibilityIdentifier("voice-show-appends")
                }

            }
            .navigationTitle(String(localized: "Call settings"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationBackgroundInteraction(.enabled(upThrough: Self.detent))
        .accessibilityIdentifier("voice-settings-sheet")
    }
}
