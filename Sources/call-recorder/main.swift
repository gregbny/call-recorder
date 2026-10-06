import Foundation
import AVFoundation
import CallRecorderKit

let kVersion = "0.2.0"

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
      --name <str>          Nom du call (défaut: "call")
      --output-dir <path>   Dossier des .md finaux (défaut: ~/Recordings)
      --temp-dir <path>     Dossier des .m4a temporaires (défaut: ~/Recordings/.tmp)
      --lang <locale>       Langue de transcription (défaut: fr-FR)
      --app <name>          App à capturer (défaut: "Microsoft Teams" — vide = tout l'audio)
      --keep-audio          Conserver les .m4a après transcription
      --diarize             Distinguer les interlocuteurs sur la piste système
                            (nécessite les modèles : scripts/download-models.sh)
      --models-dir <path>   Dossier des modèles de diarization
                            (défaut: ~/.call-recorder/models/speaker-diarization-coreml)
      --process <mic> <sys> Transcrire deux .m4a existants (session interrompue)
                            sans enregistrer ; les fichiers audio sont conservés
      --help, -h            Affiche cette aide
      --version             Affiche la version

    Pendant l'enregistrement, Ctrl+C arrête proprement, transcrit et génère le markdown.
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
            FileHandle.standardError.write("Option inconnue: \(a)\n".data(using: .utf8)!)
            exit(2)
        }
        i += 1
    }
    return opt
}

@available(macOS 26.0, *)
func runApp() async {
    setbuf(stdout, nil)
    print("call-recorder \(kVersion) — initialisation…")
    fflush(stdout)
    let opts = parseArgs(CommandLine.arguments)
    let fm = FileManager.default

    // Vérifier les modèles AVANT d'enregistrer : échouer après coup gâcherait le call
    if opts.diarize && !Diarizer.modelsAvailable(in: opts.modelsDir) {
        FileHandle.standardError.write("""
        Modèles de diarization introuvables dans : \(opts.modelsDir.path)
        Lancez d'abord : scripts/download-models.sh

        """.data(using: .utf8)!)
        exit(1)
    }
    try? fm.createDirectory(at: opts.outputDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: opts.tempDir, withIntermediateDirectories: true)

    // Mode récupération : traiter des .m4a existants sans enregistrer
    if let micIn = opts.processMic, let sysIn = opts.processSys {
        guard fm.fileExists(atPath: micIn.path), fm.fileExists(atPath: sysIn.path) else {
            FileHandle.standardError.write("Fichier introuvable : \(micIn.path) ou \(sysIn.path)\n".data(using: .utf8)!)
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
        print("✅ Markdown produit : \(mdURL.path) (fichiers audio conservés)")
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

    print("📂 Fichiers temp : \(opts.tempDir.path)")
    print("📂 Sortie        : \(opts.outputDir.path)")

    let recorder = Recorder(micURL: micURL, sysURL: sysURL, appName: opts.app)

    let stopSignal = DispatchSemaphore(value: 0)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    signal(SIGINT, SIG_IGN)
    src.setEventHandler {
        stopSignal.signal()
    }
    src.resume()

    print("▶  Démarrage de l'enregistrement… (Ctrl+C pour arrêter)")
    fflush(stdout)
    do {
        try await recorder.start()
    } catch {
        FileHandle.standardError.write("Erreur démarrage enregistrement: \(error)\n".data(using: .utf8)!)
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
    print("⏹  Arrêt et finalisation…")

    let duration: Double
    do {
        duration = try await recorder.stop()
    } catch {
        FileHandle.standardError.write("Erreur arrêt enregistrement: \(error)\n".data(using: .utf8)!)
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

    print("✅ Markdown produit : \(mdURL.path)")
}

/// Pipeline commun : transcription → diarization (option) → résumé → markdown.
/// Utilisé après un enregistrement live ou sur des .m4a existants (--process).
@available(macOS 26.0, *)
func produceMarkdown(micURL: URL, sysURL: URL, opts: Options, startDate: Date, duration: Double) async -> URL {
    print("📝 Transcription en cours (langue: \(opts.lang))…")
    let locale = Locale(identifier: opts.lang)

    async let micSegs = Transcriber.transcribe(url: micURL, locale: locale, speaker: "Moi")
    async let sysSegs = Transcriber.transcribe(url: sysURL, locale: locale, speaker: "Interlocuteur")

    var segments: [Segment]
    do {
        let m = try await micSegs
        let s = try await sysSegs
        segments = (m + s).sorted { $0.start < $1.start }
    } catch {
        FileHandle.standardError.write("Erreur transcription: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    if opts.diarize {
        print("🗣  Diarization de la piste système…")
        do {
            segments = try Diarizer.tag(
                segments: segments,
                speakerToSplit: "Interlocuteur",
                systemAudioURL: sysURL,
                modelsDir: opts.modelsDir
            )
        } catch {
            // Non bloquant : on garde la transcription sans distinction des interlocuteurs
            FileHandle.standardError.write("⚠️  Diarization échouée (\(error)) — labels génériques conservés\n".data(using: .utf8)!)
        }
    }

    print("✨ Résumé via Apple Intelligence…")
    let summary = await Summarizer.summarize(
        segments: segments,
        language: opts.lang,
        onStage: { stage in
            switch stage {
            case .checking:
                FileHandle.standardError.write("   vérification du modèle…\n".data(using: .utf8)!)
            case .chunk(let i, let total):
                FileHandle.standardError.write("   passage \(i)/\(total)…\n".data(using: .utf8)!)
            case .finalizing:
                FileHandle.standardError.write("   consolidation…\n".data(using: .utf8)!)
            }
        }
    )
    if summary == nil {
        print("   (Apple Intelligence indisponible — résumé sauté)")
    }

    let md = Assembler.makeMarkdown(
        name: opts.name,
        date: startDate,
        duration: duration,
        segments: segments,
        summary: summary
    )
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    df.locale = Locale(identifier: "en_US_POSIX")
    let mdURL = opts.outputDir.appendingPathComponent("\(slugify(opts.name))_\(df.string(from: startDate)).md")
    do {
        try md.write(to: mdURL, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write("Erreur écriture markdown: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    return mdURL
}

if #available(macOS 26.0, *) {
    await runApp()
} else {
    FileHandle.standardError.write("macOS 26.0+ requis.\n".data(using: .utf8)!)
    exit(1)
}
