import Foundation
import FluidAudio

/// Diarization a posteriori de la piste système via FluidAudio (CoreML, 100% local).
/// Les modèles doivent être pré-téléchargés (scripts/download-models.sh) —
/// aucune connexion réseau n'est tentée à l'exécution.
public enum Diarizer {

    /// Emplacement par défaut des modèles pré-téléchargés.
    public static func defaultModelsDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".call-recorder/models/speaker-diarization-coreml", isDirectory: true)
    }

    /// Vérifie que les deux bundles CoreML requis sont présents.
    public static func modelsAvailable(in dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("pyannote_segmentation.mlmodelc/coremldata.bin").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("wespeaker_v2.mlmodelc/coremldata.bin").path)
    }

    /// Diarize la piste système et renomme les segments portant `speakerToSplit`
    /// en "<speakerToSplit> 1", "<speakerToSplit> 2", … (numérotés par ordre
    /// de première prise de parole). Les autres segments (micro) sont inchangés.
    /// Si un seul locuteur est détecté, les segments sont retournés tels quels.
    public static func tag(
        segments: [Segment],
        speakerToSplit: String,
        systemAudioURL: URL,
        modelsDir: URL
    ) throws -> [Segment] {
        let models = try DiarizerModels.load(
            localSegmentationModel: modelsDir.appendingPathComponent("pyannote_segmentation.mlmodelc"),
            localEmbeddingModel: modelsDir.appendingPathComponent("wespeaker_v2.mlmodelc")
        )
        // Seuil 0.7 par défaut trop permissif : il fusionne des voix pourtant
        // distinctes. 0.6 validé sur audio de test (plage recommandée 0.5–0.9)
        let diarizer = DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.6))
        diarizer.initialize(models: models)

        let samples = try AudioConverter().resampleAudioFile(systemAudioURL)
        let result = try diarizer.performCompleteDiarization(samples)
        let turns = result.segments

        let distinctSpeakers = Set(turns.map(\.speakerId))
        guard distinctSpeakers.count > 1 else { return segments }

        // Numérotation stable : ordre de première prise de parole
        var labelFor: [String: String] = [:]
        for turn in turns.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds })
        where labelFor[turn.speakerId] == nil {
            labelFor[turn.speakerId] = "\(speakerToSplit) \(labelFor.count + 1)"
        }

        return segments.map { seg in
            guard seg.speaker == speakerToSplit,
                  let speakerId = dominantSpeaker(for: seg, in: turns),
                  let label = labelFor[speakerId]
            else { return seg }
            return Segment(start: seg.start, end: seg.end, speaker: label, text: seg.text)
        }
    }

    /// Locuteur au recouvrement temporel maximal avec le segment ; à défaut
    /// (silence, désaccord de timing), le tour de parole le plus proche.
    private static func dominantSpeaker(
        for seg: Segment,
        in turns: [TimedSpeakerSegment]
    ) -> String? {
        var overlapBySpeaker: [String: Double] = [:]
        for turn in turns {
            let overlap = min(seg.end, Double(turn.endTimeSeconds)) - max(seg.start, Double(turn.startTimeSeconds))
            if overlap > 0 {
                overlapBySpeaker[turn.speakerId, default: 0] += overlap
            }
        }
        if let best = overlapBySpeaker.max(by: { $0.value < $1.value }) {
            return best.key
        }
        let nearest = turns.min {
            distance(seg: seg, turn: $0) < distance(seg: seg, turn: $1)
        }
        return nearest?.speakerId
    }

    private static func distance(seg: Segment, turn: TimedSpeakerSegment) -> Double {
        max(Double(turn.startTimeSeconds) - seg.end, seg.start - Double(turn.endTimeSeconds))
    }
}
