import AppKit
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

final class BannerState {
    var onJump: ((AlertItem) -> Void)?
    var onDismiss: ((AlertItem) -> Void)?
    var onClear: (() -> Void)?
}

final class BannerModel: ObservableObject {
    @Published var alerts: [AlertItem] = []
    let state: BannerState

    init(state: BannerState) {
        self.state = state
    }
}

enum BannerStyle {
    static let width: CGFloat = 360
    static let padding: CGFloat = 12
    static let rowHeight: CGFloat = 52
    static let maxRows = 5
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

    private var visible: [AlertItem] { Array(model.alerts.prefix(BannerStyle.maxRows)) }
    private var overflow: Int { max(0, model.alerts.count - visible.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            VStack(spacing: 0) {
                ForEach(visible) { item in
                    BannerRow(item: item,
                              onJump: { model.state.onJump?(item) },
                              onDismiss: { model.state.onDismiss?(item) })
                }
            }

            if overflow > 0 {
                Text("+\(overflow) więcej")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 30)
            }

            footer
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
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.clock.string(from: context.date))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 18)
    }

    private var headerTitle: String {
        let n = model.alerts.count
        let noun: String
        switch n {
        case 1: noun = "ZADANIE"
        case 2...4: noun = "ZADANIA"
        default: noun = "ZADAŃ"
        }
        return "ALERTY · \(n) \(noun)"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: Stopka

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if model.alerts.count == 1, let item = model.alerts.first {
                Button("Odrzuć") { model.state.onDismiss?(item) }
                    .buttonStyle(BannerButtonStyle(prominent: false))
                Button("Przejdź") { model.state.onJump?(item) }
                    .buttonStyle(BannerButtonStyle(prominent: true))
            } else {
                Button("Wyczyść wszystko") { model.state.onClear?() }
                    .buttonStyle(BannerButtonStyle(prominent: false))
            }
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
        .frame(height: BannerStyle.rowHeight - 2)
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            )
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .contentShape(Rectangle())
    }

    private func background(pressed: Bool) -> Color {
        if prominent {
            return Color.accentColor.opacity(pressed ? 0.75 : 1)
        }
        return Color.primary.opacity(pressed ? 0.16 : 0.08)
    }
}

// MARK: - Panel

/// Pływający baner w prawym górnym rogu. Nie przejmuje fokusu klawiatury.
final class FloatingPanelController {
    let state = BannerState()

    private var panel: NSPanel?
    private var hosting: NSHostingView<BannerView>?
    private var model: BannerModel?

    func update(alerts: [AlertItem]) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.update(alerts: alerts) }
            return
        }
        guard !alerts.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let model = ensurePanel()
        model.alerts = alerts
        layoutAndShow()
    }

    @discardableResult
    private func ensurePanel() -> BannerModel {
        if let model { return model }

        let model = BannerModel(state: state)
        let hosting = NSHostingView(rootView: BannerView(model: model))
        hosting.wantsLayer = true

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: BannerStyle.width, height: 200),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: 101) // nad pełnoekranowymi oknami (jak banner Python)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
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

        let height = max(120, ceil(hosting.fittingSize.height))
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
}
