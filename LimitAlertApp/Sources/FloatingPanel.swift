import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Obecność aplikacji

/// Znacznik `~/.opencode-alerts/.app.pid`. Gdy aplikacja działa, to ona jest
/// jedynym źródłem głosu i banera — `alerts.py` / plugin JS go nie dublują.
enum AppPresence {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".opencode-alerts/.app.pid")

    static func register() {
        let fm = FileManager.default
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(getpid())\n".write(to: path, atomically: true, encoding: .utf8)
    }

    static func unregister() {
        try? FileManager.default.removeItem(at: path)
    }
}

// MARK: - Stan i model banera

enum BannerAction {
    case dismiss
    case jump
}

final class BannerState {
    var onAction: ((AlertItem, BannerAction) -> Void)?
}

/// Baner pokazuje dokładnie jeden alert naraz. Kolejka (indeks / liczba)
/// jest sterowana przez `AlertStore`, więc kilka alertów nie nakłada się.
final class BannerModel: ObservableObject {
    @Published var item: AlertItem?
    @Published var index: Int = 1
    @Published var total: Int = 1
    /// 0 = Odrzuć, 1 = Przejdź (domyślnie).
    @Published var selection: Int = 1
    let state: BannerState

    init(state: BannerState) {
        self.state = state
    }
}

enum BannerStyle {
    static let width: CGFloat = 384
    static let padding: CGFloat = 12
    static let margin: CGFloat = 16
}

// MARK: - Log diagnostyczny

enum DebugLog {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".opencode-alerts/panel.log")

    static func write(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: path, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Widok

struct BannerView: View {
    @ObservedObject var model: BannerModel

    var body: some View {
        Group {
            if let item = model.item {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    BannerRow(item: item,
                              onJump: {
                                  DebugLog.write("click row jump")
                                  model.state.onAction?(item, .jump)
                              },
                              onDismiss: {
                                  DebugLog.write("click x dismiss")
                                  model.state.onAction?(item, .dismiss)
                              })
                    hint
                    footer(item)
                }
                .padding(BannerStyle.padding)
                .frame(width: BannerStyle.width)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    // MARK: Nagłówek

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(headerTitle)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if model.total > 1 {
                Text("\(model.index) / \(model.total)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.clock.string(from: context.date))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .onTapGesture {
            if let item = model.item {
                model.state.onAction?(item, .jump)
            }
        }
        .help("Kliknij, aby przejść do zadania")
    }

    private var headerTitle: String {
        model.total > 1 ? "ALERTY W KOLEJCE" : "ALERT"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: Sterowanie klawiaturą

    private var hint: some View {
        Text("⌥⌘L  ·  ← → wybór  ·  Tab  ·  1 / 2  ·  ↵  ·  Esc")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.leading, 2)
    }

    // MARK: Stopka

    private func footer(_ item: AlertItem) -> some View {
        HStack(spacing: 8) {
            Button("1  Odrzuć") {
                DebugLog.write("button 1")
                model.state.onAction?(item, .dismiss)
            }
            .buttonStyle(BannerButtonStyle(prominent: false, selected: model.selection == 0))
            Button("2  Przejdź") {
                DebugLog.write("button 2")
                model.state.onAction?(item, .jump)
            }
            .buttonStyle(BannerButtonStyle(prominent: true, selected: model.selection == 1))
        }
    }
}

private struct BannerRow: View {
    let item: AlertItem
    let onJump: () -> Void
    let onDismiss: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: meta.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(meta.tint)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Odrzuć")
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hover ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onJump)
    }

    private var subtitle: String {
        let time: String
        if let clock = item.time.split(separator: "T").last, clock.count >= 5 {
            time = String(clock.prefix(5))
        } else {
            time = String(item.time.suffix(5))
        }
        return [meta.label, time, agentName].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var agentName: String {
        switch item.agent ?? "opencode" {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        default: return item.agent ?? ""
        }
    }

    private var meta: (symbol: String, tint: Color, label: String) {
        switch item.kind {
        case "limit": return ("hourglass", .orange, "Skończył się limit")
        case "done": return ("checkmark.circle.fill", .green, "Zadanie skończone")
        default: return ("exclamationmark.triangle.fill", .red, "Zadanie stanęło")
        }
    }
}

private struct BannerButtonStyle: ButtonStyle {
    let prominent: Bool
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(border, lineWidth: 2)
            )
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .contentShape(Rectangle())
    }

    private var border: Color {
        guard selected else { return .clear }
        return prominent ? Color.white.opacity(0.85) : Color.accentColor
    }

    private func background(pressed: Bool) -> Color {
        if prominent {
            return Color.accentColor.opacity(pressed ? 0.75 : 1)
        }
        return Color.primary.opacity(pressed ? 0.16 : 0.08)
    }
}

