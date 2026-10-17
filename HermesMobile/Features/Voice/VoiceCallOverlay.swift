import SwiftUI

/// screen while the call is expanded, the floating bubble while it is minimized, and the short
/// banner when a call ended on its own. The screen and the bubble are drawn in ONE layer over
/// (the header's top left, the bubble) with `matchedGeometryEffect` while the screen slides
/// and fades. While the screen is up the app under it takes no touches and VoiceOver skips it.
struct VoiceCallHost: ViewModifier {
    @Bindable var controller: VoiceCallController
    @Namespace private var orbSpace

    func body(content: Content) -> some View {
        let covered = controller.isExpanded && controller.call != nil
        content
            .allowsHitTesting(!covered)
            .accessibilityHidden(covered)
            .overlay { VoiceCallLayer(controller: controller, orbSpace: orbSpace) }
            .overlay(alignment: .top) {
                if let reason = controller.endedBanner {
                    VoiceCallEndedBanner(reason: reason) { controller.dismissBanner() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.25), value: controller.endedBanner)
            .onChange(of: covered) { _, up in
                // The app's keyboard (a chat's message box) doesn't stay up over the call screen.
                if up { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
    }
}

/// animation: the screen slides down and fades, the bubble's slot appears, and the orb travels
/// from the header to the bubble (and back on expand).
private struct VoiceCallLayer: View {
    let controller: VoiceCallController
    let orbSpace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let flight = Animation.smooth(duration: 0.45)

    var body: some View {
        let call = controller.call
        let expanded = controller.isExpanded
        let slot = VoiceOrbSlot.current(expanded: expanded)
        ZStack {
            if let call, expanded {
                VoiceScreen(call: call, controller: controller, orbSlot: slot, orbSpace: orbSpace)
                    .ignoresSafeArea(.keyboard)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.isModal)
            }
            if let call, !expanded {
                VoiceCallBubbleLayer(model: call.model, composerTop: controller.composerTop, orbSpace: orbSpace) {
                    controller.expand()
                }
            }
            if let call {
                VoiceOrb(model: call.model, ending: call.isEnding)
                    .matchedGeometryEffect(id: VoiceOrbSlot.matchID, in: orbSpace, isSource: false)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Self.flight, value: expanded)
    }
}

extension View {
    func voiceCallHost(_ controller: VoiceCallController) -> some View {
        modifier(VoiceCallHost(controller: controller))
    }
}

/// Reports the modified view (a screen's bottom controls) to the voice call so the floating
private struct VoiceBubbleClearance: ViewModifier {
    @State private var owner = UUID()
    @State private var onScreen = false
    @State private var top: CGFloat?
    private let controller = VoiceCallController.shared

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { value in
                top = value
                if onScreen { controller.reportBottomControls(owner: owner, top: value) }
            }
            .onAppear {
                onScreen = true
                if let top { controller.reportBottomControls(owner: owner, top: top) }
            }
            .onDisappear {
                onScreen = false
                controller.clearBottomControls(owner: owner)
            }
    }
}

extension View {
    func voiceBubbleClearance() -> some View { modifier(VoiceBubbleClearance()) }
}

/// Where the bubble rests: the screen side it snapped to and its height above the bottom of
/// the safe area (which includes the keyboard, so the bubble rides above it), plus how far
/// a drag in progress has moved it from there.
struct VoiceCallBubblePlacement: Equatable {
    enum Side: String { case leading, trailing }
    var side: Side = .trailing
    /// Distance from the bottom of the safe area to the bubble's centre.
    var bottom: CGFloat = VoiceCallBubblePlacement.defaultBottom
    /// The finger's translation while a drag is in progress; zero at rest. Kept in the same
    /// bubble's drawn position animates from where it was let go, never from the drag start.
    var drag: CGSize = .zero

    static let size: CGFloat = 56
    static let margin: CGFloat = 12
    /// placement keeps this whole extent, not just the 56 pt disc, `margin` inside the edges.
    static let reach: CGFloat = size / 2 * VoiceOrbLook.haloReach
    /// From an edge to the bubble's centre, at rest: the margin plus the drawn reach.
    static let inset: CGFloat = margin + reach
    /// As low as it goes: just above the message box when one is on screen (`clearance`),
    /// else just above the bottom edge.
    static let defaultBottom: CGFloat = inset

    /// The bubble's resting centre in a container of `bounds`, kept above a message box
    /// `clearance` tall at the bottom (0 = none).
    func center(in bounds: CGSize, clearance: CGFloat = 0) -> CGPoint {
        let x = side == .leading ? Self.inset : bounds.width - Self.inset
        return CGPoint(x: x, y: bounds.height - clampedBottom(in: bounds, clearance: clearance))
    }

    /// Where the bubble is drawn: its resting centre moved by the drag in progress.
    func position(in bounds: CGSize, clearance: CGFloat = 0) -> CGPoint {
        let center = center(in: bounds, clearance: clearance)
        return CGPoint(x: center.x + drag.width, y: center.y + drag.height)
    }

    func clampedBottom(in bounds: CGSize, clearance: CGFloat = 0) -> CGFloat {
        let low = clearance + Self.inset
        let high = max(low, bounds.height - Self.inset)
        return min(max(bottom, low), high)
    }

    /// The drag in progress ended at its current translation, moving at `velocity` (pt/s): the
    /// direction for the distance a scroll view decelerating at the fast rate would coast
    /// (`VoiceBubbleDeceleration.projection`), then rests on the nearest side to that point,
    /// kept on screen and above the message box.
    func released(in bounds: CGSize, clearance: CGFloat = 0, velocity: CGSize = .zero) -> Self {
        let from = position(in: bounds, clearance: clearance)
        let ahead = CGPoint(x: from.x + VoiceBubbleDeceleration.projection(velocity.width),
                            y: from.y + VoiceBubbleDeceleration.projection(velocity.height))
        var placement = Self()
        placement.side = ahead.x < bounds.width / 2 ? .leading : .trailing
        placement.bottom = bounds.height - ahead.y
        placement.bottom = placement.clampedBottom(in: bounds, clearance: clearance)
        return placement
    }
}

/// paging rate), with no spring, bounce or overshoot. Each frame the remaining velocity is
/// multiplied by the rate per millisecond, so the position follows
/// `x(t) = x0 + v·τ·(1 − e^(−t/τ))`, τ = −1 / (1000·ln rate), and the coast's whole distance is
/// `v·τ`. The bubble's end point can differ from `x0 + v·τ` (the nearest side, the clamps), so
/// the animation runs the same curve scaled to the actual distance: it starts at about the
/// release speed when unclamped, only ever slows, and arrives without passing its end.
struct VoiceBubbleDeceleration: CustomAnimation {
    static let rate = Double(UIScrollView.DecelerationRate.fast.rawValue)
    /// The curve's time constant: ≈ 0.0995 s at the fast rate.
    static var tau: Double { -1 / (1000 * log(rate)) }
    /// UIKit stops a deceleration once less than half a point remains.
    static let restDistance: Double = 0.5

    /// How far a release at `velocity` (pt/s) coasts: a 1000 pt/s flick ≈ 99.5 pt, 100 pt/s ≈ 10 pt.
    static func projection(_ velocity: CGFloat) -> CGFloat { velocity * CGFloat(tau) }

    /// The fraction of the way covered at `time`, for a move of `distance` points.
    static func progress(at time: TimeInterval, distance: Double) -> Double {
        let end = duration(distance: distance)
        guard end > 0, time < end else { return 1 }
        return (1 - exp(-time / tau)) / (1 - exp(-end / tau))
    }

    /// The time until less than `restDistance` of the decaying curve remains.
    static func duration(distance: Double) -> TimeInterval {
        guard distance > restDistance else { return 0 }
        return tau * log(distance / restDistance)
    }

    /// The largest distance any coordinate of this release moves.
    let distance: Double

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < Self.duration(distance: distance) else { return nil }
        return value.scaled(by: Self.progress(at: time, distance: distance))
    }
}

/// Lays the bubble out over the screen, inside the safe area (so the keyboard pushes it up),
/// and moves it with the finger. Only the bubble takes touches. The bubble is the call's orb
private struct VoiceCallBubbleLayer: View {
    let model: VoiceScreenModel?
    let composerTop: CGFloat?
    let orbSpace: Namespace.ID
    let open: () -> Void
    @State private var placement = VoiceCallBubblePlacement()

