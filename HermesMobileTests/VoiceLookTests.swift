import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

/// The voice screen's look (#85, #86) and the voice archive's removal from the app (#87).
final class VoiceLookTests: XCTestCase {
    /// App source read from the checkout (`#filePath`), as `BotConnectionVersionTests` reads its pin.
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HermesMobileTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("Could not read \(url.path); the source tree is not present.")
        }
        return text
    }

    // MARK: #86 Speech-to-text + Hermes voice, settings gear and sheet

    @MainActor func testModeNamesShowCascadeVoiceAndGPTLive() {
        XCTAssertEqual(VoiceMode.normal.title, "Speech-to-text + Hermes voice")
        XCTAssertEqual(VoiceMode.live.title, "GPT-Live")
        XCTAssertEqual(VoiceMode.normal.modeLine, "Mode: Speech-to-text + Hermes voice")
        XCTAssertEqual(VoiceMode.live.modeLine, "Mode: GPT-Live")
        XCTAssertEqual(VoiceMode.normal.rawValue, "normal", "the stored value doesn't change")
        XCTAssertEqual(VoiceScreenModel.fallbackLine(reason: "This Hermes has no GPT-Live."),
                       "Using Speech-to-text + Hermes voice. This Hermes has no GPT-Live.")
        XCTAssertEqual(VoiceScreenModel.fallbackLine(reason: nil), "Using Speech-to-text + Hermes voice. Couldn't check GPT-Live.")
        XCTAssertEqual(VoiceSettingsView.modeFooter,
                       "GPT-Live is used when your Hermes offers it; otherwise voice starts in Speech-to-text + Hermes voice.")
    }

    /// No user-visible "Normal" is left in the voice screen's source (start menu, sheet, picker,
    /// footer, fallback line).
    func testNoUserFacingNormalLeftInVoiceScreen() throws {
        let voice = try source("HermesMobile/Features/Voice/VoiceScreen.swift")
        for literal in ["\"Normal\"", "Mode: Normal", "Using Normal", "starts in Normal"] {
            XCTAssertFalse(voice.contains(literal), literal)
        }
        XCTAssertFalse(voice.contains("voice-display-menu"), "the old display menu is gone")
    }

    /// The sheet's three switches write the same keys Settings › Voice does, and what the sheet
    /// writes is what the voice screen and the running call read.
    func testSheetSwitchesShareSettingsStorage() throws {
        XCTAssertEqual(VoiceCallSettingsSheet.storageKeys,
                       ["voice.show.thinkingAndTools", "voice.show.appends"])
        let settings = try source("HermesMobile/Features/Voice/VoiceScreen.swift")
        for key in ["showsThinkingAndToolsKey", "showsAppendsKey"] {
            XCTAssertTrue(settings.contains("@AppStorage(VoicePreferences.\(key))"), key)
        }
        let defaults = UserDefaults.standard
        let saved = VoiceCallSettingsSheet.storageKeys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(VoiceCallSettingsSheet.storageKeys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(false, forKey: VoicePreferences.showsThinkingAndToolsKey)
        defaults.set(true, forKey: VoicePreferences.showsAppendsKey)
        XCTAssertEqual(VoicePreferences.segmentFilter(defaults), TranscriptSegmentFilter(appends: true, thinkingAndTools: false))
    }

    /// Hosted: the sheet's switches are bound to the stored values (flip the stored value, the
    /// switch follows; flip the switch, the stored value follows).
    @MainActor func testSheetTogglesReadAndWriteTheStoredValues() async throws {
        let defaults = UserDefaults.standard
        let saved = VoiceCallSettingsSheet.storageKeys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(VoiceCallSettingsSheet.storageKeys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(true, forKey: VoicePreferences.showsThinkingAndToolsKey)
        defaults.set(false, forKey: VoicePreferences.showsAppendsKey)
        let host = UIHostingController(rootView: VoiceCallSettingsSheet(mode: .normal))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let switches = descendants(of: host.view).compactMap { $0 as? UISwitch }
            .sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
        XCTAssertEqual(switches.map { $0.isOn }, [true, false])
        guard switches.count == 2 else { return }
        switches[1].setOn(true, animated: false)
        switches[1].sendActions(for: UIControl.Event.valueChanged)
        XCTAssertEqual(defaults.object(forKey: VoicePreferences.showsAppendsKey) as? Bool, true)
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    // MARK: #85/#94 header buttons; #111 the orb alone at the top left

    /// At 402 pt (iPhone 17 Pro, the simulator's width) the header is the orb's 32 pt slot at the
    /// leading edge and the two buttons at the trailing edge, nothing between; the row is as
    /// tall as the buttons.
    @MainActor func testHeaderIsTheOrbThenTheButtonsAt402() throws {
        let bar = VoiceTopBar(orb: Color.clear.frame(width: VoiceOrbMetrics.headerSize, height: VoiceOrbMetrics.headerSize)
                                .frame(maxWidth: .infinity, alignment: .leading),
                              disabled: false, minimize: {}, settings: {})
        let host = UIHostingController(rootView: bar)
        let size = host.sizeThatFits(in: CGSize(width: 402, height: 1000))
        XCTAssertEqual(size.width, 402, accuracy: 0.5, "the row fills the width")
        XCTAssertEqual(size.height, VoiceHeaderButton.size + 12, accuracy: 0.5, "the buttons' height plus 8 above and 4 below")
    }

    /// Each output reading is stored with the time since the previous one (the circle animates
    /// between readings over exactly that time).
    @MainActor func testOutputLevelReadingsCarryTheirInterval() throws {
        let connection = BotConnection(id: UUID(), name: "t", address: try BotConnection.address("http://127.0.0.1:9"),
                                       username: "u", password: "p")
        let model = VoiceScreenModel(server: URL(string: "https://example.invalid")!, connection: connection, resumeSessionKey: nil)
        let t0 = Date(timeIntervalSince1970: 1000)
        model.noteOutputLevel(0.2, at: t0)
        XCTAssertEqual(model.outputLevel, 0.2)
        XCTAssertEqual(model.outputLevelInterval, 0)
        model.noteOutputLevel(0.05, at: t0.addingTimeInterval(0.043))
        XCTAssertEqual(model.outputLevel, 0.05)
        XCTAssertEqual(model.outputLevelInterval, 0.043, accuracy: 0.0001)
    }

    /// The minimize button left the status panel: it and the gear are separate header buttons.
    func testMinimizeAndGearAreTheirOwnButtons() throws {
        let chrome = try source("HermesMobile/Features/Voice/VoiceScreenChrome.swift")
        XCTAssertTrue(chrome.contains("VoiceHeaderButton(systemImage: \"chevron.down\""))
        XCTAssertTrue(chrome.contains("VoiceHeaderButton(systemImage: \"gearshape.fill\""))
    }

    // MARK: #87 Voice archive out of the app

    /// No entry point opens the archive: not the chat menu, not the voice screen. Storing stays
    /// (`VoiceArchiveTests`, `VoiceArchiveHTTPTests` cover the outbox, client, store and wire).
    func testVoiceArchiveHasNoEntryPointInTheApp() throws {
        let chat = try source("HermesMobile/Features/Chat/ChatView.swift")
        XCTAssertFalse(chat.contains("chat-voice-archive"))
        XCTAssertFalse(chat.contains("Voice archive"))
        XCTAssertFalse(chat.contains("VoiceArchiveSheet"))
        let voice = try source("HermesMobile/Features/Voice/VoiceScreen.swift")
        XCTAssertFalse(voice.contains("voice-archive-save-error"))
        XCTAssertFalse(voice.contains("archiveProblem"))
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Features/Voice")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(files.contains("VoiceArchiveView.swift"))
        XCTAssertFalse(files.contains("VoiceArchiveProjection.swift"))
    }

    /// Calls are still stored: the store hands out a recorder whose records reach the outbox.

}
