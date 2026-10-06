import Foundation
import AVFoundation
import Speech
import CoreMedia

/// Transcription en streaming d'un flux audio. Reçoit des `AVAudioPCMBuffer`
/// via `feed(_:)` et appelle `onSegment` à chaque résultat final.
/// Une instance = un locuteur (mic OU système).
@available(macOS 26.0, *)
public final class LiveTranscriber: @unchecked Sendable {
    private let speaker: String
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var consumeTask: Task<Void, Never>?
    private var analyzeTask: Task<Void, Error>?
    private let startWall: Date

    /// Format requis par l'analyzer (résolu après `start`).
    private var analyzerFormat: AVAudioFormat?
    /// Convertisseur lazy par format d'entrée rencontré.
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?
    private let convQueue = DispatchQueue(label: "live-transcriber.convert")

    public init(speaker: String, startWall: Date) {
        self.speaker = speaker
        self.startWall = startWall
    }

    public func start(
        locale: Locale,
        onSegment: @Sendable @escaping (Segment) -> Void,
        onVolatile: (@Sendable (String, String) -> Void)? = nil
    ) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // Format recommandé par l'analyzer pour ce module.
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let format else {
            throw NSError(domain: "LiveTranscriber", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "No audio format compatible with SpeechAnalyzer."
            ])
        }
        self.analyzerFormat = format

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = cont

        let speaker = self.speaker
        let startWall = self.startWall

        self.consumeTask = Task.detached(priority: .userInitiated) {
            do {
                for try await result in transcriber.results {
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
                        let elapsed = Date().timeIntervalSince(startWall)
                        startSec = elapsed
                        endSec = elapsed
                    }
                    let str = String(text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !str.isEmpty else { continue }
                    if result.isFinal {
                        onVolatile?(speaker, "")
                        onSegment(Segment(
                            start: startSec ?? 0,
                            end: endSec ?? (startSec ?? 0),
                            speaker: speaker,
                            text: str
                        ))
                    } else {
                        onVolatile?(speaker, str)
                    }
                }
            } catch {
                FileHandle.standardError.write(
                    "Live (\(speaker)) results error: \(error)\n".data(using: .utf8)!)
            }
        }

        self.analyzeTask = Task.detached(priority: .userInitiated) {
            do {
                try await analyzer.analyzeSequence(stream)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                FileHandle.standardError.write(
                    "Live (\(speaker)) analyze error: \(error)\n".data(using: .utf8)!)
            }
        }
    }

    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let cont = continuation, let target = analyzerFormat else { return }

        convQueue.async { [weak self] in
            guard let self = self else { return }
            guard let converted = self.convert(buffer: buffer, to: target) else { return }
            let input = AnalyzerInput(buffer: converted)
            cont.yield(input)
        }
    }

    private func convert(buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Si déjà au bon format, on saute la conversion.
        if buffer.format.sampleRate == target.sampleRate
            && buffer.format.channelCount == target.channelCount
            && buffer.format.commonFormat == target.commonFormat
            && buffer.format.isInterleaved == target.isInterleaved {
            return buffer
        }

        if converter == nil || lastInputFormat == nil
            || lastInputFormat?.sampleRate != buffer.format.sampleRate
            || lastInputFormat?.channelCount != buffer.format.channelCount {
            converter = AVAudioConverter(from: buffer.format, to: target)
            lastInputFormat = buffer.format
        }
        guard let converter = converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * ratio + 1024
        )
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: outFrameCapacity
        ) else { return nil }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || convError != nil {
            return nil
        }
        guard outBuf.frameLength > 0 else { return nil }
        return outBuf
    }

    public func finish() async {
        continuation?.finish()
        continuation = nil
        _ = await analyzeTask?.result
        _ = await consumeTask?.value
    }
}
