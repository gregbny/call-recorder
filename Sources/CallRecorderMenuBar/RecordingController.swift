import Foundation
import SwiftUI
import CallRecorderKit

@available(macOS 26.0, *)
@MainActor
final class RecordingController: ObservableObject {
    enum State {
        case idle
        case recording
        case processing
    }

    @Published var state: State = .idle
    @Published var callName: String = ""
    @Published var language: String = UserDefaults.standard.string(forKey: "language") ?? "fr-FR" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var diarize: Bool = UserDefaults.standard.bool(forKey: "diarizeEnabled") {
        didSet { UserDefaults.standard.set(diarize, forKey: "diarizeEnabled") }
    }
    @Published var elapsed: TimeInterval = 0
    @Published var lastOutputURL: URL? = nil
    @Published var lastError: String? = nil
    @Published var processingMessage: String = "Processing…"
    @Published var liveSegments: [Segment] = []
    @Published var volatileBySpeaker: [String: String] = [:]

    private var recorder: Recorder?
    private var startDate: Date?
    private var micURL: URL?
    private var sysURL: URL?
    private var timerTask: Task<Void, Never>?
    private var micLive: LiveTranscriber?
    private var sysLive: LiveTranscriber?

    private let outputDir: URL
    private let tempDir: URL

    var diarizeModelsAvailable: Bool {
        Diarizer.modelsAvailable(in: Diarizer.defaultModelsDir())
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.outputDir = home.appendingPathComponent("Recordings", isDirectory: true)
        self.tempDir = home.appendingPathComponent("Recordings/.tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func start() {
        guard state == .idle else { return }
        lastError = nil
        let date = Date()
        startDate = date

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        let stamp = df.string(from: date)

        let mURL = tempDir.appendingPathComponent("session_\(stamp)_mic.m4a")
        let sURL = tempDir.appendingPathComponent("session_\(stamp)_sys.m4a")
        micURL = mURL
        sysURL = sURL

        // appName vide = capture tout l'audio système
        let rec = Recorder(micURL: mURL, sysURL: sURL, appName: "")
        recorder = rec
        elapsed = 0
        liveSegments = []
        state = .recording

        let micLT = LiveTranscriber(speaker: Speaker.me, startWall: date)
        let sysLT = LiveTranscriber(speaker: Speaker.interlocutor, startWall: date)
        micLive = micLT
        sysLive = sysLT

        let appendLive: @Sendable (Segment) -> Void = { [weak self] seg in
            Task { @MainActor in
                guard let self = self else { return }
                self.liveSegments.append(seg)
                // Cap pour éviter de gonfler indéfiniment l'UI sur les longs calls
                if self.liveSegments.count > 500 {
                    self.liveSegments.removeFirst(self.liveSegments.count - 500)
                }
            }
        }
        let updateVolatile: @Sendable (String, String) -> Void = { [weak self] spk, txt in
            Task { @MainActor in
                guard let self = self else { return }
                if txt.isEmpty {
                    self.volatileBySpeaker.removeValue(forKey: spk)
                } else {
                    self.volatileBySpeaker[spk] = txt
                }
            }
        }

        rec.onMicBuffer = { [weak micLT] buf in micLT?.feed(buf) }
        rec.onSysBuffer = { [weak sysLT] buf in sysLT?.feed(buf) }

        let locale = Locale(identifier: language)
        Task { @MainActor in
            do {
                try await micLT.start(locale: locale, onSegment: appendLive, onVolatile: updateVolatile)
                try await sysLT.start(locale: locale, onSegment: appendLive, onVolatile: updateVolatile)
                try await rec.start()
                self.startTimer(from: Date())
            } catch {
                self.lastError = "Start: \(error.localizedDescription)"
                self.state = .idle
                self.recorder = nil
                self.micLive = nil
                self.sysLive = nil
            }
        }
    }

    private func startTimer(from t0: Date) {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.elapsed = Date().timeIntervalSince(t0)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stop() {
        guard state == .recording, let rec = recorder else { return }
        timerTask?.cancel()
        timerTask = nil
        state = .processing

        let name: String = {
            let trimmed = callName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "call" : trimmed
        }()
        let startedAt = startDate ?? Date()
        guard let mURL = micURL, let sURL = sysURL else {
            state = .idle
            return
        }
        let lang = language
        let outDir = outputDir

        processingMessage = "Transcribing…"
        let micLT = micLive
        let sysLT = sysLive
        micLive = nil
        sysLive = nil
        Task { @MainActor in
            do {
                let duration = try await rec.stop()
                await micLT?.finish()
                await sysLT?.finish()
                let locale = Locale(identifier: lang)
                async let micSegs = Transcriber.transcribe(url: mURL, locale: locale, speaker: Speaker.me)
                async let sysSegs = Transcriber.transcribe(url: sURL, locale: locale, speaker: Speaker.interlocutor)
                let m = try await micSegs
                let s = try await sysSegs
                var segments = (m + s).sorted { $0.start < $1.start }

                if self.diarize && self.diarizeModelsAvailable {
                    self.processingMessage = "Identifying speakers…"
                    let input = segments
                    do {
                        // Hors main actor : la diarization est CPU-bound
                        segments = try await Task.detached(priority: .userInitiated) {
                            try Diarizer.tag(
                                segments: input,
                                speakerToSplit: Speaker.interlocutor,
                                systemAudioURL: sURL,
                                modelsDir: Diarizer.defaultModelsDir()
                            )
                        }.value
                    } catch {
                        // Non bloquant : labels génériques conservés
                    }
                }

                let md = Assembler.makeMarkdown(
                    name: name,
                    date: startedAt,
                    duration: duration,
                    segments: segments
                )
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                df.locale = Locale(identifier: "en_US_POSIX")
                let stamp = df.string(from: startedAt)
                let mdURL = outDir.appendingPathComponent("\(slugify(name))_\(stamp).md")
                try md.write(to: mdURL, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: mURL)
                try? FileManager.default.removeItem(at: sURL)
                self.lastOutputURL = mdURL
                self.callName = ""
                self.state = .idle
                self.recorder = nil
                self.liveSegments = []
                self.volatileBySpeaker = [:]
            } catch {
                self.lastError = "Stop: \(error.localizedDescription)"
                self.state = .idle
                self.recorder = nil
            }
        }
    }
}
