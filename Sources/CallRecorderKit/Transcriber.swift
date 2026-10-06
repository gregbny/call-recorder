import Foundation
import AVFoundation
import Speech
import CoreMedia

public struct Segment: Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String
    public let text: String

    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

@available(macOS 26.0, *)
public enum Transcriber {

    public static func transcribe(url: URL, locale: Locale, speaker: String) async throws -> [Segment] {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { return [] }

        await requestSpeechAuth()

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collectTask: Task<[Segment], Error> = Task {
            var segments: [Segment] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = result.text
                var startSec: Double? = nil
                var endSec: Double? = nil
                for run in text.runs {
                    if let tr = run.audioTimeRange {
                        let s = CMTimeGetSeconds(tr.start)
                        let e = CMTimeGetSeconds(tr.end)
                        if startSec == nil || s < startSec! { startSec = s }
                        if endSec == nil || e > endSec! { endSec = e }
                    }
                }
                if startSec == nil {
                    startSec = CMTimeGetSeconds(result.range.start)
                    endSec = CMTimeGetSeconds(result.range.end)
                }
                let str = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if str.isEmpty { continue }
                segments.append(Segment(
                    start: startSec ?? 0,
                    end: endSec ?? (startSec ?? 0),
                    speaker: speaker,
                    text: str
                ))
            }
            return segments
        }

        let audioFile = try AVAudioFile(forReading: url)
        let _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return try await collectTask.value
    }

    private static func requestSpeechAuth() async {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { _ in
                cont.resume()
            }
        }
    }
}
