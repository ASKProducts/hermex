import SwiftUI

/// disc that never changes size, with a grid of bold white dots inside it. A wave of dot size and
/// opacity runs outward from the centre; on the user's turn and while Hermes speaks its strength
/// is the live voice level. No gradient, gloss, highlight or shadow. Around the disc:
/// - Hermes speaking: a flat halo behind the disc, larger and stronger with the played level.
/// - The user's turn: the halo breathes faintly while it's quiet and fades as they speak.
/// - Hermes thinking or working: the disc turns indigo, an arc spins on a faint ring.
/// - Needs you: the disc turns orange, with a full ring.
/// The call layer draws ONE orb and moves it between its slots (the header's top left, the
enum VoiceOrbState: Equatable {
    /// Connecting, ended, ending, muted while nothing plays: grey and still.
    case quiet
    /// session's endpointer phase): the dots follow the mic from silence.
    case listening
    /// Hermes speaks: the halo follows the played level, the dots the louder of the two voices.
    case speaking
    /// Sending, working, thinking (also while listening during a background turn).
    case working
    /// Hermes waits on the user (approval, clarify).
    case attention

    static func of(phase: VoiceSession.Phase, hermesWorking: Bool, attention: Bool, muted: Bool, ending: Bool) -> Self {
        if ending { return .quiet }
        if attention { return .attention }
        switch phase {
        case .connecting, .ended: return .quiet
        case .speaking: return .speaking
        case .sending, .working: return .working
        case .listening, .hearing:
            if hermesWorking { return .working }
            if muted { return .quiet }
            return .listening
        }
    }
}

struct VoiceOrbLevelScale: Equatable {
    let floorDB: Double
    let ceilingDB: Double

    /// Cascade, played reply (main mixer tap): speech p10 -32.1, p50 -22.8, p90 -18.3, max -15.9 dBFS.
    static let cascadeOutput = Self(floorDB: -40, ceilingDB: -18)
    /// GPT-Live, played reply (inbound-rtp audioLevel): p10 -24.1, p50 -15.6, p90 -11.5, max -8.6 dB.
    static let liveOutput = Self(floorDB: -32, ceilingDB: -11)
    /// Cascade, mic (meter window max): p10 -34.1, p50 -20.8, p90 -15.0, max -11.8 dBFS.
    static let cascadeInput = Self(floorDB: -40, ceilingDB: -15)
    /// GPT-Live, mic (media-source audioLevel): p10 -22.5, p50 -10.1, p90 -3.5, max -1.9 dB.
    static let liveInput = Self(floorDB: -30, ceilingDB: -4)

    static func output(_ mode: VoiceMode) -> Self { mode == .live ? liveOutput : cascadeOutput }
    static func input(_ mode: VoiceMode) -> Self { mode == .live ? liveInput : cascadeInput }

    func fraction(_ level: Float) -> CGFloat {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return CGFloat(min(1, max(0, (db - floorDB) / (ceilingDB - floorDB))))
    }
}

/// The orb's level envelope: rises with a syllable within ~50 ms and falls over ~250 ms, so a
/// syllable reads as one pulse and the gaps between readings don't flicker.
enum VoiceOrbEnvelope {
    static let rise: TimeInterval = 0.05
    static let fall: TimeInterval = 0.25
    static func follow(_ current: CGFloat, toward target: CGFloat, over interval: TimeInterval) -> CGFloat {
        guard interval > 0 else { return current }
        let tau = target > current ? rise : fall
        return current + (target - current) * CGFloat(1 - exp(-interval / tau))
    }
}

/// One enveloped level as the orb draws it: from the value it had when the latest reading
/// arrived to the new one, linearly over the time between the last two readings (the reading
/// rate: Cascade's taps ~43 ms, GPT-Live's stats 100 ms). A pure function of the drawing time.
struct VoiceOrbGlide: Equatable {
    var from: CGFloat = 0
    var to: CGFloat = 0
    var at: Date = .distantPast
    var over: TimeInterval = 0

    func value(at date: Date) -> CGFloat {
        guard over > 0 else { return to }
        let k = CGFloat(min(1, max(0, date.timeIntervalSince(at) / over)))
        return from + (to - from) * k
    }

    /// A new reading `value` at `now`, `interval` after the previous one.
    func next(_ value: CGFloat, at now: Date, interval: TimeInterval) -> Self {
        Self(from: self.value(at: now), to: value, at: now, over: interval)
    }
}

/// Sizes.
enum VoiceOrbMetrics {
    static let headerSize: CGFloat = 32
    /// The halo reaches 1.52 × the disc's radius: the drawing's frame is this many discs wide.
    static let drawingScale: CGFloat = 1.6
}

