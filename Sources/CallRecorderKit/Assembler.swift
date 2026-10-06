import Foundation

public enum Assembler {

    public static func makeMarkdown(
        name: String,
        date: Date,
        duration: Double,
        segments: [Segment],
        summary: String? = nil
    ) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = df.string(from: date)

        var md = "# Call : \(name) — \(dateStr)\n\n"
        md += "**Durée** : \(formatDuration(duration))\n\n"

        if let summary = summary, !summary.isEmpty {
            md += summary
            if !md.hasSuffix("\n\n") { md += "\n" }
        }

        md += "## Transcription\n\n"

        if segments.isEmpty {
            md += "_Aucun contenu transcrit._\n"
            return md
        }

        for seg in segments {
            let ts = formatTimestamp(seg.start)
            md += "**[\(ts)] \(seg.speaker)** : \(seg.text)\n\n"
        }
        return md
    }
}
