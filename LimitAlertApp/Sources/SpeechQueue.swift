import Foundation

/// Jeden mówca na całą aplikację. Alerty trafiają do kolejki i są czytane
/// dokładnie po kolei — nowy nie przerywa poprzedniego i nie nakłada się z nim.
final class SpeechQueue {
    private struct Job {
        let id = UUID()
        let text: String
        let voiceId: String
        let systemVoice: String
        let apiKey: String
        let modelId: String
        let onFinish: () -> Void
    }

    private var jobs: [Job] = []
    private var active: Job?
    private var playerProcess: Process?
    private var sayProcess: Process?
    private var fetchTask: URLSessionDataTask?

    func enqueue(text: String, voiceId: String, systemVoice: String,
                 apiKey: String, modelId: String,
                 onFinish: @escaping () -> Void) {
        let job = Job(text: text, voiceId: voiceId, systemVoice: systemVoice,
                      apiKey: apiKey, modelId: modelId, onFinish: onFinish)
        DispatchQueue.main.async {
            self.jobs.append(job)
            self.pump()
        }
    }

    /// Przerywa bieżące czytanie i czyści kolejkę (np. gdy alert odrzucono).
    func stop() {
        jobs.removeAll()
        active = nil
        fetchTask?.cancel()
        fetchTask = nil
        playerProcess?.terminationHandler = nil
        playerProcess?.terminate()
        playerProcess = nil
        sayProcess?.terminationHandler = nil
        sayProcess?.terminate()
        sayProcess = nil
    }

    private func pump() {
        guard active == nil, !jobs.isEmpty else { return }
        let job = jobs.removeFirst()
        active = job
        DebugLog.write("speak start: \(job.text)")
        if !job.apiKey.isEmpty, !job.voiceId.isEmpty {
            fetchElevenLabs(job)
        } else {
            speakWithSystemVoice(job)
        }
    }

    // MARK: - ElevenLabs

    private func fetchElevenLabs(_ job: Job) {
        guard let url = URL(string:
            "https://api.elevenlabs.io/v1/text-to-speech/\(job.voiceId)?output_format=mp3_44100_128") else {
            speakWithSystemVoice(job)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(job.apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": job.text, "model_id": job.modelId])

        let task = URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.active?.id == job.id else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, status == 200, let data, !data.isEmpty else {
                    DebugLog.write("tts elevenlabs failed: http=\(status) \(error?.localizedDescription ?? "empty")")
                    self.speakWithSystemVoice(job)
                    return
                }
                self.playMp3(job, data: data)
            }
        }
        fetchTask = task
        task.resume()
    }

    /// Odtwarzamy przez `/usr/bin/afplay`, nie przez AVAudioPlayer — ten
    /// odrzuca mp3 z ElevenLabs (kAudioFormatUnsupportedDataFormatError),
    /// przez co alert wypadał na głos systemowy zamiast głosu z API.
    private func playMp3(_ job: Job, data: Data) {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("limit-alert-\(UUID().uuidString).mp3")
        do {
            try data.write(to: file)
        } catch {
            DebugLog.write("tts write failed: \(error.localizedDescription)")
            speakWithSystemVoice(job)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [file.path]
        process.terminationHandler = { [weak self] proc in
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async {
                guard let self, self.active?.id == job.id else { return }
                if proc.terminationStatus != 0 {
                    DebugLog.write("tts afplay failed, using system voice")
                    self.speakWithSystemVoice(job)
                } else {
                    self.finish(job)
                }
            }
        }
        do {
            try process.run()
            playerProcess = process
        } catch {
            DebugLog.write("tts afplay launch failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: file)
            speakWithSystemVoice(job)
        }
    }

    // MARK: - Systemowy `say`

    private func speakWithSystemVoice(_ job: Job) {
        DispatchQueue.main.async {
            guard self.active?.id == job.id else { return }
            self.runSay(job, voice: job.systemVoice)
        }
    }

    private func runSay(_ job: Job, voice: String) {
        // Pusty głos = `say` bez -v, czyli domyślny Alex (EN, męski). Wolimy
        // ciszę niż obcy lektor, więc wtedy w ogóle nie czytamy.
        guard !voice.isEmpty else {
            DebugLog.write("say skipped: no system voice configured")
            finish(job)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, job.text]
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.active?.id == job.id else { return }
                if proc.terminationStatus != 0 {
                    // Głos z konfiguracji nie istnieje — cisza.
                    DebugLog.write("say voice \(voice) failed, staying silent")
                }
                self.finish(job)
            }
        }
        do {
            try process.run()
            sayProcess = process
        } catch {
            DebugLog.write("say failed: \(error.localizedDescription)")
            finish(job)
        }
    }

    private func finish(_ job: Job) {
        guard active?.id == job.id else { return }
        active = nil
        playerProcess = nil
        sayProcess = nil
        fetchTask = nil
        DebugLog.write("speak end")
        job.onFinish()
        // Następny tekst startuje dopiero po zakończeniu poprzedniego.
        DispatchQueue.main.async { self.pump() }
    }
}