enum VoiceOrbLook {
    static let discRadius: CGFloat = 50
    /// The dot grid: 13-unit pitch centred on the middle, dots whose centre is inside radius 46.
    static let pitch: CGFloat = 13
    static let gridLimit: CGFloat = 46
    /// Flat colours (sRGB hex): system blue, indigo, orange; grey while quiet.
    static let blue: UInt32 = 0x0A84FF
    static let indigo: UInt32 = 0x5E5CE6
    static let orange: UInt32 = 0xFF9500
    static let grey: UInt32 = 0x8E8E93
    /// The listening halo's breath period.
    static let breathSeconds: Double = 3.2
    /// The thinking arc: 22% of the ring, turning 220°/s.
    static let arcFraction: CGFloat = 0.22
    static let arcDegreesPerSecond: Double = 220
    /// The ring's radius (thinking, needs you): 1.24 × the disc's.
    static let ringRadius: CGFloat = 1.24
    /// The halo's largest radius (Hermes at full level): 1.52 × the disc's. The farthest the orb
    static let haloReach: CGFloat = 1.52

    static func colorHex(_ state: VoiceOrbState) -> UInt32 {
        switch state {
        case .quiet: return grey
        case .listening, .speaking: return blue
        case .working: return indigo
        case .attention: return orange
        }
    }

    static func color(_ state: VoiceOrbState) -> Color {
        let hex = colorHex(state)
        return Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }

    /// The grid's dot centres, in units from the disc's centre.
    static let dots: [CGPoint] = {
        let steps = Int((gridLimit / pitch).rounded(.down))
        var points: [CGPoint] = []
        for row in -steps...steps {
            for column in -steps...steps {
                let point = CGPoint(x: CGFloat(column) * pitch, y: CGFloat(row) * pitch)
                if hypot(point.x, point.y) <= gridLimit { points.append(point) }
            }
        }
        return points
    }()

    /// How strongly the wave lifts the dots. `output` is Hermes's played level and `input` the
    /// 0.05 when silent, so the dots sit nearly still and dim); while Hermes speaks the louder
    /// voice drives them, so a cut-in shows. Fixed while working or waiting on the user.
    static func amplitude(_ state: VoiceOrbState, output: CGFloat, input: CGFloat) -> CGFloat {
        switch state {
        case .quiet: return 0
        case .listening: return 0.05 + 0.95 * clamp(input)
        case .speaking: return 0.05 + 0.95 * max(clamp(output), clamp(input))
        case .working: return 0.6
        case .attention: return 0.35
        }
    }

    /// How fast the wave's phase advances (per second): faster with either voice.
    static func waveSpeed(_ state: VoiceOrbState, output: CGFloat, input: CGFloat) -> CGFloat {
        switch state {
        case .quiet: return 0
        case .working: return 1.6
        case .listening: return 0.35 + 1.2 * clamp(input)
        case .speaking: return 0.35 + 3.0 * clamp(output) + 1.2 * clamp(input)
        case .attention: return 0.35
        }
    }

    /// The wave at a dot `distance` units from the centre: 0…1, running outward as `phase` grows.
    static func lift(distance: CGFloat, phase: CGFloat) -> CGFloat {
        0.5 + 0.5 * sin(distance * 0.12 - phase * 3.2)
    }

    /// A dot's radius (units) and opacity for its wave lift and the state's amplitude.
    static func dot(amplitude: CGFloat, lift: CGFloat) -> (radius: CGFloat, opacity: CGFloat) {
        (2.2 + 2.6 * amplitude * lift, min(1, 0.22 + 0.55 * amplitude * lift))
    }

    /// The flat halo behind the disc, as a multiple of the disc's radius, and its opacity.
    /// Speaking: 1.08…`haloReach` and 0.14…0.30 with the played level. The user's turn: breathing
    /// faintly (`breath` 0…1) while it's quiet, fading out as the mic rises (gone at a third of
    /// the mic's range). None otherwise.
    static func halo(_ state: VoiceOrbState, output: CGFloat, input: CGFloat, breath: CGFloat) -> (scale: CGFloat, opacity: CGFloat)? {
        switch state {
        case .speaking:
            let level = clamp(output)
            return (1.08 + (haloReach - 1.08) * level, 0.14 + 0.16 * level)
        case .listening:
            let quiet = max(0, 1 - 3 * clamp(input))
            guard quiet > 0 else { return nil }
            return (1.12 + 0.06 * breath, (0.10 + 0.05 * breath) * quiet)
        default:
            return nil
        }
    }

    /// The thin ring at 1.24 × the radius: opacity and width (pt). Thinking: a faint full ring
    static func ring(_ state: VoiceOrbState) -> (opacity: CGFloat, width: CGFloat)? {
        switch state {
        case .working: return (0.15, 1.5)
        case .attention: return (1, 2)
        default: return nil
        }
    }

    /// The breath, 0…1, at `seconds`.
    static func breath(at seconds: Double) -> CGFloat {
        CGFloat(0.5 + 0.5 * sin(seconds * 2 * .pi / breathSeconds))
    }

    private static func clamp(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }
}

/// Where the orb sits; one slot at a time is the matched-geometry source.
enum VoiceOrbSlot: Equatable {
    case header, bubble

    static let matchID = "voice-orb"

    /// and after). Minimized: the bubble (the bubble is the orb).
    static func current(expanded: Bool) -> Self {
        expanded ? .header : .bubble
    }
}

