import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

/// The voice orb (#92, redrawn as J in #103), its flight (#93), the header's buttons (#94), the
/// glass pill (#104) and the bubble's release (#96).
final class VoiceOrbTests: XCTestCase {
    // MARK: #92 level → orb

    /// Each mode's level maps onto 0…1 on its own measured dB window: the floor is still, the
    /// ceiling is full, halfway in dB is half.
    func testLevelScalesMapTheMeasuredWindows() {
        func linear(_ db: Double) -> Float { Float(pow(10, db / 20)) }
        for scale in [VoiceOrbLevelScale.cascadeOutput, .liveOutput, .cascadeInput, .liveInput] {
            XCTAssertEqual(scale.fraction(0), 0)
            XCTAssertEqual(scale.fraction(linear(scale.floorDB - 10)), 0, accuracy: 0.0001)
            XCTAssertEqual(scale.fraction(linear(scale.floorDB)), 0, accuracy: 0.0001)
            XCTAssertEqual(scale.fraction(linear((scale.floorDB + scale.ceilingDB) / 2)), 0.5, accuracy: 0.001)
            XCTAssertEqual(scale.fraction(linear(scale.ceilingDB)), 1, accuracy: 0.0001)
            XCTAssertEqual(scale.fraction(1), 1, "capped")
        }
        XCTAssertEqual(VoiceOrbLevelScale.output(.normal), .cascadeOutput)
        XCTAssertEqual(VoiceOrbLevelScale.output(.live), .liveOutput)
        XCTAssertEqual(VoiceOrbLevelScale.input(.normal), .cascadeInput)
        XCTAssertEqual(VoiceOrbLevelScale.input(.live), .liveInput)
        // The measured medians land mid-range, not pinned at either end.
        XCTAssertEqual(VoiceOrbLevelScale.cascadeOutput.fraction(linear(-22.8)), 0.78, accuracy: 0.02)
        XCTAssertEqual(VoiceOrbLevelScale.liveOutput.fraction(linear(-15.6)), 0.78, accuracy: 0.02)
    }

    /// Fast rise (most of a syllable within ~3 Cascade readings of 43 ms), slower fall.
    func testEnvelopeRisesFastFallsSlowly() {
        var pulse: CGFloat = 0
        for _ in 0..<3 { pulse = VoiceOrbEnvelope.follow(pulse, toward: 1, over: 0.043) }
        XCTAssertGreaterThan(pulse, 0.9)
        let peak = pulse
        pulse = VoiceOrbEnvelope.follow(pulse, toward: 0, over: 0.043)
        XCTAssertGreaterThan(pulse, peak * 0.8, "one quiet reading doesn't collapse it")
        for _ in 0..<30 { pulse = VoiceOrbEnvelope.follow(pulse, toward: 0, over: 0.043) }
        XCTAssertLessThan(pulse, 0.01)
        XCTAssertEqual(VoiceOrbEnvelope.follow(0.4, toward: 1, over: 0), 0.4)
        // GPT-Live's 100 ms readings: one loud reading already carries most of the way.
        XCTAssertGreaterThan(VoiceOrbEnvelope.follow(0, toward: 1, over: 0.1), 0.85)
    }

    /// The orb's state per phase (#108): the user's whole turn is one state; the session's
    /// `.hearing` phase (its endpointer heard speech) draws the same orb as `.listening`.
    func testOrbStatePerPhase() {
        func state(_ phase: VoiceSession.Phase, working: Bool = false, attention: Bool = false, muted: Bool = false, ending: Bool = false) -> VoiceOrbState {
            VoiceOrbState.of(phase: phase, hermesWorking: working, attention: attention, muted: muted, ending: ending)
        }
        XCTAssertEqual(state(.connecting), .quiet)
        XCTAssertEqual(state(.listening), .listening)
        XCTAssertEqual(state(.hearing), .listening, "the user's turn is one orb state, whatever the internal phase")
        XCTAssertEqual(state(.listening, working: true), .working)
        XCTAssertEqual(state(.hearing, working: true), .working)
        XCTAssertEqual(state(.listening, muted: true), .quiet)
        XCTAssertEqual(state(.hearing, muted: true), .quiet)
        XCTAssertEqual(state(.sending), .working)
        XCTAssertEqual(state(.working(nil)), .working)
        XCTAssertEqual(state(.speaking), .speaking)
        XCTAssertEqual(state(.speaking, attention: true), .attention)
        XCTAssertEqual(state(.speaking, ending: true), .quiet)
        XCTAssertEqual(state(.ended(nil)), .quiet)
    }