// MARK: - Panel

/// Pływający baner w prawym górnym rogu. Domyślnie nie zabiera fokusu.
/// Klik w baner albo ⌥⌘L włącza sterowanie klawiaturą.
final class FloatingPanelController {
    let state = BannerState()

    private var panel: KeyablePanel?
    private var hosting: NSHostingView<BannerView>?
    private var model: BannerModel?
    private var keyMonitor: Any?
    private var hotKey: GlobalHotKey?

    init() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
        hotKey = GlobalHotKey(key: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.focus()
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func present(_ item: AlertItem, index: Int, total: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.present(item, index: index, total: total) }
            return
        }
        let model = ensurePanel()
        model.item = item
        model.index = index
        model.total = total
        model.selection = 1
        layoutAndShow()
    }

    func updateProgress(index: Int, total: Int) {
        DispatchQueue.main.async {
            self.model?.index = index
            self.model?.total = total
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Nadaje banerowi fokus klawiatury bez aktywowania całej aplikacji.
    func focus() {
        guard let panel, panel.isVisible else { return }
        DebugLog.write("focus panel")
        panel.makeKeyAndOrderFront(nil)
        model?.selection = 1
    }

    private func ensurePanel() -> BannerModel {
        if let model { return model }

        let model = BannerModel(state: state)
        let hosting = FirstMouseHostingView(rootView: BannerView(model: model))
        hosting.wantsLayer = true

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: BannerStyle.width, height: 220),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: 101)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.contentView = hosting

        self.model = model
        self.hosting = hosting
        self.panel = panel
        return model
    }

    private func layoutAndShow() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()

        let height = max(150, ceil(hosting.fittingSize.height))
        let size = NSSize(width: BannerStyle.width, height: height)
        if panel.frame.size != size {
            panel.setContentSize(size)
        }
        position(panel, size: size)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.maxX - size.width - BannerStyle.margin,
            y: frame.maxY - size.height - BannerStyle.margin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: Klawiatura

    private func handle(_ event: NSEvent) -> Bool {
        guard let model, let item = model.item else { return false }
        DebugLog.write("key \(event.keyCode)")
        switch event.keyCode {
        case 123: // ←
            model.selection = 0
            return true
        case 124: // →
            model.selection = 1
            return true
        case 48: // Tab / Shift+Tab — dwa przyciski, więc przełącza w obie strony
            model.selection = model.selection == 0 ? 1 : 0
            return true
        case 18: // 1
            fire(.dismiss, item)
            return true
        case 19: // 2
            fire(.jump, item)
            return true
        case 36, 76, 49: // Return, keypad Enter, Space
            fire(model.selection == 0 ? .dismiss : .jump, item)
            return true
        case 53: // Esc
            fire(.dismiss, item)
            return true
        default:
            return false
        }
    }

    private func fire(_ action: BannerAction, _ item: AlertItem) {
        state.onAction?(item, action)
    }
}

/// `NSPanel` bez fokusu zjada pierwszy klik. Ten widok oddaje go od razu
/// SwiftUI, więc klik w wiersz od razu przełącza na zadanie.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Globalny skrót ⌥⌘L

private final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void

    init(key: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.callback() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C414C54), id: 1) // 'LALT'
        let status = RegisterEventHotKey(key, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            DebugLog.write("hotkey registration failed: \(status)")
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
