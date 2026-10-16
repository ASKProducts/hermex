import Foundation
import Observation
import SwiftUI

@MainActor @Observable final class VoiceModePreferenceModel {
    enum State: Equatable {
        case loading, loaded(VoiceMode), unreachable
    }
    typealias Fetch = @MainActor () async throws -> VoiceMode
    typealias Save = @MainActor (VoiceMode) async throws -> VoiceMode

    private(set) var state = State.loading
    private(set) var saving: VoiceMode?
    private(set) var failure: String?
    private let fetch: Fetch
    private let save: Save

    init(fetch: @escaping Fetch, save: @escaping Save) {
        self.fetch = fetch; self.save = save
    }

    func load() async {
        state = .loading
        do { state = .loaded(try await fetch()) } catch { state = .unreachable }
    }

    func select(_ mode: VoiceMode) async {
        guard case .loaded(let current) = state, current != mode else { return }
        saving = mode
        failure = nil
        defer { saving = nil }
        do { state = .loaded(try await save(mode)) }
        catch { failure = String(localized: "Couldn't change voice mode.") }
    }
}

struct VoiceModePreferenceSection: View {
    let model: VoiceModePreferenceModel

    var body: some View {
        Section {
            switch model.state {
            case .loading:
                ProgressView(String(localized: "Loading voice mode…"))
            case .unreachable:
                Text(VoiceChoicesModel.unreachableText).foregroundStyle(.secondary)
            case .loaded(let current):
                Picker(String(localized: "Default mode"), selection: Binding(
                    get: { current }, set: { next in Task { await model.select(next) } }
                )) {
                    Text(VoiceMode.normal.title).tag(VoiceMode.normal)
                    Text(VoiceMode.live.title).tag(VoiceMode.live)
                }
                .disabled(model.saving != nil)
                .accessibilityIdentifier("voice-default-mode")
            }
            if let failure = model.failure { Text(verbatim: failure).foregroundStyle(.red) }
        } header: {
            Text("Mode")
        } footer: {
            Text(VoiceSettingsView.modeFooter)
        }
    }
}