    // MARK: #103 the J orb

    /// State → flat colour: blue while listening and speaking; indigo working; orange
    /// when it needs you; grey while quiet.
    func testStateColours() {
        XCTAssertEqual(VoiceOrbLook.colorHex(.listening), 0x0A84FF)
        XCTAssertEqual(VoiceOrbLook.colorHex(.speaking), 0x0A84FF)
        XCTAssertEqual(VoiceOrbLook.colorHex(.working), 0x5E5CE6)
        XCTAssertEqual(VoiceOrbLook.colorHex(.attention), 0xFF9500)
        XCTAssertEqual(VoiceOrbLook.colorHex(.quiet), 0x8E8E93)
    }

    /// The grid: 13-unit pitch centred on the middle, every dot centre inside radius 46 (as
    /// the mockup builds it: 7 × 7 lattice cut to a circle).
    func testDotGrid() {
        XCTAssertTrue(VoiceOrbLook.dots.contains(.zero))
        XCTAssertTrue(VoiceOrbLook.dots.allSatisfy { hypot($0.x, $0.y) <= 46 })
        XCTAssertEqual(VoiceOrbLook.dots.count, 37)
        XCTAssertTrue(VoiceOrbLook.dots.contains(CGPoint(x: 39, y: 0)))
        XCTAssertFalse(VoiceOrbLook.dots.contains(CGPoint(x: 39, y: 26)), "47 units out: cut")
    }

