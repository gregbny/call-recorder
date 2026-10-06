import Foundation
import AVFoundation
import CallRecorderKit

let kVersion = "0.3.0"

struct Options {
    var name: String = "call"
    var outputDir: URL
    var tempDir: URL
    var lang: String = "fr-FR"
    var app: String = "Microsoft Teams"
    var keepAudio: Bool = false
    var diarize: Bool = false
    var modelsDir: URL
    var processMic: URL?
    var processSys: URL?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.outputDir = home.appendingPathComponent("Recordings", isDirectory: true)
        self.tempDir = home.appendingPathComponent("Recordings/.tmp", isDirectory: true)
        self.modelsDir = Diarizer.defaultModelsDir()
    }
}

func printHelp() {
    print("""
    call-recorder \(kVersion)

    Usage: call-recorder [options]

    Options:
      --name <str>          Call name (default: "call")
      --output-dir <path>   Folder for the final .md files (default: ~/Recordings)
      --temp-dir <path>     Folder for temporary .m4a files (default: ~/Recordings/.tmp)
      --lang <locale>       Transcription language (default: fr-FR)
      --app <name>          App to capture (default: "Microsoft Teams" — empty = all audio)
      --keep-audio          Keep the .m4a files after transcription
      --diarize             Identify remote speakers on the system track
                            (requires the models: scripts/download-models.sh)
      --models-dir <path>   Diarization models folder
                            (default: ~/.call-recorder/models/speaker-diarization-coreml)
      --process <mic> <sys> Transcribe two existing .m4a files (interrupted session)
                            without recording; audio files are kept
      --help, -h            Show this help
      --version             Show the version

    While recording, Ctrl+C stops cleanly, transcribes and writes the markdown.
    """)
}

func parseArgs(_ argv: [String]) -> Options {
    var opt = Options()
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--help", "-h":
            printHelp()
            exit(0)
        case "--version":
            print(kVersion)
            exit(0)
        case "--name":
            i += 1
            opt.name = argv[i]
        case "--output-dir":
            i += 1
            opt.outputDir = URL(fileURLWithPath: (argv[i] as NSString).expandingTildeInPath)
        case "--temp-dir":
            i += 1
            opt.tempDir = URL(fileURLWithPath: (argv[i] as NSString).expandingTildeInPath)
        case "--lang":
            i += 1
            opt.lang = argv[i]
        case "--app":
            i += 1
            opt.app = argv[i]
        case "--keep-audio":
            opt.keepAudio = true
        case "--diarize":
            opt.diarize = true
        case "--models-dir":
            i += 1
            opt.modelsDir = URL(fileURLWithPath: (argv[i] as NSString).expandingTildeInPath)
        case "--process":
            i += 1
            opt.processMic = URL(fileURLWithPath: (argv[i] as NSString).expandingTildeInPath)
            i += 1
            opt.processSys = URL(fileURLWithPath: (argv[i] as NSString).expandingTildeInPath)
        default:
            FileHandle.standardError.write("Unknown option: \(a)\n".data(using: .utf8)!)
            exit(2)
        }
        i += 1
    }
    return opt
}