extension View {
    /// Makes this clear frame the orb's place when `active`.
    @ViewBuilder
    func voiceOrbSource(_ active: Bool, in namespace: Namespace.ID) -> some View {
        if active {
            matchedGeometryEffect(id: VoiceOrbSlot.matchID, in: namespace, isSource: true)
        } else {
            self
        }
    }
}

/// The wave's phase: advanced each drawn frame by the elapsed time × the state's speed, so a
/// louder voice runs the wave faster without the phase jumping.
@MainActor
final class VoiceOrbWaveClock {
    private(set) var phase: CGFloat = 0
    private var last: Date?

    func advance(to date: Date, speed: CGFloat) -> CGFloat {
        if let last {
            // A long gap (paused timeline, backgrounded app) restarts the step, not a jump.
            phase += CGFloat(min(0.1, max(0, date.timeIntervalSince(last)))) * speed
        }
        last = date
        return phase
    }
}

/// The orb itself. Reads the call's high-rate levels here only, so a level change re-evaluates
/// this view and nothing else. Drawn in one `Canvas` per frame of a `TimelineView` (the dots
/// are one fill each in that canvas, not views).
struct VoiceOrb: View {
    /// nil (no Hermes connection): a still grey orb.
    let model: VoiceScreenModel?
    let ending: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = VoiceOrbWaveClock()

    var body: some View {
        let state = model.flatMap { model in
            model.engineSession.map {
                VoiceOrbState.of(phase: $0.phase, hermesWorking: model.hermesWorking, attention: model.needsAttention,
                                 muted: model.muted, ending: ending)
            }
        } ?? .quiet
        // Hermes's level is read only while it speaks; the mic on the user's turn and while
        // Hermes speaks (a cut-in), never while Hermes works or waits.
        let output = state == .speaking ? model?.outputGlide ?? VoiceOrbGlide() : VoiceOrbGlide()
        let input = state == .listening || state == .speaking ? model?.inputGlide ?? VoiceOrbGlide() : VoiceOrbGlide()
        let moves = !reduceMotion && state != .quiet
        Color.clear
            .overlay {
                GeometryReader { geo in
                    let disc = min(geo.size.width, geo.size.height)
                    TimelineView(.animation(paused: !moves)) { timeline in
                        let date = timeline.date
                        // Reduce Motion: the wave and the spin stand still; the colour, the ring
                        // and the halo still follow the state and the levels (each reading redraws).
                        let out = moves ? output.value(at: date) : output.to
                        let mic = moves ? input.value(at: date) : input.to
                        let phase = moves ? clock.advance(to: date, speed: VoiceOrbLook.waveSpeed(state, output: out, input: mic))
                                          : clock.phase
                        let seconds = moves ? date.timeIntervalSinceReferenceDate : 0
                        Canvas { context, size in
                            VoiceOrbDrawing(state: state, output: out, input: mic, phase: phase, seconds: seconds, still: !moves)
                                .draw(in: &context, size: size)
                        }
                        .frame(width: disc * VoiceOrbMetrics.drawingScale, height: disc * VoiceOrbMetrics.drawingScale)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }
            }
            .animation(.smooth(duration: 0.3), value: state)
    }
}

/// One frame of the orb, in a canvas `VoiceOrbMetrics.drawingScale` discs wide.
struct VoiceOrbDrawing {
    let state: VoiceOrbState
    /// Hermes's played level and the mic's, 0…1 on their scales.
    let output: CGFloat
    let input: CGFloat
    let phase: CGFloat
    let seconds: Double
    let still: Bool

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / VoiceOrbMetrics.drawingScale / 2
        let unit = radius / VoiceOrbLook.discRadius
        let color = VoiceOrbLook.color(state)
        func circle(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
        }

        let breath = still ? 0.5 : VoiceOrbLook.breath(at: seconds)
        if let halo = VoiceOrbLook.halo(state, output: output, input: input, breath: breath) {
            context.fill(circle(radius * halo.scale), with: .color(color.opacity(halo.opacity)))
        }
        let ringRadius = radius * VoiceOrbLook.ringRadius
        if let ring = VoiceOrbLook.ring(state) {
            context.stroke(circle(ringRadius), with: .color(color.opacity(ring.opacity)), lineWidth: ring.width)
        }
        if state == .working {
            let start = still ? -90 : (seconds * VoiceOrbLook.arcDegreesPerSecond).truncatingRemainder(dividingBy: 360)
            var arc = Path()
            arc.addArc(center: centre, radius: ringRadius, startAngle: .degrees(start),
                       endAngle: .degrees(start + 360 * Double(VoiceOrbLook.arcFraction)), clockwise: false)
            context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }

        let disc = circle(radius)
        context.fill(disc, with: .color(color))
        var dots = context
        dots.clip(to: disc)
        let amplitude = VoiceOrbLook.amplitude(state, output: output, input: input)
        for point in VoiceOrbLook.dots {
            let lift = VoiceOrbLook.lift(distance: hypot(point.x, point.y), phase: phase)
            let dot = VoiceOrbLook.dot(amplitude: amplitude, lift: lift)
            let r = dot.radius * unit
            let x = centre.x + point.x * unit, y = centre.y + point.y * unit
            dots.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                      with: .color(.white.opacity(dot.opacity)))
        }
    }
}