    /// Level → wave amplitude, dot size and opacity (mockup M, #108): the user's turn follows the
    /// mic from silence (0.05: nearly still and dim); Hermes speaking takes the louder voice.
    func testLevelToAmplitudeAndDots() {
        XCTAssertEqual(VoiceOrbLook.amplitude(.listening, output: 0, input: 0), 0.05, accuracy: 0.0001, "silent: near still")
        XCTAssertEqual(VoiceOrbLook.amplitude(.listening, output: 0, input: 0.5), 0.525, accuracy: 0.0001)
        XCTAssertEqual(VoiceOrbLook.amplitude(.listening, output: 0, input: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(VoiceOrbLook.amplitude(.listening, output: 1, input: 0), 0.05, accuracy: 0.0001,
                       "the user's turn: only the mic drives the dots")
        XCTAssertEqual(VoiceOrbLook.amplitude(.listening, output: 0, input: 3), 1, accuracy: 0.0001, "capped")
        XCTAssertEqual(VoiceOrbLook.amplitude(.speaking, output: 0, input: 0), 0.05, accuracy: 0.0001)
        XCTAssertEqual(VoiceOrbLook.amplitude(.speaking, output: 0.6, input: 0.2), 0.62, accuracy: 0.0001, "Hermes louder")
        XCTAssertEqual(VoiceOrbLook.amplitude(.speaking, output: 0.2, input: 0.8), 0.81, accuracy: 0.0001, "a louder cut-in drives them")
        XCTAssertEqual(VoiceOrbLook.amplitude(.working, output: 1, input: 1), 0.6)
        XCTAssertEqual(VoiceOrbLook.amplitude(.attention, output: 1, input: 1), 0.35)
        XCTAssertEqual(VoiceOrbLook.amplitude(.quiet, output: 1, input: 1), 0)
        let rest = VoiceOrbLook.dot(amplitude: 1, lift: 0)
        XCTAssertEqual(rest.radius, 2.2, accuracy: 0.0001)
        XCTAssertEqual(rest.opacity, 0.22, accuracy: 0.0001)
        let top = VoiceOrbLook.dot(amplitude: 1, lift: 1)
        XCTAssertEqual(top.radius, 4.8, accuracy: 0.0001)
        XCTAssertEqual(top.opacity, 0.77, accuracy: 0.0001)
        // Silent turn: the wave's crest barely lifts a dot (≤ 0.13 units of radius, +0.03 opacity).
        let silent = VoiceOrbLook.dot(amplitude: VoiceOrbLook.amplitude(.listening, output: 0, input: 0), lift: 1)
        XCTAssertEqual(silent.radius, 2.33, accuracy: 0.0001)
        XCTAssertEqual(silent.opacity, 0.2475, accuracy: 0.0001)
        // The wave runs outward: a crest at distance d moves to a larger d as the phase grows.
        XCTAssertEqual(VoiceOrbLook.lift(distance: 0, phase: 0), 0.5, accuracy: 0.0001)
        let crest0 = (0...460).map { CGFloat($0) / 10 }.max { VoiceOrbLook.lift(distance: $0, phase: 0) < VoiceOrbLook.lift(distance: $1, phase: 0) }!
        let crest1 = (0...460).map { CGFloat($0) / 10 }.max { VoiceOrbLook.lift(distance: $0, phase: 0.1) < VoiceOrbLook.lift(distance: $1, phase: 0.1) }!
        XCTAssertGreaterThan(crest1, crest0)
        // Louder: the wave runs faster, with either voice.
        XCTAssertGreaterThan(VoiceOrbLook.waveSpeed(.speaking, output: 1, input: 0), VoiceOrbLook.waveSpeed(.speaking, output: 0, input: 0))
        XCTAssertGreaterThan(VoiceOrbLook.waveSpeed(.listening, output: 0, input: 1), VoiceOrbLook.waveSpeed(.listening, output: 0, input: 0))
        XCTAssertEqual(VoiceOrbLook.waveSpeed(.quiet, output: 1, input: 1), 0)
    }

    /// Hermes's halo with the played level; on the user's turn the halo breathes only while it's
    /// quiet and fades with the mic (gone from a third of the mic's range); a ring only while
    /// working (faint, under the arc) and needing you, never for a voice (#108).
    func testHaloAndRing() throws {
        let quietHalo = try XCTUnwrap(VoiceOrbLook.halo(.speaking, output: 0, input: 0, breath: 0))
        XCTAssertEqual(quietHalo.scale, 1.08, accuracy: 0.0001)
        XCTAssertEqual(quietHalo.opacity, 0.14, accuracy: 0.0001)
        let loudHalo = try XCTUnwrap(VoiceOrbLook.halo(.speaking, output: 1, input: 0, breath: 0))
        XCTAssertEqual(loudHalo.scale, 1.52, accuracy: 0.0001)
        XCTAssertEqual(loudHalo.scale, VoiceOrbLook.haloReach)
        XCTAssertEqual(loudHalo.opacity, 0.30, accuracy: 0.0001)
        XCTAssertEqual(VoiceOrbLook.halo(.speaking, output: 0.5, input: 1, breath: 0)?.scale,
                       VoiceOrbLook.halo(.speaking, output: 0.5, input: 0, breath: 0)?.scale, "the mic never sizes Hermes's halo")
        // The user's turn: breathing while quiet, fading with the mic.
        let still = try XCTUnwrap(VoiceOrbLook.halo(.listening, output: 0, input: 0, breath: 0.5))
        XCTAssertEqual(still.opacity, 0.125, accuracy: 0.0001)
        let low = try XCTUnwrap(VoiceOrbLook.halo(.listening, output: 0, input: 0.1, breath: 0.5))
        XCTAssertEqual(low.opacity, 0.125 * 0.7, accuracy: 0.0001)
        XCTAssertNil(VoiceOrbLook.halo(.listening, output: 0, input: 1.0 / 3, breath: 0.5), "gone at a third of the range")
        XCTAssertNil(VoiceOrbLook.halo(.listening, output: 0, input: 0.8, breath: 1))
        XCTAssertNil(VoiceOrbLook.halo(.working, output: 1, input: 1, breath: 0))
        // Rings: never for a voice.
        XCTAssertNil(VoiceOrbLook.ring(.listening), "no ring for the user's voice")
        XCTAssertNil(VoiceOrbLook.ring(.speaking), "Hermes's voice is the halo, not the ring")
        XCTAssertNil(VoiceOrbLook.ring(.quiet))
        XCTAssertEqual(VoiceOrbLook.ring(.attention)?.width, 2)
        XCTAssertEqual(VoiceOrbLook.ring(.attention)?.opacity, 1)
        XCTAssertEqual(VoiceOrbLook.ring(.working)?.opacity, 0.15)
        XCTAssertEqual(VoiceOrbLook.breathSeconds, 3.2)
        XCTAssertEqual(VoiceOrbLook.breath(at: 0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(VoiceOrbLook.breath(at: 0.8), 1, accuracy: 0.0001)
    }

    /// The hearing-only pieces are gone from the orb and the header (#108): no hearing state, no
    /// "Hearing you" word.
    func testNoHearingStateOrWord() throws {
        let orb = try source("HermesMobile/Features/Voice/VoiceOrb.swift")
        XCTAssertFalse(orb.contains("case hearing"), "no hearing orb state")
        XCTAssertFalse(orb.contains("ring(.hearing"))
        let screen = try source("HermesMobile/Features/Voice/VoiceScreen.swift")
        XCTAssertFalse(screen.contains("\"Hearing you\""), "the header says Listening through the user's turn")
        XCTAssertEqual(VoiceStatusText.orb(phase: .hearing, status: VoiceHermesStatus(), muted: false, ending: false), "Listening")
        XCTAssertEqual(VoiceStatusText.orb(phase: .hearing, status: VoiceHermesStatus(), muted: true, ending: false), "Paused, muted")
    }

    /// The glide draws the enveloped level from where it was to the new reading over the time
    /// between readings, then holds.
    func testGlideBetweenReadings() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var glide = VoiceOrbGlide()
        glide = glide.next(0.8, at: t0, interval: 0.1)
        XCTAssertEqual(glide.value(at: t0), 0, accuracy: 0.0001)
        XCTAssertEqual(glide.value(at: t0.addingTimeInterval(0.05)), 0.4, accuracy: 0.0001)
        XCTAssertEqual(glide.value(at: t0.addingTimeInterval(0.5)), 0.8, accuracy: 0.0001)
        // A reading mid-glide starts from the drawn value, so nothing jumps.
        let mid = glide.next(0.2, at: t0.addingTimeInterval(0.05), interval: 0.1)
        XCTAssertEqual(mid.value(at: t0.addingTimeInterval(0.05)), 0.4, accuracy: 0.0001)
        XCTAssertEqual(VoiceOrbGlide().next(0.6, at: t0, interval: 0).value(at: t0), 0.6, "first reading: no interval")
    }

    /// The deleted pieces of the old orb stay deleted (#103): no edge deformation, no swell,
    /// no gradient fill, no highlight, no shadow.
    func testOrbIsFlat() throws {
        let orb = try source("HermesMobile/Features/Voice/VoiceOrb.swift")
        for gone in ["VoiceOrbShape", "scaleEffect", "Gradient", ".shadow(", "plusLighter", ".gradient"] {
            XCTAssertFalse(orb.contains(gone), gone)
        }
        XCTAssertTrue(orb.contains("Canvas {"), "drawn in one canvas, not a view per dot")
    }

    /// The model feeds both levels through the envelope on its mode's scale, with intervals.
    @MainActor func testModelPulsesFollowReadings() throws {
        let connection = BotConnection(id: UUID(), name: "t", address: try BotConnection.address("http://127.0.0.1:9"),
                                       username: "u", password: "p")
        let model = VoiceScreenModel(server: URL(string: "https://example.invalid")!, connection: connection, resumeSessionKey: nil)
        let t0 = Date(timeIntervalSince1970: 1000)
        model.noteInputLevel(0.2, at: t0)
        XCTAssertEqual(model.level, 0.2)
        XCTAssertEqual(model.inputPulse, 0, "the first reading has no interval to move over")
        model.noteInputLevel(0.2, at: t0.addingTimeInterval(0.043))
        XCTAssertEqual(model.inputLevelInterval, 0.043, accuracy: 0.0001)
        XCTAssertGreaterThan(model.inputPulse, 0.4)
        XCTAssertEqual(model.inputGlide.to, model.inputPulse)
        XCTAssertEqual(model.inputGlide.over, 0.043, accuracy: 0.0001)
        // Silence: readings every 100 ms for 1.5 s (the 250 ms fall: e^-6 of the peak).
        for i in 1...15 { model.noteInputLevel(0, at: t0.addingTimeInterval(0.043 + 0.1 * Double(i))) }
        XCTAssertLessThan(model.inputPulse, 0.01)
        model.noteOutputLevel(0.1, at: t0)
        model.noteOutputLevel(0.1, at: t0.addingTimeInterval(0.043))
        XCTAssertGreaterThan(model.outputGlide.to, 0.4)
    }

    // MARK: #93/#112 orb slots

    /// Expanded, the orb is in the header from the start (#112: no centre slot); minimized, the
    /// bubble.
    func testOrbSlot() {
        XCTAssertEqual(VoiceOrbSlot.current(expanded: true), .header)
        XCTAssertEqual(VoiceOrbSlot.current(expanded: false), .bubble)
    }

    /// The header orb is 30–32 pt, its drawing holds the full halo,
    /// and its halo and ring fit the header row (as tall as the buttons beside it).
    func testHeaderOrbFitsTheRow() {
        XCTAssertTrue((30...32).contains(VoiceOrbMetrics.headerSize))
        let radius = VoiceOrbMetrics.headerSize / 2
        let reach = max(radius * 1.52, radius * VoiceOrbLook.ringRadius + 2)
        XCTAssertLessThanOrEqual(2 * reach, VoiceHeaderButton.size, "halo and ring inside the row's height")
        XCTAssertGreaterThanOrEqual(VoiceOrbMetrics.drawingScale, 1.52, "the canvas holds the full halo")
    }

    /// The header is the orb alone (#111): no pill, no glass panel, no status word, no meter.
    func testHeaderIsOnlyTheOrb() throws {
        let chrome = try source("HermesMobile/Features/Voice/VoiceScreenChrome.swift")
        let screen = try source("HermesMobile/Features/Voice/VoiceScreen.swift")
        XCTAssertFalse(chrome.contains("RoundedRectangle(cornerRadius: 18"), "no pill")
        for gone in ["VoiceStatusPanel", "VoiceLiveMeter", "VoiceLevelMeter", "VoiceHeaderText", "centreSize", ".centre"] {
            XCTAssertFalse(chrome.contains(gone), gone)
            XCTAssertFalse(screen.contains(gone), gone)
        }
        let orb = try source("HermesMobile/Features/Voice/VoiceOrb.swift")
        XCTAssertFalse(orb.contains("case header, centre"), "no centre slot")
        XCTAssertFalse(orb.contains("centreSize"))
    }

    // MARK: #111 the status without a word

    /// The orb's VoiceOver label says the call's status (#111), including Ending (#70) and a
    /// muted mic.
    func testOrbAccessibilityStatus() {
        var thinking = VoiceHermesStatus(); thinking.apply("message.start", .object([:]), at: Date())
        let idle = VoiceHermesStatus()
        XCTAssertEqual(VoiceStatusText.orb(phase: .listening, status: idle, muted: false, ending: false), "Listening")
        XCTAssertEqual(VoiceStatusText.orb(phase: .listening, status: idle, muted: true, ending: false), "Paused, muted")
        XCTAssertEqual(VoiceStatusText.orb(phase: .speaking, status: idle, muted: false, ending: false), "Speaking")
        XCTAssertEqual(VoiceStatusText.orb(phase: .working(nil), status: thinking, muted: false, ending: false), "Thinking")
        XCTAssertEqual(VoiceStatusText.orb(phase: .working(nil), status: idle, muted: false, ending: false), "Working")
        XCTAssertEqual(VoiceStatusText.orb(phase: .speaking, status: idle, muted: false, ending: true), "Ending…")
        XCTAssertEqual(VoiceStatusText.orb(phase: .ended("Connection lost."), status: idle, muted: false, ending: false), "Ended")
    }

    /// An ended call's reason goes to the notices above the dock (#111); a plain end, a running
    /// call and End (#70) show none.
    func testEndedReasonGoesToTheNotices() throws {
        XCTAssertEqual(VoiceStatusText.endedReason(phase: .ended("Connection lost."), ending: false), "Connection lost.")
        XCTAssertEqual(VoiceStatusText.endedReason(phase: .ended("Couldn't connect to Hermes."), ending: false),
                       "Couldn't connect to Hermes.")
        XCTAssertNil(VoiceStatusText.endedReason(phase: .ended(nil), ending: false))
        XCTAssertNil(VoiceStatusText.endedReason(phase: .listening, ending: false))
        XCTAssertNil(VoiceStatusText.endedReason(phase: .ended("Connection lost."), ending: true))
        let screen = try source("HermesMobile/Features/Voice/VoiceScreen.swift")
        let notices = try XCTUnwrap(screen.range(of: "private var notices: some View"))
        let dock = try XCTUnwrap(screen.range(of: "private var dock: some View"))
        let block = screen[notices.upperBound..<dock.lowerBound]
        XCTAssertTrue(block.contains("VoiceStatusText.endedReason"), "the reason is one of the notices")
        XCTAssertTrue(block.contains("\"voice-ended-reason\""))
    }

    // MARK: #112 the opening

    /// The pre-#92 hint: "Connecting to Hermes…" until the engine listens, then "Go ahead, I'm
    /// listening."; shown while the call has nothing to draw.
    @MainActor func testEmptyHint() {
        XCTAssertEqual(VoiceScreen.emptyHintText(phase: nil), "Connecting to Hermes…")
        XCTAssertEqual(VoiceScreen.emptyHintText(phase: .connecting), "Connecting to Hermes…")
        XCTAssertEqual(VoiceScreen.emptyHintText(phase: .listening), "Go ahead, I'm listening.")
        XCTAssertEqual(VoiceScreen.emptyHintText(phase: .hearing), "Go ahead, I'm listening.")
        let transcript = VoiceTranscriptModel()
        XCTAssertTrue(VoiceScreen.showsEmptyHint(transcript, mode: .full, showsAppends: true))
        transcript.isLoadingHistory = true
        XCTAssertFalse(VoiceScreen.showsEmptyHint(transcript, mode: .full, showsAppends: true), "saved history loading")
        transcript.isLoadingHistory = false
        transcript.loadHistory([ChatMessage(role: "user", content: "Hi", timestamp: 1, messageId: nil)], hasOlder: false)
        XCTAssertFalse(VoiceScreen.showsEmptyHint(transcript, mode: .full, showsAppends: true), "the first message")
    }

    // MARK: #94 header buttons

    func testHeaderButtonsAreGearThenCollapse() {
        XCTAssertEqual(VoiceTopBar<EmptyView>.buttonIdentifiers, ["voice-settings", "voice-minimize"])
    }

    /// The row's code lists the gear's button before collapse, last in the HStack (#94).
    func testHeaderRowListsGearThenCollapse() throws {
        let chrome = try source("HermesMobile/Features/Voice/VoiceScreenChrome.swift")
        let gear = try XCTUnwrap(chrome.range(of: "VoiceHeaderButton(systemImage: \"gearshape.fill\""))
        let collapse = try XCTUnwrap(chrome.range(of: "VoiceHeaderButton(systemImage: \"chevron.down\""))
        XCTAssertLessThan(gear.lowerBound, collapse.lowerBound)
    }

    // MARK: #96 bubble release

    func testDecelerationUsesTheFastRate() {
        XCTAssertEqual(VoiceBubbleDeceleration.rate, 0.99, accuracy: 0.0001)
        XCTAssertEqual(VoiceBubbleDeceleration.tau, 0.0995, accuracy: 0.0002)
        // A quick flick (1000 pt/s) coasts ~100 pt; a slow release (50 pt/s) ~5 pt.
        XCTAssertEqual(VoiceBubbleDeceleration.projection(1000), 99.5, accuracy: 0.5)
        XCTAssertEqual(VoiceBubbleDeceleration.projection(50), 4.97, accuracy: 0.05)
        XCTAssertEqual(VoiceBubbleDeceleration.projection(-1000), -99.5, accuracy: 0.5)
    }

    /// The curve only ever moves forward, only slows, and reaches the end without passing it.
    func testDecelerationCurveIsMonotonicWithNoOvershoot() {
        for distance in [3.0, 40, 100, 250] {
            let end = VoiceBubbleDeceleration.duration(distance: distance)
            XCTAssertGreaterThan(end, 0)
            var last = 0.0, lastStep = Double.infinity
            var t = 1.0 / 120
            while t < end {
                let p = VoiceBubbleDeceleration.progress(at: t, distance: distance)
                XCTAssertGreaterThanOrEqual(p, last)
                XCTAssertLessThanOrEqual(p, 1)
                let step = p - last
                XCTAssertLessThanOrEqual(step, lastStep + 1e-12, "speed never increases")
                last = p; lastStep = step
                t += 1.0 / 120
            }
            XCTAssertEqual(VoiceBubbleDeceleration.progress(at: end, distance: distance), 1)
        }
        XCTAssertEqual(VoiceBubbleDeceleration.duration(distance: 0.3), 0, "under half a point: no animation")
        // 100 pt takes about half a second.
        XCTAssertEqual(VoiceBubbleDeceleration.duration(distance: 100), 0.527, accuracy: 0.01)
    }

    private let bounds = CGSize(width: 402, height: 800)

    /// Released with no speed: the nearest side at the release height (as before #96).
    func testReleaseWithoutVelocityRestsAtTheReleaseHeight() {
        var placement = VoiceCallBubblePlacement()
        placement.drag = CGSize(width: -100, height: -300)
        let from = placement.position(in: bounds)
        let rest = placement.released(in: bounds)
        XCTAssertEqual(rest.side, .trailing)
        XCTAssertEqual(rest.position(in: bounds).y, from.y, accuracy: 0.001)
        XCTAssertEqual(rest.drag, .zero)
    }

    /// An upward flick keeps going up by velocity × τ; a slow release barely moves.
    func testReleaseCarriesTheVelocity() {
        var placement = VoiceCallBubblePlacement()
        placement.drag = CGSize(width: 0, height: -300)
        let from = placement.position(in: bounds)
        let quick = placement.released(in: bounds, velocity: CGSize(width: 0, height: -1000))
        XCTAssertEqual(from.y - quick.position(in: bounds).y, 99.5, accuracy: 0.5)
        let slow = placement.released(in: bounds, velocity: CGSize(width: 0, height: -50))
        XCTAssertEqual(from.y - slow.position(in: bounds).y, 4.97, accuracy: 0.05)
    }

    /// The side is the one nearest to where the coast ends, not where the finger lifted.
    func testReleaseSideFollowsTheCoast() {
        var placement = VoiceCallBubblePlacement()   // trailing
        placement.drag = CGSize(width: -130, height: 0)    // x = 402-12-42.56-130 = 217.4 (right half)
        XCTAssertEqual(placement.released(in: bounds).side, .trailing)
        XCTAssertEqual(placement.released(in: bounds, velocity: CGSize(width: -600, height: 0)).side, .leading)
    }

    /// Clamped on screen and above the message box.
    func testReleaseIsClamped() {
        var placement = VoiceCallBubblePlacement()
        placement.drag = CGSize(width: 0, height: -700)
        let top = placement.released(in: bounds, velocity: CGSize(width: 0, height: -3000))
        XCTAssertEqual(top.position(in: bounds).y, VoiceCallBubblePlacement.inset, accuracy: 0.001)
        placement.drag = .zero
        let low = placement.released(in: bounds, clearance: 80, velocity: CGSize(width: 0, height: 3000))
        XCTAssertEqual(low.position(in: bounds, clearance: 80).y,
                       800 - 80 - VoiceCallBubblePlacement.inset, accuracy: 0.001)
    }

    // MARK: #109 the bubble's halo stays on screen

    /// The placement reserves what the orb draws: the halo at full size reaches 1.52 × the
    /// 28 pt radius (42.56 pt) from the centre, and that whole extent rests `margin` inside the
    /// container on each side, after a plain release and after a fling either way.
    func testReservedExtentIncludesTheHalo() {
        XCTAssertEqual(VoiceCallBubblePlacement.reach, 42.56, accuracy: 0.001)
        XCTAssertEqual(VoiceCallBubblePlacement.reach, VoiceCallBubblePlacement.size / 2 * VoiceOrbLook.haloReach)
        let halo = try? XCTUnwrap(VoiceOrbLook.halo(.speaking, output: 1, input: 0, breath: 0))
        XCTAssertEqual((halo?.scale ?? 0) * VoiceCallBubblePlacement.size / 2, VoiceCallBubblePlacement.reach, accuracy: 0.001,
                       "the reserved reach is the halo the orb draws at full level")
        let reach = VoiceCallBubblePlacement.reach
        func extent(_ p: VoiceCallBubblePlacement) -> CGRect {
            let c = p.position(in: bounds)
            return CGRect(x: c.x - reach, y: c.y - reach, width: reach * 2, height: reach * 2)
        }
        var placement = VoiceCallBubblePlacement()
        let cases: [(String, CGSize, CGSize)] = [
            ("rest right", .zero, .zero),
            ("plain to the left", CGSize(width: -320, height: 0), .zero),
            ("fling left", CGSize(width: -150, height: 0), CGSize(width: -3000, height: 0)),
            ("fling right", CGSize(width: 0, height: 0), CGSize(width: 3000, height: 0)),
            ("fling up-left", CGSize(width: -200, height: -600), CGSize(width: -3000, height: -3000)),
        ]
        for (name, drag, velocity) in cases {
            placement.drag = drag
            let rest = placement.released(in: bounds, velocity: velocity)
            let e = extent(rest)
            XCTAssertEqual(min(e.minX, bounds.width - e.maxX), VoiceCallBubblePlacement.margin, accuracy: 0.001, name)
            XCTAssertGreaterThanOrEqual(e.minY, VoiceCallBubblePlacement.margin - 0.001, name)
            XCTAssertLessThanOrEqual(e.maxY, bounds.height - VoiceCallBubblePlacement.margin + 0.001, name)
            placement = rest
        }
    }

    /// The custom animation runs the curve and ends; no spring is left in the release.
    func testReleaseAnimationIsTheDecelerationNotASpring() throws {
        let overlay = try source("HermesMobile/Features/Voice/VoiceCallOverlay.swift")
        XCTAssertTrue(overlay.contains("Animation(VoiceBubbleDeceleration(distance: distance))"))
        XCTAssertFalse(overlay.contains(".spring("), "no spring on release")
    }

    // MARK: #93 one root layer

    func testCallScreenIsNoLongerAFullScreenCover() throws {
        let overlay = try source("HermesMobile/Features/Voice/VoiceCallOverlay.swift")
        XCTAssertFalse(overlay.contains(".fullScreenCover"))
        XCTAssertTrue(overlay.contains("matchedGeometryEffect(id: VoiceOrbSlot.matchID"))
        XCTAssertTrue(overlay.contains(".allowsHitTesting(!covered)"), "the app under the call takes no touches")
    }

    // MARK: #105 the transcript runs under the header

    /// The header is the voice screen's top safe-area inset, not a row stacked above the
    /// transcript: the transcript fills the screen, lays its first row out below the header,
    /// and scrolled rows pass under the pill and the buttons.
    func testHeaderIsTheTopSafeAreaInset() throws {
        let screen = try source("HermesMobile/Features/Voice/VoiceScreen.swift")
        let body = try XCTUnwrap(screen.range(of: "    var body: some View {\n        VStack(spacing: 0) {"))
        let inset = try XCTUnwrap(screen.range(of: ".safeAreaInset(edge: .top, spacing: 0) {\n            topBar",
                                               range: body.upperBound..<screen.endIndex))
        let firstRow = screen[body.upperBound..<inset.lowerBound]
        XCTAssertFalse(firstRow.contains("            topBar\n"), "the header is no longer the stack's first row")
    }

    // MARK: #106 the bubble clears the Chat button

    /// The chat list's numbers measured on the simulator (402 × 874, #106): the bottom buttons'
    /// top at y 760, the bubble layer's safe area ending at 840. The default spot keeps the whole
    /// bubble above the buttons with the margin between. Since #109 "the whole bubble" is what
    /// the orb draws there: the halo at full size.
    func testDefaultSpotClearsTheListButtons() {
        let layerMaxY: CGFloat = 840
        let buttonsTop: CGFloat = 760
        let bounds = CGSize(width: 402, height: layerMaxY - 62)
        let centre = VoiceCallBubblePlacement().center(in: bounds, clearance: layerMaxY - buttonsTop)
        let haloBottom = 62 + centre.y + VoiceCallBubblePlacement.reach
        XCTAssertEqual(haloBottom, buttonsTop - VoiceCallBubblePlacement.margin, accuracy: 0.001)
    }

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("no source tree") }
        return text
    }
}
