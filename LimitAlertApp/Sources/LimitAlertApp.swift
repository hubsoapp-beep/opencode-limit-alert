import SwiftUI
import AppKit
import AVFoundation
import UserNotifications
import Foundation
import Dispatch

// MARK: - Models

struct AlertItem: Codable, Identifiable, Hashable {
    let id: String
    let sessionID: String
    let title: String
    let kind: String
    let detail: String?
    let agent: String?
    let time: String
}

struct AgentVoice: Codable, Hashable {
    var voiceId: String
    var systemVoice: String
}

struct AppConfig: Codable {
    var elevenlabsApiKey: String = ""
    var voiceId: String = "EXAVITQu4vr4xnSDxMaL"
    var modelId: String = "eleven_flash_v2_5"
    var systemVoice: String = "Zosia"
    var announceDone: Bool = true
    var debug: Bool = false
    var useNativeNotifications: Bool = true
    var bannerOnlyNoVoice: Bool = false
    var quietHoursStart: Int = 23
    var quietHoursEnd: Int = 7
    var webhookURL: String = ""
    var voiceByAgent: [String: String] = [:]
    var systemVoiceByAgent: [String: String] = [:]
    var agentEnabled: [String: Bool] = ["opencode": true, "claude-code": true, "codex": true]
    var agentMode: [String: String] = [:] // voice+notify | notify-only | banner-only

    static let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode/limit-alert.json")

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configPath),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return cfg
    }

    func save() {
        let dir = AppConfig.configPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: AppConfig.configPath, options: .atomic)
        }
    }
}

// MARK: - Alert Store

