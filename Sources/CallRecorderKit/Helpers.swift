import Foundation

public func slugify(_ s: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let spaceReplaced = s.replacingOccurrences(of: " ", with: "-")
    let scalars = spaceReplaced.unicodeScalars.filter { allowed.contains($0) }
    let out = String(String.UnicodeScalarView(scalars))
    return out.isEmpty ? "call" : out
}

public func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return "\(h) h \(m) min \(s) s" }
    if m > 0 { return "\(m) min \(s) s" }
    return "\(s) s"
}

public func formatTimestamp(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return String(format: "%02d:%02d:%02d", h, m, s)
}
