import Foundation

public enum Assembler {

    public static func makeMarkdown(
        name: String,
        date: Date,
        duration: Double,
        segments: [Segment]
    ) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = df.string(from: date)

        var md = "# Call: \(name) — \(dateStr)\n\n"
        md += "**Duration**: \(formatDuration(duration))\n\n"
        md += "## Transcript\n\n"

        if segments.isEmpty {
            md += "_No transcribed content._\n"
            return md
        }

        for seg in segments {
            let ts = formatTimestamp(seg.start)
            md += "**[\(ts)] \(seg.speaker)**: \(seg.text)\n\n"
        }
        return md
    }
}
