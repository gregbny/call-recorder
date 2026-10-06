import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Capture simultanée du micro (AVAudioEngine) et de l'audio système
/// d'une application cible (ScreenCaptureKit). Les deux pistes sont
/// écrites dans des fichiers M4A/AAC.
public final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let micURL: URL
    private let sysURL: URL
    private let appName: String

    private let engine = AVAudioEngine()
    private var micFile: AVAudioFile?
    private var sysFile: AVAudioFile?
    private var scStream: SCStream?

    private var startTime: Date?
    private let writeQueue = DispatchQueue(label: "call-recorder.write")

    /// Callbacks optionnels appelés en plus de l'écriture fichier.
    /// Utiles pour brancher une transcription live.
    public var onMicBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onSysBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// `appName` vide ⇒ capture tout l'audio système (pas de filtre par app).
    public init(micURL: URL, sysURL: URL, appName: String) {
        self.micURL = micURL
        self.sysURL = sysURL
        self.appName = appName
    }

    public func start() async throws {
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        guard micOK else {
            throw NSError(domain: "Recorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Permission micro refusée."])
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVEncoderBitRateKey: 256000
        ]
        let micFile = try AVAudioFile(
            forWriting: micURL,
            settings: aacSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.micFile = micFile

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.writeQueue.async {
                try? self.micFile?.write(from: buffer)
            }
            self.onMicBuffer?(buffer)
        }

        try engine.start()

        try await startSystemCapture()

        self.startTime = Date()
    }

    private func startSystemCapture() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            throw NSError(domain: "Recorder", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Permission enregistrement d'écran refusée ou indisponible: \(error)"])
        }

        guard let display = content.displays.first else {
            throw NSError(domain: "Recorder", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Aucun écran disponible."])
        }

        let needle = appName.lowercased()
        let targetApps: [SCRunningApplication]
        if needle.isEmpty {
            targetApps = []
        } else {
            let matched = content.applications.filter { app in
                app.applicationName.lowercased().contains(needle) ||
                app.bundleIdentifier.lowercased().contains(needle)
            }
            if matched.isEmpty {
                FileHandle.standardError.write(
                    "⚠️  Application '\(appName)' introuvable — capture de tout l'audio système.\n"
                        .data(using: .utf8)!)
            }
            targetApps = matched
        }

        let filter: SCContentFilter
        if targetApps.isEmpty {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            filter = SCContentFilter(
                display: display,
                including: targetApps,
                exceptingWindows: []
            )
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writeQueue)

        try await stream.startCapture()
        self.scStream = stream
    }

    /// Arrête les deux captures et retourne la durée totale (secondes).
    public func stop() async throws -> Double {
        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        writeQueue.sync { }
        micFile = nil
        sysFile = nil

        let dur = startTime.map { Date().timeIntervalSince($0) } ?? 0
        return dur
    }

    // MARK: - SCStreamOutput
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }

        if sysFile == nil {
            let fmt = buffer.format
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: fmt.sampleRate,
                AVNumberOfChannelsKey: fmt.channelCount,
                AVEncoderBitRateKey: 256000
            ]
            do {
                sysFile = try AVAudioFile(
                    forWriting: sysURL,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                FileHandle.standardError.write(
                    "Erreur création fichier système: \(error)\n".data(using: .utf8)!)
                return
            }
        }
        try? sysFile?.write(from: buffer)
        onSysBuffer?(buffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(
            "SCStream arrêté avec erreur: \(error)\n".data(using: .utf8)!)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }
        var asbd = asbdPtr.pointee
        guard let avFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let numSamples = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: numSamples) else {
            return nil
        }
        pcm.frameLength = numSamples

        let abl = pcm.mutableAudioBufferList
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: abl
        )
        guard status == noErr else { return nil }
        return pcm
    }
}
