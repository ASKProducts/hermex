import SwiftUI
import SwiftTerm

struct TerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var fontSize = 14.0
    private var terminal: ShellTerminalView? { model.display as? ShellTerminalView }
    @State private var model: TerminalViewModel

    init(target: HermesTerminalTarget) {
        _model = State(initialValue: TerminalViewModel(client: HermesTerminalClient(target: target)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if case .failed(let failure) = model.state {
                        Button(failure == .exited ? String(localized: "Start New Shell") : String(localized: "Reconnect")) {
                            model.reconnect()
                        }.font(.callout)
                    }
                }.padding(.horizontal).padding(.vertical, 8)
                NativeTerminal(model: model, fontSize: min(fontSize, 22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                keys
                Text("Commands run on your Hermes host, outside agent approvals. Closing keeps the shell running.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.bottom, 4)
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut("w", modifiers: .command)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { toggleKeyboard() } label: { Label("Keyboard", systemImage: "keyboard") }
                }
            }
        }
        .onAppear { if scenePhase != .background { model.activate() } }
        .onDisappear { model.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.suspend() }
            else if phase == .active { model.activate() }
        }
    }

    private var keys: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                Button { model.send(Data(EscapeSequences.cmdEsc)) } label: { Text(verbatim: "Esc") }.accessibilityLabel("Escape")
                Button { terminal?.controlModifier.toggle() } label: { Text(verbatim: "Ctrl") }
                    .accessibilityLabel("Control")
                Button { model.send(Data([UInt8(ascii: "\u{9}")])) } label: { Text(verbatim: "Tab") }.accessibilityLabel("Tab")
                arrow(.left)
                arrow(.down)
                arrow(.up)
                arrow(.right)
            }
            .buttonStyle(TerminalKeyStyle())
            .padding(.horizontal, 8).padding(.vertical, 6)
            .disabled(model.state != .connected)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollDismissesKeyboard(.never)
    }

    private func arrow(_ direction: TerminalArrow) -> some View {
        Button {
            guard let terminal else { return }
            model.send(Data(direction.bytes(applicationCursor: terminal.getTerminal().applicationCursor)))
        } label: { Image(systemName: direction.icon) }
            .accessibilityLabel(direction.label)
    }

    private func toggleKeyboard() {
        guard let terminal else { return }
        if terminal.isFirstResponder { terminal.resignFirstResponder() }
        else if model.state == .connected { terminal.becomeFirstResponder() }
    }
}

private struct TerminalKeyStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.fixedSize()
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(.tint)
            .background(.quaternary, in: Capsule())
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.6 : 1)
            .accessibilityShowsLargeContentViewer()
    }
}

private struct NativeTerminal: UIViewRepresentable {
    let model: TerminalViewModel
    let fontSize: CGFloat
    @Environment(\.colorScheme) private var scheme

    func makeUIView(context: Context) -> ShellTerminalView {
        let view = ShellTerminalView(frame: .zero)
        view.model = model
        view.terminalDelegate = view
        view.inputAccessoryView = nil
        view.accessibilityIdentifier = "hermes-terminal"
        model.display = view
        return view
    }

    func updateUIView(_ view: ShellTerminalView, context: Context) {
        applyAppearance(view)
        view.inputEnabled = model.state == .connected
        if !view.inputEnabled { view.resignFirstResponder() }
    }

    private func applyAppearance(_ view: SwiftTerm.TerminalView) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if view.font != font { view.font = font }
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        view.nativeForegroundColor = UIColor.label.resolvedColor(with: traits)
        view.nativeBackgroundColor = UIColor.systemBackground.resolvedColor(with: traits)
    }

    static func dismantleUIView(_ view: ShellTerminalView, coordinator: Void) {
        view.model?.display = nil
        view.terminalDelegate = nil
    }
}

private final class ShellTerminalView: SwiftTerm.TerminalView, TerminalViewDelegate, TerminalDisplay {
    weak var model: TerminalViewModel?
    var inputEnabled = false
    override var canBecomeFirstResponder: Bool { inputEnabled && super.canBecomeFirstResponder }
    override func bell(source: Terminal) {
        if model?.isReplaying != true { super.bell(source: source) }
    }
    func reset() { feed(text: "\u{1b}c") }
    func feed(_ data: ArraySlice<UInt8>) { feed(byteArray: data) }
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { model?.send(Data(data)) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        model?.resize(columns: newCols, rows: newRows)
    }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

}

enum TerminalArrow {
    case up, down, left, right
    var label: String {
        switch self {
        case .up: String(localized: "Up")
        case .down: String(localized: "Down")
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        }
    }
    var icon: String { "arrow.\(self)" }
    func bytes(applicationCursor: Bool) -> [UInt8] {
        switch self {
        case .up: applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        case .down: applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        case .left: applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
        case .right: applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
        }
    }
}

struct TerminalFeature: ViewModifier {
    let target: HermesTerminalTarget?
    @State private var available = false
    @State private var selected: HermesTerminalTarget?
    func body(content: Content) -> some View {
        content
            .toolbar {
                if available, let target {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { selected = target } label: { Label("Terminal", systemImage: "terminal") }
                    }
                }
            }
            .focusedSceneValue(\.hermexTerminalAction, available ? { selected = target } : nil)
            .fullScreenCover(item: $selected) { TerminalScreen(target: $0) }
            .task(id: target?.id) {
                available = false
                guard let target else { return }
                let offered = await HermesTerminalClient.isAvailable(on: target.http)
                if !Task.isCancelled { available = offered }
            }
    }
}