    var body: some View {
        GeometryReader { geo in
            // Space the message box takes at the bottom of this (safe-area) container.
            let clearance = composerTop.map { max(0, geo.frame(in: .global).maxY - $0) } ?? 0
            let position = placement.position(in: geo.size, clearance: clearance)
            VoiceCallBubble(model: model)
                .voiceOrbSource(true, in: orbSpace)
                .position(x: position.x, y: position.y)
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in placement.drag = value.translation }
                        .onEnded { value in
                            placement.drag = value.translation
                            let from = placement.position(in: geo.size, clearance: clearance)
                            let rest = placement.released(in: geo.size, clearance: clearance, velocity: value.velocity)
                            let to = rest.position(in: geo.size, clearance: clearance)
                            let distance = max(abs(Double(to.x - from.x)), abs(Double(to.y - from.y)))
                            withAnimation(Animation(VoiceBubbleDeceleration(distance: distance))) {
                                placement = rest
                            }
                        }
                )
                .simultaneousGesture(TapGesture().onEnded(open))
        }
        .animation(.smooth(duration: 0.25), value: composerTop)
    }
}

struct VoiceCallBubble: View {
    let model: VoiceScreenModel?

    var body: some View {
        let attention = model?.needsAttention == true
        let working = model?.hermesWorking == true
        Color.clear
            .frame(width: VoiceCallBubblePlacement.size, height: VoiceCallBubblePlacement.size)
            .contentShape(Circle())
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(String(localized: "Voice call"))
            .accessibilityValue(accessibilityValue(attention: attention, working: working))
            .accessibilityIdentifier("voice-bubble")
    }

    private func accessibilityValue(attention: Bool, working: Bool) -> String {
        if attention { return String(localized: "Needs you") }
        if model?.muted == true { return String(localized: "Muted") }
        guard let phase = model?.engineSession?.phase else { return "" }
        switch phase {
        case .speaking: return String(localized: "Speaking")
        case .listening, .hearing: return working ? String(localized: "Listening, Hermes working") : String(localized: "Listening")
        case .sending, .working: return String(localized: "Working")
        case .connecting: return String(localized: "Connecting")
        case .ended: return String(localized: "Ended")
        }
    }
}

/// "Voice call ended: <why>" at the top of the screen; it goes by itself or on tap.
private struct VoiceCallEndedBanner: View {
    let reason: String
    let close: () -> Void

    var body: some View {
        Button(action: close) {
            Label(reason, systemImage: "waveform.slash")
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .adaptiveGlass(in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .accessibilityIdentifier("voice-ended-banner")
    }
}