class AlertStore: ObservableObject {
    @Published var alerts: [AlertItem] = []
    let panel = FloatingPanelController()
    @Published var history: [AlertItem] = []
    private let spool = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode-alerts")
    private var timer: Timer?
    /// Trzymamy odtwarzacz, inaczej AVAudioPlayer zwalnia się i głos ucina.
    private var player: AVAudioPlayer?
    private let historyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".opencode-alerts/history.jsonl")

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        loadHistory()
        panel.state.onJump = { [weak self] item in
            guard let self else { return }
            self.jump(item)
        }
        panel.state.onDismiss = { [weak self] item in self?.remove(item) }
        panel.state.onClear = { [weak self] in self?.clearAll() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        var items: [AlertItem] = []
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let item = try? JSONDecoder().decode(AlertItem.self, from: data) {
                items.append(item)
            }
        }
        items.sort { $0.time > $1.time }
        DispatchQueue.main.async {
            let oldIds = Set(self.alerts.map { $0.id })
            let newItems = items.filter { !oldIds.contains($0.id) }
            self.alerts = items
            self.panel.update(alerts: items)
            for item in newItems {
                self.handleNewItem(item)
                self.appendHistory(item)
            }
        }
    }

    func remove(_ item: AlertItem) {
        // Nazwa pliku to sessionID, ale id bywa inne — szukamy po zawartości.
        if let files = try? FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil) {
            for u in files where u.pathExtension == "json" {
                if let data = try? Data(contentsOf: u),
                   let it = try? JSONDecoder().decode(AlertItem.self, from: data),
                   it.id == item.id {
                    try? FileManager.default.removeItem(at: u)
                }
            }
        }
        alerts.removeAll { $0.id == item.id }
    }

    func jump(_ item: AlertItem) {
        remove(item)
        jumpToAlert(item)
    }

    func clearAll() {
        DebugLog.write("clearAll")
        if let files = try? FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil) {
            for u in files where u.pathExtension == "json" {
                try? FileManager.default.removeItem(at: u)
            }
        }
        alerts.removeAll()
    }

    private func appendHistory(_ item: AlertItem) {
        if let data = try? JSONEncoder().encode(item),
           let line = String(data: data, encoding: .utf8) {
            let handle = try? FileHandle(forWritingTo: historyFile)
            if handle == nil {
                try? FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: historyFile.path, contents: nil)
            }
            if let h = try? FileHandle(forWritingTo: historyFile) {
                h.seekToEndOfFile()
                h.write((line + "\n").data(using: .utf8)!)
                h.closeFile()
            }
        }
        loadHistory()
    }

    private func loadHistory() {
        guard let text = try? String(contentsOf: historyFile) else { return }
        var items: [AlertItem] = []
        for line in text.split(separator: "\n") {
            if let data = line.data(using: .utf8),
               let item = try? JSONDecoder().decode(AlertItem.self, from: data) {
                items.append(item)
            }
        }
        items.reverse()
        history = Array(items.prefix(200))
    }

    private func handleNewItem(_ item: AlertItem) {
        DebugLog.write("new \(item.id) agent=\(item.agent ?? "-")")
        let cfg = AppConfig.load()
        let agent = item.agent ?? "opencode"
        guard cfg.agentEnabled[agent] ?? true else { return }
        let mode = cfg.agentMode[agent] ?? "voice+notify"
        if cfg.bannerOnlyNoVoice || mode == "banner-only" { /* still menu */ }

        // Quiet hours
        let hour = Calendar.current.component(.hour, from: Date())
        let quiet = isQuietHour(hour: hour, start: cfg.quietHoursStart, end: cfg.quietHoursEnd)

        // Native notification
        if cfg.useNativeNotifications && mode != "banner-only" {
            sendNativeNotification(item: item)
        }

        // TTS
        if !cfg.bannerOnlyNoVoice && mode != "notify-only" && mode != "banner-only" && !quiet {
            speak(item: item, cfg: cfg, agent: agent)
        }

        // Webhook
        if !cfg.webhookURL.isEmpty {
            sendWebhook(item: item, url: cfg.webhookURL)
        }
    }

    private func isQuietHour(hour: Int, start: Int, end: Int) -> Bool {
        if start < end {
            return hour >= start && hour < end
        } else {
            return hour >= start || hour < end
        }
    }

    private func sendNativeNotification(item: AlertItem) {
        let content = UNMutableNotificationContent()
        content.title = "LimitAlert"
        content.subtitle = item.title
        content.body = item.kind
        content.sound = .default
        let req = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func speak(item: AlertItem, cfg: AppConfig, agent: String) {
        let heading: String
        switch item.kind {
        case "limit": heading = "Skończył się limit"
        case "error": heading = "Zadanie stanęło"
        case "done": heading = "Zadanie skończone"
        default: heading = "Alert"
        }
        let text = "\(heading). Zadanie: \(item.title)."
        let voiceId = cfg.voiceByAgent[agent] ?? cfg.voiceId
        let systemVoice = cfg.systemVoiceByAgent[agent] ?? cfg.systemVoice
        let apiKey = cfg.elevenlabsApiKey
        let modelId = cfg.modelId
        if !apiKey.isEmpty && !cfg.bannerOnlyNoVoice {
            // ElevenLabs
            let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)?output_format=mp3_44100_128")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": modelId])
            let task = URLSession.shared.dataTask(with: req) { data, resp, err in
                if let data = data, err == nil {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("la-\(UUID().uuidString).mp3")
                    try? data.write(to: tmp)
                    DispatchQueue.main.async {
                        do {
                            let player = try AVAudioPlayer(contentsOf: tmp)
                            self.player?.stop()
                            self.player = player
                            player.play()
                        } catch {
                            self.fallbackSay(text: text, voice: systemVoice)
                        }
                    }
                } else {
                    self.fallbackSay(text: text, voice: systemVoice)
                }
            }
            task.resume()
        } else {
            fallbackSay(text: text, voice: systemVoice)
        }
    }

    private func fallbackSay(text: String, voice: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, text]
        try? p.run()
    }

    private func sendWebhook(item: AlertItem, url: String) {
        guard let u = URL(string: url) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["title": item.title, "kind": item.kind, "agent": item.agent ?? "", "time": item.time, "detail": item.detail ?? ""]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }
}

// MARK: - Jump helper

func jumpToAlert(_ item: AlertItem) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc.arguments = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/opencode-alerts/alerts.py").path, "jump", item.title, "--session", item.sessionID]
    try? proc.run()
}

// MARK: - Views

struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct SettingsView: View {
    @State private var cfg = AppConfig.load()
    @State private var voices: [VoiceOption] = []
    @State private var testResult: String = ""
    @State private var saveResult: String = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("Ogólne", systemImage: "gear") }
            voicesTab
                .tabItem { Label("Głosy", systemImage: "speaker.wave.2") }
            agentsTab
                .tabItem { Label("Agenty", systemImage: "person.2") }
            integrationsTab
                .tabItem { Label("Integracje", systemImage: "link") }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    // MARK: - Ogólne
    var generalTab: some View {
        Form {
            Section("Zachowanie") {
                Toggle("Czytaj „zadanie skończone”", isOn: $cfg.announceDone)
                Toggle("Tylko banner, bez głosu", isOn: $cfg.bannerOnlyNoVoice)
                Toggle("Natywne powiadomienia Apple", isOn: $cfg.useNativeNotifications)
                Toggle("Debug (logi)", isOn: $cfg.debug)
            }
            Section("Cicha godzina") {
                Stepper("Start: \(cfg.quietHoursStart):00", value: $cfg.quietHoursStart, in: 0...23)
                Stepper("Koniec: \(cfg.quietHoursEnd):00", value: $cfg.quietHoursEnd, in: 0...23)
            }
            Section("Webhook (Slack/Telegram)") {
                TextField("URL webhooka", text: $cfg.webhookURL)
                    .textFieldStyle(.roundedBorder)
            }
            Section {
                Button("Zapisz ustawienia") { save() }
                    .buttonStyle(.borderedProminent)
                if !saveResult.isEmpty {
                    Text(saveResult).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Głosy
    var voicesTab: some View {
        Form {
            Section("ElevenLabs") {
                SecureField("Klucz API", text: $cfg.elevenlabsApiKey)
                TextField("Model ID", text: $cfg.modelId)
                Picker("Domyślny głos", selection: $cfg.voiceId) {
                    if voices.isEmpty {
                        Text(cfg.voiceId).tag(cfg.voiceId)
                    } else {
                        ForEach(voices) { v in
                            Text(v.name).tag(v.id)
                        }
                    }
                }
                HStack {
                    Button("Pobierz listę głosów") { fetchVoices() }
                    Button("Testuj połączenie") { testConnection() }
                }
                if !testResult.isEmpty {
                    Text(testResult).font(.caption).foregroundColor(.secondary)
                }
            }
            Section("Głos systemowy (fallback macOS)") {
                TextField("Nazwa głosu `say` (np. Zosia)", text: $cfg.systemVoice)
            }
            Section("Głosy per agent (voiceId ElevenLabs)") {
                ForEach(["opencode", "claude-code", "codex"], id: \.self) { a in
                    TextField(a, text: Binding(get: { cfg.voiceByAgent[a] ?? "" },
                                             set: { cfg.voiceByAgent[a] = $0 }))
                }
                ForEach(["opencode", "claude-code", "codex"], id: \.self) { a in
                    TextField("\(a) (system)", text: Binding(get: { cfg.systemVoiceByAgent[a] ?? "" },
                                                          set: { cfg.systemVoiceByAgent[a] = $0 }))
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Agenty
    var agentsTab: some View {
        Form {
            Section("Włącz/wyłącz agenty") {
                ForEach(["opencode", "claude-code", "codex"], id: \.self) { a in
                    Toggle(a, isOn: Binding(get: { cfg.agentEnabled[a] ?? true },
                                           set: { cfg.agentEnabled[a] = $0 }))
                }
            }
            Section("Reguły routingu") {
                ForEach(["opencode", "claude-code", "codex"], id: \.self) { a in
                    Picker(a, selection: Binding(get: { cfg.agentMode[a] ?? "voice+notify" },
                                               set: { cfg.agentMode[a] = $0 })) {
                        Text("Głos + powiadomienie").tag("voice+notify")
                        Text("Tylko powiadomienie").tag("notify-only")
                        Text("Tylko banner").tag("banner-only")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Integracje
    var integrationsTab: some View {
        Form {
            Section("Status") {
                let herdr = ["/opt/homebrew/bin/herdr","/usr/local/bin/herdr",FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/herdr").path].first { FileManager.default.isExecutableFile(atPath: $0) }
                LabeledContent("herdr", value: herdr != nil ? "✓ zainstalowany" : "✗ brak")
                let orca = ["/usr/local/bin/orca","/Applications/Orca.app/Contents/Resources/bin/orca","/opt/homebrew/bin/orca"].first { FileManager.default.isExecutableFile(atPath: $0) }
                LabeledContent("Orca", value: orca != nil ? "✓ zainstalowany" : "✗ brak")
                let ghostty = FileManager.default.fileExists(atPath: "/Applications/Ghostty.app")
                LabeledContent("Ghostty", value: ghostty ? "✓ zainstalowany" : "✗ brak")
            }
            Section("Uprawnienia") {
                Text("Dostępność (Ghostty) ustaw w Ustawieniach systemowych → Prywatność i ochrona → Dostępność.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func save() {
        cfg.save()
        saveResult = "Zapisano \(Date().formatted(date: .omitted, time: .standard))"
    }

    func fetchVoices() {
        guard !cfg.elevenlabsApiKey.isEmpty else { testResult = "Brak klucza"; return }
        let url = URL(string: "https://api.elevenlabs.io/v1/voices")!
        var req = URLRequest(url: url)
        req.setValue(cfg.elevenlabsApiKey, forHTTPHeaderField: "xi-api-key")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let voicesArr = json["voices"] as? [[String: Any]] {
                let opts = voicesArr.compactMap { v -> VoiceOption? in
                    guard let id = v["voice_id"] as? String else { return nil }
                    let name = (v["name"] as? String) ?? id
                    return VoiceOption(id: id, name: name)
                }
                DispatchQueue.main.async { self.voices = opts; self.testResult = "Pobrano \(opts.count) głosów" }
            } else {
                DispatchQueue.main.async { self.testResult = "Błąd pobierania" }
            }
        }.resume()
    }

    func testConnection() {
        guard !cfg.elevenlabsApiKey.isEmpty else { testResult = "Brak klucza"; return }
        let url = URL(string: "https://api.elevenlabs.io/v1/user")!
        var req = URLRequest(url: url)
        req.setValue(cfg.elevenlabsApiKey, forHTTPHeaderField: "xi-api-key")
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async {
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    self.testResult = "OK (200)"
                } else {
                    self.testResult = "Błąd połączenia"
                }
            }
        }.resume()
    }
}


struct HistoryView: View {
    @ObservedObject var store: AlertStore
    var body: some View {
        VStack {
            Text("Historia alertów").font(.headline)
            List(store.history) { item in
                VStack(alignment: .leading) {
                    Text(item.title).font(.body)
                    Text("\(item.kind) · \(item.agent ?? "") · \(item.time)").font(.caption).foregroundColor(.secondary)
                }
            }
            HStack {
                Button("Wyczyść historię") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode-alerts/history.jsonl")
                    try? FileManager.default.removeItem(at: url)
                    store.history.removeAll()
                }
                Spacer()
            }.padding()
        }.frame(width: 420, height: 500)
    }
}

// MARK: - App

@main
struct LimitAlertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AlertStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("LimitAlert", systemImage: "exclamationmark.triangle.fill") {
            if store.alerts.isEmpty {
                Text("Brak alertów").foregroundColor(.secondary)
            } else {
                ForEach(store.alerts) { item in
                    Menu(item.title) {
                        Button("Przejdź") { store.jump(item) }
                        Button("Odrzuć") { store.remove(item) }
                    }
                }
                Divider()
                Button("Wyczyść wszystko") { store.clearAll() }
            }
            Divider()
            SettingsLink {
                Text("Ustawienia…")
            }
            Button("Test alertu") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                p.arguments = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/opencode-alerts/alerts.py").path, "alert", "Test alertu", "--kind", "limit", "--agent", "opencode"]
                try? p.run()
            }
            Button("Historia") { openWindow(id: "history") }
            Divider()
            Button("Zakończ") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }

        Window("Historia", id: "history") {
            HistoryView(store: store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppPresence.register()
        // SIGTERM/SIGINT (np. pkill) też sprzątają znacznik pid.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                AppPresence.unregister()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppPresence.unregister()
    }
}
