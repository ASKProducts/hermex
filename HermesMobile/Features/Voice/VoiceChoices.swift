import Foundation
import Observation
import SwiftUI

struct VoiceChoices: Equatable, Sendable {
    enum Unavailable: Error { case routeNotAdvertised }
    enum Mode: String, CaseIterable, Sendable { case live, cascade }

    struct Choice: Equatable, Sendable {
        var voice: String
        var choices: [String]

        /// The voices to list: the host's choices, plus its current voice if the list lacks it.
        var listed: [String] { choices.contains(voice) ? choices : choices + [voice] }
    }

    var live: Choice
    var cascade: Choice

    init(live: Choice, cascade: Choice) {
        self.live = live
        self.cascade = cascade
    }

    /// `{"ok": true, "live": {"voice", "choices"}, "cascade": {"voice", "choices"}}`, the
    /// body of both GET and PUT. Nil without `ok` or without either mode.
    init?(_ json: BotJSON) {
        guard json["ok"].flag == true,
              let live = Choice(json["live"]), let cascade = Choice(json["cascade"]) else { return nil }
        self.init(live: live, cascade: cascade)
    }

    subscript(mode: Mode) -> Choice {
        switch mode {
        case .live: live
        case .cascade: cascade
        }
    }

    /// A voice's name as the pickers show it: `marin` reads "Marin".
    static func title(_ voice: String) -> String { voice.capitalized }
}

extension VoiceChoices.Choice {
    init?(_ json: BotJSON) {
        guard let voice = json["voice"].text, !voice.isEmpty, let list = json["choices"].list else { return nil }
        self.init(voice: voice, choices: list.compactMap(\.text))
    }
}

/// Settings → Voice's two pickers. A pick is sent to the host and the picker shows the host's
/// answer; nothing changes on screen until the host has answered.
@MainActor @Observable final class VoiceChoicesModel {
    enum State: Equatable {
        case loading
        case loaded(VoiceChoices)
        /// The companion has not advertised the read route.
        case unavailable
        /// An advertised route couldn't be read, or there is no Hermes connection.
        case unreachable
    }

    typealias Fetch = @MainActor () async throws -> VoiceChoices
    typealias Save = @MainActor (VoiceChoices.Mode, String) async throws -> VoiceChoices

    private(set) var state: State = .loading
    var showsSection: Bool { state != .unavailable }
    /// The mode whose pick is on its way to the host.
    private(set) var saving: VoiceChoices.Mode?
    /// One short line after a pick the host didn't take.
    private(set) var failure: String?

    private let fetch: Fetch
    private let save: Save

    static let unreachableText = String(localized: "Set on your Hermes")
    static let failureText = String(localized: "Couldn't change the voice.")

    init(fetch: @escaping Fetch, save: @escaping Save) {
        self.fetch = fetch
        self.save = save
    }

    func load() async {
        state = .loading
        do { state = .loaded(try await fetch()) }
        catch VoiceChoices.Unavailable.routeNotAdvertised { state = .unavailable }
        catch { state = .unreachable }
    }

    /// Sends `voice` for `mode`. The host's reply becomes the state. A failed pick leaves the
    /// state at the host's last answer, so the picker shows that voice again, with `failure`.
    func select(_ voice: String, for mode: VoiceChoices.Mode) async {
        guard case .loaded(let current) = state, current[mode].voice != voice else { return }
        saving = mode
        failure = nil
        defer { saving = nil }
        do {
            state = .loaded(try await save(mode, voice))
        } catch {
            failure = Self.failureText
        }
    }
}

/// Settings → Voice → Voices: one picker per mode, listing that mode's voices from the host.
struct VoiceChoicesSection: View {
    let model: VoiceChoicesModel

    @ViewBuilder var body: some View {
        if model.showsSection { choicesSection }
    }

    private var choicesSection: some View {
        Section {
            switch model.state {
            case .unavailable:
                EmptyView()
            case .loading:
                HStack {
                    Text(String(localized: "Voices"))
                    Spacer()
                    ProgressView()
                }
                .accessibilityIdentifier("voice-choices-loading")
            case .unreachable:
                LabeledContent(String(localized: "Voice"), value: VoiceChoicesModel.unreachableText)
                    .accessibilityIdentifier("voice-choices-unreachable")
            case .loaded(let choices):
                picker(String(localized: "GPT-Live voice"), .live, choices.live, id: "voice-choice-live")
                picker(String(localized: "Speech-to-text + Hermes voice"), .cascade, choices.cascade, id: "voice-choice-cascade")
                if let failure = model.failure {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("voice-choices-error")
                }
            }
        } header: { Text("Voices") } footer: {
            Text("Applies to your next call.")
        }
    }

    /// The picker shows the host's voice; a pick is sent and the picker moves only when the
    /// host's answer arrives.
    private func picker(_ title: String, _ mode: VoiceChoices.Mode, _ choice: VoiceChoices.Choice, id: String) -> some View {
        Picker(selection: Binding(get: { choice.voice }, set: { voice in Task { await model.select(voice, for: mode) } })) {
            ForEach(choice.listed, id: \.self) { Text(VoiceChoices.title($0)).tag($0) }
        } label: {
            HStack {
                Text(title)
                if model.saving == mode { ProgressView() }
            }
        }
        .disabled(model.saving != nil)
        .accessibilityIdentifier(id)
    }
}
