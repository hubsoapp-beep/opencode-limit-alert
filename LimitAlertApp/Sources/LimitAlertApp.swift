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
    /// Ile sekund baner trzyma alert po przeczytaniu, zanim pokaże następny.
    var toastHoldSeconds: Double = 4
    /// To samo, gdy głos jest wyłączony (trzeba więcej czasu na przeczytanie).
    var toastNoVoiceSeconds: Double = 7

    static let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode/limit-alert.json")

    init() {}

    /// Ręczne dekodowanie, bo syntezowane `Codable` wymagałoby wszystkich kluczy
    /// w pliku JSON. Dzięki temu stary/niepełny config nie resetuje ustawień
    /// (np. klucza ElevenLabs) do domyślnych.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        elevenlabsApiKey = try c.decodeIfPresent(String.self, forKey: .elevenlabsApiKey) ?? d.elevenlabsApiKey
        voiceId = try c.decodeIfPresent(String.self, forKey: .voiceId) ?? d.voiceId
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId) ?? d.modelId
        systemVoice = try c.decodeIfPresent(String.self, forKey: .systemVoice) ?? d.systemVoice
        announceDone = try c.decodeIfPresent(Bool.self, forKey: .announceDone) ?? d.announceDone
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? d.debug
        useNativeNotifications = try c.decodeIfPresent(Bool.self, forKey: .useNativeNotifications) ?? d.useNativeNotifications
        bannerOnlyNoVoice = try c.decodeIfPresent(Bool.self, forKey: .bannerOnlyNoVoice) ?? d.bannerOnlyNoVoice
        quietHoursStart = try c.decodeIfPresent(Int.self, forKey: .quietHoursStart) ?? d.quietHoursStart
        quietHoursEnd = try c.decodeIfPresent(Int.self, forKey: .quietHoursEnd) ?? d.quietHoursEnd
        webhookURL = try c.decodeIfPresent(String.self, forKey: .webhookURL) ?? d.webhookURL
        voiceByAgent = try c.decodeIfPresent([String: String].self, forKey: .voiceByAgent) ?? d.voiceByAgent
        systemVoiceByAgent = try c.decodeIfPresent([String: String].self, forKey: .systemVoiceByAgent) ?? d.systemVoiceByAgent
        agentEnabled = try c.decodeIfPresent([String: Bool].self, forKey: .agentEnabled) ?? d.agentEnabled
        agentMode = try c.decodeIfPresent([String: String].self, forKey: .agentMode) ?? d.agentMode
        toastHoldSeconds = try c.decodeIfPresent(Double.self, forKey: .toastHoldSeconds) ?? d.toastHoldSeconds
        toastNoVoiceSeconds = try c.decodeIfPresent(Double.self, forKey: .toastNoVoiceSeconds) ?? d.toastNoVoiceSeconds
    }

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

class AlertStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AlertStore()

    @Published var alerts: [AlertItem] = []
    let panel = FloatingPanelController()
    @Published var history: [AlertItem] = []
    private let spool = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode-alerts")
    private var timer: Timer?
    private let speech = SpeechQueue()
    private let historyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".opencode-alerts/history.jsonl")

    /// Alert aktualnie pokazany w banerze i kolejka następnych. Jeden na raz —
    /// dzięki temu kilka alertów nie wyskakuje i nie mówi jednocześnie.
    private var current: AlertItem?
    private var queue: [AlertItem] = []
    private var knownIDs = Set<String>()
    private var batchIndex = 0
    private var batchTotal = 0
    private var advanceTask: DispatchWorkItem?
    private var enqueueTask: DispatchWorkItem?
    private var pendingNew: [AlertItem] = []
    /// Ostatnie alerty wysłane jako natywne powiadomienia — po kliknięciu
    /// w powiadomienie w Centrum powiadomień wracamy do właściwego zadania.
    private var notified: [String: AlertItem] = [:]
    private var notifiedOrder: [String] = []

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        loadHistory()
        panel.state.onAction = { [weak self] item, action in
            self?.perform(action, for: item)
        }
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
            let visible = Set(items.map { $0.id })

            // Alert zniknął z kolejki (np. sesja ruszyła dalej) — zdejmij go też z banera.
            self.queue.removeAll { !visible.contains($0.id) }
            if let current = self.current, !visible.contains(current.id) {
                self.clearCurrent()
            }

            // Nowe pokazujemy w kolejności pojawienia się (najstarszy pierwszy).
            let fresh = items
                .filter { !self.knownIDs.contains($0.id) }
                .sorted { $0.time < $1.time }
            self.knownIDs = visible
            self.alerts = items
            self.collect(fresh)
            self.pump()
        }
    }

    func remove(_ item: AlertItem) {
        perform(.dismiss, for: item)
    }

    func jump(_ item: AlertItem) {
        perform(.jump, for: item)
    }

    func clearAll() {
        DebugLog.write("clearAll")
        advanceTask?.cancel()
        advanceTask = nil
        enqueueTask?.cancel()
        enqueueTask = nil
        pendingNew.removeAll()
        speech.stop()
        current = nil
        queue.removeAll()
        panel.hide()
        if let files = try? FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil) {
            for u in files where u.pathExtension == "json" {
                try? FileManager.default.removeItem(at: u)
            }
        }
        knownIDs.removeAll()
        alerts.removeAll()
    }

    // MARK: - Kolejka

    /// Alerty zapisane niemal równocześnie (np. kilka sesji naraz) zbieramy
    /// przez chwilę, żeby od razu znać pełne „1 / 3”, a nie „1 / 1”.
    private func collect(_ items: [AlertItem]) {
        guard !items.isEmpty else { return }
        for item in items where !pendingNew.contains(where: { $0.id == item.id }) {
            pendingNew.append(item)
        }
        enqueueTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.pendingNew.sorted { $0.time < $1.time }
            self.pendingNew.removeAll()
            for item in batch { self.enqueue(item) }
            self.pump()
        }
        enqueueTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    private func enqueue(_ item: AlertItem) {
        guard current?.id != item.id, !queue.contains(where: { $0.id == item.id }) else { return }
        if current == nil && queue.isEmpty {
            batchIndex = 0
            batchTotal = 0
        }
        queue.append(item)
        appendHistory(item)
        if current != nil {
            batchTotal = max(batchTotal, batchIndex + queue.count)
            panel.updateProgress(index: batchIndex, total: batchTotal)
        }
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        current = item
        batchIndex += 1
        batchTotal = max(batchTotal, batchIndex + queue.count)
        present(item)
    }

    private func present(_ item: AlertItem) {
        let cfg = AppConfig.load()
        let agent = item.agent ?? "opencode"
        guard cfg.agentEnabled[agent] ?? true else {
            clearCurrent()
            return
        }

        let mode = cfg.agentMode[agent] ?? "voice+notify"
        if !cfg.webhookURL.isEmpty {
            sendWebhook(item: item, url: cfg.webhookURL)
        }

        let hour = Calendar.current.component(.hour, from: Date())
        let quiet = isQuietHour(hour: hour, start: cfg.quietHoursStart, end: cfg.quietHoursEnd)
        let voiceAllowed = !cfg.bannerOnlyNoVoice
            && mode != "notify-only"
            && mode != "banner-only"
            && !quiet
            && (item.kind != "done" || cfg.announceDone)
        let notifies = cfg.useNativeNotifications && mode != "banner-only"

        DebugLog.write("present \(batchIndex)/\(batchTotal) \(item.id) agent=\(agent) quiet=\(quiet) voice=\(voiceAllowed)")
        panel.present(item, index: batchIndex, total: max(batchTotal, 1))
        if notifies {
            // Gdy i tak czytamy na głos, natywne powiadomienie nie dodaje dźwięku.
            sendNativeNotification(item: item, withSound: !voiceAllowed)
        }

        if voiceAllowed {
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
            speech.enqueue(text: text,
                           voiceId: voiceId,
                           systemVoice: systemVoice,
                           apiKey: cfg.elevenlabsApiKey,
                           modelId: cfg.modelId) { [weak self] in
                self?.scheduleAdvance(after: cfg.toastHoldSeconds)
            }
        } else {
            scheduleAdvance(after: cfg.toastNoVoiceSeconds)
        }
    }

    private func scheduleAdvance(after seconds: TimeInterval) {
        DebugLog.write("hold \(seconds)s")
        advanceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.current != nil else { return }
            self.autoAdvance()
        }
        advanceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, seconds), execute: task)
    }

    /// Po przeczytaniu alert znika i zaczyna się następny z kolejki.
    private func autoAdvance() {
        guard let item = current else { return }
        DebugLog.write("auto-advance \(item.id)")
        forgetNotification(item.id)
        removeFromSpool(item)
        alerts.removeAll { $0.id == item.id }
        knownIDs.remove(item.id)
        clearCurrent()
    }

    private func clearCurrent() {
        DebugLog.write("clear current \(current?.id ?? "-")")
        advanceTask?.cancel()
        advanceTask = nil
        enqueueTask?.cancel()
        enqueueTask = nil
        pendingNew.removeAll()
        speech.stop()
        current = nil
        panel.hide()
        // Krótka przerwa, żeby kolejne powiadomienie pojawiło się osobno.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.pump()
        }
    }

    private func perform(_ action: BannerAction, for item: AlertItem) {
        DebugLog.write("perform \(action) \(item.id)")
        forgetNotification(item.id)
        removeFromSpool(item)
        alerts.removeAll { $0.id == item.id }
        queue.removeAll { $0.id == item.id }
        knownIDs.remove(item.id)
        if current?.id == item.id {
            clearCurrent()
        }
        if action == .jump {
            jumpToAlert(item)
        }
    }

    private func removeFromSpool(_ item: AlertItem) {
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

    private func isQuietHour(hour: Int, start: Int, end: Int) -> Bool {
        if start == end { return false } // 0/0 = cicha godzina wyłączona
        if start < end {
            return hour >= start && hour < end
        } else {
            return hour >= start || hour < end
        }
    }

    private func sendNativeNotification(item: AlertItem, withSound: Bool) {
        notified[item.id] = item
        if !notifiedOrder.contains(item.id) { notifiedOrder.append(item.id) }
        if notifiedOrder.count > 50 {
            let old = notifiedOrder.removeFirst()
            notified.removeValue(forKey: old)
        }
        let content = UNMutableNotificationContent()
        content.title = "LimitAlert"
        content.subtitle = item.title
        content.body = item.kind
        content.sound = withSound ? .default : nil
        let req = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func forgetNotification(_ id: String) {
        notified.removeValue(forKey: id)
        notifiedOrder.removeAll { $0 == id }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Klik w natywne powiadomienie = przejście do zadania (jak klik w baner).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        DispatchQueue.main.async {
            if let item = self.notified[id] ?? self.alerts.first(where: { $0.id == id }) {
                self.jump(item)
            }
            completionHandler()
        }
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
            Section("Kolejka banera") {
                Stepper("Po przeczytaniu pokazuj następny po \(Int(cfg.toastHoldSeconds)) s",
                        value: $cfg.toastHoldSeconds, in: 1...30, step: 1)
                Stepper("Bez głosu trzymaj \(Int(cfg.toastNoVoiceSeconds)) s",
                        value: $cfg.toastNoVoiceSeconds, in: 2...60, step: 1)
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
        VStack(spacing: 0) {
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
        }
    }
}

// MARK: - App

@main
struct LimitAlertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppPresence.register()
        _ = AlertStore.shared // start store'a od razu — timer spoolu i panel
        setupStatusItem()
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

    // MARK: Pasek menu — natywne NSMenu zamiast MenuBarExtra

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                     accessibilityDescription: "LimitAlert")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    /// Buduje menu przy każdym otwarciu — zawsze aktualna lista alertów.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = AlertStore.shared
        store.refresh()

        if store.alerts.isEmpty {
            let empty = NSMenuItem(title: "Brak alertów", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for alert in store.alerts {
                let sub = NSMenu()
                sub.autoenablesItems = false
                let jump = NSMenuItem(title: "Przejdź", action: #selector(alertJump(_:)), keyEquivalent: "")
                jump.target = self
                jump.representedObject = alert
                jump.isEnabled = true
                let dismiss = NSMenuItem(title: "Odrzuć", action: #selector(alertDismiss(_:)), keyEquivalent: "")
                dismiss.target = self
                dismiss.representedObject = alert
                dismiss.isEnabled = true
                sub.addItem(jump)
                sub.addItem(dismiss)

                let parent = NSMenuItem(title: alert.title, action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Wyczyść wszystko", action: #selector(clearAllAlerts(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }

        menu.addItem(.separator())

        let test = NSMenuItem(title: "Test alertu", action: #selector(runTestAlert(_:)), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let history = NSMenuItem(title: "Historia", action: #selector(openHistory(_:)), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        let settings = NSMenuItem(title: "Ustawienia…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Zakończ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: Akcje menu

    @objc private func alertJump(_ sender: NSMenuItem) {
        guard let alert = sender.representedObject as? AlertItem else { return }
        AlertStore.shared.jump(alert)
    }

    @objc private func alertDismiss(_ sender: NSMenuItem) {
        guard let alert = sender.representedObject as? AlertItem else { return }
        AlertStore.shared.remove(alert)
    }

    @objc private func clearAllAlerts(_ sender: NSMenuItem) {
        AlertStore.shared.clearAll()
    }

    @objc private func runTestAlert(_ sender: NSMenuItem) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin/opencode-alerts/alerts.py").path,
            "alert", "Test alertu", "--kind", "limit", "--agent", "opencode"]
        try? p.run()
    }

    @objc private func openHistory(_ sender: NSMenuItem) {
        if let w = historyWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Historia alertów"
        w.contentView = NSHostingView(rootView: HistoryView(store: AlertStore.shared))
        w.center()
        w.isReleasedWhenClosed = false
        historyWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Ustawienia LimitAlert"
        w.contentView = NSHostingView(rootView: SettingsView())
        w.center()
        w.isReleasedWhenClosed = false
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