@available(macOS 26.0, *)
func runApp() async {
    setbuf(stdout, nil)
    print("call-recorder \(kVersion) — starting…")
    fflush(stdout)
    let opts = parseArgs(CommandLine.arguments)
    let fm = FileManager.default

    // Vérifier les modèles AVANT d'enregistrer : échouer après coup gâcherait le call
    if opts.diarize && !Diarizer.modelsAvailable(in: opts.modelsDir) {
        FileHandle.standardError.write("""
        Diarization models not found in: \(opts.modelsDir.path)
        Run first: scripts/download-models.sh

        """.data(using: .utf8)!)
        exit(1)
    }
    try? fm.createDirectory(at: opts.outputDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: opts.tempDir, withIntermediateDirectories: true)

    // Mode récupération : traiter des .m4a existants sans enregistrer
    if let micIn = opts.processMic, let sysIn = opts.processSys {
        guard fm.fileExists(atPath: micIn.path), fm.fileExists(atPath: sysIn.path) else {
            FileHandle.standardError.write("File not found: \(micIn.path) or \(sysIn.path)\n".data(using: .utf8)!)
            exit(1)
        }
        func fileDuration(_ url: URL) -> Double {
            guard let f = try? AVAudioFile(forReading: url) else { return 0 }
            return Double(f.length) / f.processingFormat.sampleRate
        }
        // Durée = piste la plus longue ; date du call = création du fichier micro
        let duration = max(fileDuration(micIn), fileDuration(sysIn))
        let creation = (try? fm.attributesOfItem(atPath: micIn.path)[.creationDate]) as? Date
        let mdURL = await produceMarkdown(
            micURL: micIn, sysURL: sysIn,
            opts: opts, startDate: creation ?? Date(), duration: duration
        )
        print("✅ Markdown written: \(mdURL.path) (audio files kept)")
        return
    }

    let startDate = Date()
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    df.locale = Locale(identifier: "en_US_POSIX")
    let stamp = df.string(from: startDate)
    let slug = slugify(opts.name)

    let micURL = opts.tempDir.appendingPathComponent("\(slug)_\(stamp)_mic.m4a")
    let sysURL = opts.tempDir.appendingPathComponent("\(slug)_\(stamp)_sys.m4a")

    print("📂 Temp files: \(opts.tempDir.path)")
    print("📂 Output    : \(opts.outputDir.path)")

    let recorder = Recorder(micURL: micURL, sysURL: sysURL, appName: opts.app)

    let stopSignal = DispatchSemaphore(value: 0)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    signal(SIGINT, SIG_IGN)
    src.setEventHandler {
        stopSignal.signal()
    }
    src.resume()

    print("▶  Recording… (Ctrl+C to stop)")
    fflush(stdout)
    do {
        try await recorder.start()
    } catch {
        FileHandle.standardError.write("Failed to start recording: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    let timerTask = Task {
        let t0 = Date()
        while !Task.isCancelled {
            let d = Date().timeIntervalSince(t0)
            let str = "⏺  \(formatTimestamp(d))"
            FileHandle.standardError.write("\r\(str)".data(using: .utf8)!)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            stopSignal.wait()
            cont.resume()
        }
    }

    timerTask.cancel()
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    print("⏹  Stopping and finalizing…")

    let duration: Double
    do {
        duration = try await recorder.stop()
    } catch {
        FileHandle.standardError.write("Failed to stop recording: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    let mdURL = await produceMarkdown(
        micURL: micURL, sysURL: sysURL,
        opts: opts, startDate: startDate, duration: duration
    )

    if !opts.keepAudio {
        try? fm.removeItem(at: micURL)
        try? fm.removeItem(at: sysURL)
    }

    print("✅ Markdown written: \(mdURL.path)")
}

/// Pipeline commun : transcription → diarization (option) → markdown.
/// Utilisé après un enregistrement live ou sur des .m4a existants (--process).
@available(macOS 26.0, *)
func produceMarkdown(micURL: URL, sysURL: URL, opts: Options, startDate: Date, duration: Double) async -> URL {
    print("📝 Transcribing (language: \(opts.lang))…")
    let locale = Locale(identifier: opts.lang)

    async let micSegs = Transcriber.transcribe(url: micURL, locale: locale, speaker: Speaker.me)
    async let sysSegs = Transcriber.transcribe(url: sysURL, locale: locale, speaker: Speaker.interlocutor)

    var segments: [Segment]
    do {
        let m = try await micSegs
        let s = try await sysSegs
        segments = (m + s).sorted { $0.start < $1.start }
    } catch {
        FileHandle.standardError.write("Transcription failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    if opts.diarize {
        print("🗣  Identifying speakers on the system track…")
        do {
            segments = try Diarizer.tag(
                segments: segments,
                speakerToSplit: Speaker.interlocutor,
                systemAudioURL: sysURL,
                modelsDir: opts.modelsDir
            )
        } catch {
            // Non bloquant : on garde la transcription sans distinction des interlocuteurs
            FileHandle.standardError.write("⚠️  Diarization failed (\(error)) — keeping generic labels\n".data(using: .utf8)!)
        }
    }

    let md = Assembler.makeMarkdown(
        name: opts.name,
        date: startDate,
        duration: duration,
        segments: segments
    )
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    df.locale = Locale(identifier: "en_US_POSIX")
    let mdURL = opts.outputDir.appendingPathComponent("\(slugify(opts.name))_\(df.string(from: startDate)).md")
    do {
        try md.write(to: mdURL, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write("Failed to write markdown: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    return mdURL
}

if #available(macOS 26.0, *) {
    await runApp()
} else {
    FileHandle.standardError.write("macOS 26.0+ required.\n".data(using: .utf8)!)
    exit(1)
}
