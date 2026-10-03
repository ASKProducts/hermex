import SwiftTerm
import SwiftUI
import UIKit

/// Full-screen terminal for one chat (presented from ChatView's toolbar button).
struct TerminalScreen: View {
    static let fontSizeKey = "terminal.fontSize"

    let session: SessionSummary
    let server: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: TerminalSessionController
    @State private var terminalHandle = TerminalHandle()

    init(session: SessionSummary, server: URL) {
        self.session = session
        self.server = server
        _controller = State(initialValue: TerminalSessionController(
            sessionID: session.sessionId ?? session.id,
            server: server,
            api: APIClient(baseURL: server)
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBanner
                if case let .failed(message) = controller.state {
                    ContentUnavailableView {
                        Label("Terminal unavailable", systemImage: "apple.terminal")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { terminalHandle.reopen(controller) }
                    }
                } else {
                    SwiftTermView(controller: controller, handle: terminalHandle, openURL: { openURL($0) })
                        .padding(.horizontal, 8)   // text inset; the background still fills the edges
                        .ignoresSafeArea(.container, edges: .bottom)
                }
            }
            .background(TerminalColors.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Terminal").font(.headline)
                        if let workspace = controller.workspace ?? session.workspace {
                            Text(workspace)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("terminal-title")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await terminalHandle.restart(controller) }
                        } label: {
                            Label("Restart Shell", systemImage: "arrow.clockwise")
                        }
                        Button {
                            UIPasteboard.general.string = terminalHandle.allText()
                        } label: {
                            Label("Copy All Output", systemImage: "doc.on.doc")
                        }
                        Button {
                            if let text = UIPasteboard.general.string { controller.send(text) }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        Label("Terminal Actions", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("terminal-menu")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.suspend()
            case .active: controller.resume()
            default: break
            }
        }
        .onDisappear { controller.detach() }
        .onReceive(NotificationCenter.default.publisher(for: .hermexAuthStateDidChange)) { note in
            guard let auth = note.object as? AuthManager,
                  TerminalAuthGate.shouldDismiss(terminalServer: server, state: auth.state) else { return }
            controller.detach()
            dismiss()
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch controller.state {
        case .reconnecting:
            banner(text: String(localized: "Reconnecting…"), showsRestart: false)
        case let .ended(reason):
            banner(text: endedText(reason), showsRestart: true)
        default:
            EmptyView()
        }
    }

    private func endedText(_ reason: TerminalSessionController.EndReason) -> String {
        switch reason {
        case let .exited(code?) where code != 0:
            return String(localized: "Session ended (exit \(code))")
        case let .error(message):
            return String(localized: "Session ended: \(message)")
        default:
            return String(localized: "Session ended")
        }
    }

    private func banner(text: String, showsRestart: Bool) -> some View {
        HStack {
            Text(text)
                .font(.footnote.weight(.medium))
                .accessibilityIdentifier("terminal-status")
            Spacer()
            if showsRestart {
                Button("Restart") { Task { await terminalHandle.restart(controller) } }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("terminal-restart")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

extension Notification.Name {
    /// Posted by AuthManager whenever `state` changes.
    static let hermexAuthStateDidChange = Notification.Name("hermex.authStateDidChange")
}

/// Whether an open terminal must close for an auth state (check 9): it belongs to
/// exactly one signed-in server; any switch, sign-out or expiry closes it.
enum TerminalAuthGate {
    static func shouldDismiss(terminalServer: URL, state: AuthManager.State) -> Bool {
        state != .loggedIn(server: terminalServer)
    }
}

/// Feeds terminal output to SwiftTerm in bounded slices, one slice per main run-loop pass.
/// Chunks that arrive in the same pass are joined (one parse/layout instead of one per SSE
/// event), and a flood (`yes`, `cat` of a big file) is cut into slices of at most
/// `maxPerPass` UTF-8 bytes with a run-loop turn in between, so touches (Done, scrolling)
/// and drawing get in while output streams. Order is preserved; nothing is dropped.
@MainActor
final class TerminalOutputBatcher {
    static let defaultMaxPerPass = 16_384

    private let sink: (String) -> Void
    private let maxPerPass: Int
    private var queue: [Substring] = []
    private var head = 0
    private var scheduled = false

    init(maxPerPass: Int = TerminalOutputBatcher.defaultMaxPerPass, sink: @escaping (String) -> Void) {
        self.maxPerPass = max(1, maxPerPass)
        self.sink = sink
    }

    var hasPending: Bool { head < queue.count }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        queue.append(Substring(text))
        scheduleIfNeeded()
    }

    /// Feeds everything that is pending now (used on teardown and by tests).
    func flush() {
        while hasPending { drainOnePass() }
        scheduled = false
    }

    private func scheduleIfNeeded() {
        guard !scheduled, hasPending else { return }
        scheduled = true
        // main.async runs on a later run-loop pass than the current one, so input events
        // and the Core Animation commit are handled between two slices.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.drainOnePass()
            self.scheduleIfNeeded()
        }
    }

    /// Feeds up to `maxPerPass` bytes, split on a Unicode scalar boundary.
    func drainOnePass() {
        var budget = maxPerPass
        var slice = ""
        while budget > 0, head < queue.count {
            let chunk = queue[head]
            let size = chunk.utf8.count
            if size <= budget {
                slice += chunk
                budget -= size
                head += 1
                continue
            }
            var cut = chunk.utf8.index(chunk.startIndex, offsetBy: budget)
            // Step back off UTF-8 continuation bytes (10xxxxxx) to a scalar boundary.
            while cut > chunk.startIndex, cut < chunk.endIndex, chunk.utf8[cut] & 0xC0 == 0x80 {
                cut = chunk.utf8.index(before: cut)
            }
            if cut == chunk.startIndex {
                // A single scalar larger than the remaining budget: take it whole.
                cut = chunk.unicodeScalars.index(after: chunk.startIndex)
            }
            slice += chunk[..<cut]
            queue[head] = chunk[cut...]
            budget = 0
        }
        if head >= queue.count {
            queue.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 64 {
            queue.removeFirst(head)
            head = 0
        }
        if !slice.isEmpty { sink(slice) }
    }
}

enum TerminalLinks {
    /// Only web links open from the terminal (no file:, tel:, custom schemes).
    static func openableURL(_ link: String) -> URL? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

enum TerminalColors {
    /// The app's code-block colors (MarkdownRenderer's `codeBlockBackground`).
    static let background = Color(uiColor: backgroundUIColor)
    static let backgroundUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
            : UIColor.secondarySystemBackground
    }
    static let foregroundUIColor = UIColor.label
}

/// Lets the SwiftUI screen reach the UIKit terminal view (copy all, restart).
@MainActor
final class TerminalHandle {
    weak var view: SwiftTerm.TerminalView?

    func allText() -> String {
        guard let terminal = view?.getTerminal() else { return "" }
        let data = terminal.getBufferAsData(kind: .normal)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func restart(_ controller: TerminalSessionController) async {
        // Keep the old output visible; the new shell's output follows a separator.
        view?.feed(text: "\r\n")
        await controller.restart()
    }

    func reopen(_ controller: TerminalSessionController) {
        guard let view else { return }
        let terminal = view.getTerminal()
        Task { await controller.open(rows: terminal.rows, cols: terminal.cols) }
    }
}

/// SwiftTerm's UIKit `TerminalView` wrapped for SwiftUI.
struct SwiftTermView: UIViewRepresentable {
    let controller: TerminalSessionController
    let handle: TerminalHandle
    let openURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, openURL: openURL)
    }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let size = Coordinator.storedFontSize
        let view = SwiftTerm.TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: size, weight: .regular))
        view.terminalDelegate = context.coordinator
        Self.applyColors(to: view, scheme: context.environment.colorScheme)
        view.linkHighlightMode = .always
        view.changeScrollback(10_000)
        view.accessibilityIdentifier = "terminal-view"
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        view.addGestureRecognizer(pinch)
        // SwiftTerm's own tap only opens OSC 8 links in `.always` mode; also open plain
        // http(s) URLs printed by commands. Runs alongside SwiftTerm's tap (keyboard focus).
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        handle.view = view
        let batcher = TerminalOutputBatcher { [weak view] text in view?.feed(text: text) }
        context.coordinator.batcher = batcher
        controller.onOutput = { text in batcher.append(text) }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        let scheme = context.environment.colorScheme
        guard context.coordinator.appliedScheme != scheme else { return }
        context.coordinator.appliedScheme = scheme
        Self.applyColors(to: uiView, scheme: scheme)
    }

    /// SwiftTerm turns these into fixed terminal colors when set, so dynamic colors
    /// don't follow light/dark by themselves: resolve for the scheme and re-apply.
    private static func applyColors(to view: SwiftTerm.TerminalView, scheme: ColorScheme) {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        view.nativeBackgroundColor = TerminalColors.backgroundUIColor.resolvedColor(with: traits)
        view.nativeForegroundColor = TerminalColors.foregroundUIColor.resolvedColor(with: traits)
        view.setNeedsDisplay()
    }

    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        coordinator.controller.onOutput = nil
        coordinator.batcher?.flush()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        static let minFontSize: CGFloat = 9
        static let maxFontSize: CGFloat = 20

        static var storedFontSize: CGFloat {
            let value = UserDefaults.standard.double(forKey: TerminalScreen.fontSizeKey)
            return value > 0 ? min(max(value, minFontSize), maxFontSize) : 12
        }

        let controller: TerminalSessionController
        let openURL: (URL) -> Void
        weak var view: SwiftTerm.TerminalView?
        var appliedScheme: ColorScheme?
        var batcher: TerminalOutputBatcher?
        private var pinchStartSize: CGFloat = 12
        private var didOpen = false

        init(controller: TerminalSessionController, openURL: @escaping (URL) -> Void) {
            self.controller = controller
            self.openURL = openURL
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard let view else { return }
            switch gesture.state {
            case .began:
                pinchStartSize = view.font.pointSize
            case .changed, .ended:
                let size = (pinchStartSize * gesture.scale).rounded()
                let clamped = min(max(size, Self.minFontSize), Self.maxFontSize)
                if clamped != view.font.pointSize {
                    view.font = .monospacedSystemFont(ofSize: clamped, weight: .regular)
                }
                if gesture.state == .ended {
                    UserDefaults.standard.set(Double(clamped), forKey: TerminalScreen.fontSizeKey)
                }
            default:
                break
            }
        }

        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view, gesture.state == .ended,
                  let cell = view.cellSizeInPixels(source: view.getTerminal()), cell.width > 0, cell.height > 0 else { return }
            // Same scale SwiftTerm uses for cellSizeInPixels (the window's, not the view's).
            let scale = view.window?.contentScaleFactor ?? UIScreen.main.scale
            // Viewport-relative point (the view scrolls), so rounding in the cell size can't drift far.
            let point = gesture.location(in: view)
            let viewportY = point.y - view.contentOffset.y
            let position = Position(col: Int(point.x * scale) / cell.width, row: Int(viewportY * scale) / cell.height)
            let terminal = view.getTerminal()
            guard position.col >= 0, position.col < terminal.cols, position.row >= 0, position.row < terminal.rows,
                  let link = terminal.link(at: .screen(position), mode: .explicitAndImplicit),
                  let url = TerminalLinks.openableURL(link) else {
                return
            }
            openURL(url)
        }

        // MARK: TerminalViewDelegate

        nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                // Measure first, then start: the first real size opens the shell.
                guard newCols > 1, newRows > 1 else { return }
                if !didOpen {
                    didOpen = true
                    Task { await controller.open(rows: newRows, cols: newCols) }
                    // Take the keyboard on open so typing works without a tap first.
                    DispatchQueue.main.async { _ = source.becomeFirstResponder() }
                } else {
                    controller.resize(rows: newRows, cols: newCols)
                }
            }
        }

        nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let text = String(decoding: data, as: UTF8.self)
            MainActor.assumeIsolated { controller.send(text) }
        }

        nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            guard let url = TerminalLinks.openableURL(link) else { return }
            MainActor.assumeIsolated { openURL(url) }
        }

        nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        nonisolated func bell(source: SwiftTerm.TerminalView) {}
        nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                DispatchQueue.main.async { UIPasteboard.general.string = text }
            }
        }
        nonisolated func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
