import Foundation
import FoundationModels

@available(macOS 26.0, *)
public enum Summarizer {

    public enum Stage: Sendable {
        case checking
        case chunk(index: Int, total: Int)
        case finalizing
    }

    /// Génère la section markdown "## Résumé", ou nil si Apple Intelligence
    /// est indisponible ou si la transcription est vide.
    public static func summarize(
        segments: [Segment],
        language: String,
        onStage: (@Sendable (Stage) -> Void)? = nil
    ) async -> String? {
        guard !segments.isEmpty else { return nil }

        onStage?(.checking)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return nil
        }

        // Court-circuit : transcript trop court pour mériter un appel modèle.
        // Le petit modèle on-device a tendance à recopier les exemples du prompt
        // quand il n'a rien de substantiel à résumer.
        let totalContentChars = segments.map { $0.text.count }.reduce(0, +)
        let totalDuration = (segments.last?.end ?? 0) - (segments.first?.start ?? 0)
        if totalContentChars < 120 || totalDuration < 20 {
            return "## Résumé\n\n**TL;DR** : Test/échange court, pas de contenu structuré à résumer.\n\n"
        }

        let transcript = segments
            .map { "[\(formatTimestamp($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        let chunks = chunkTranscript(transcript, maxChars: 6000)
        let langName = languageName(for: language)

        // Single chunk : on demande directement le format final (TLDR + sections).
        if chunks.count == 1 {
            onStage?(.chunk(index: 1, total: 1))
            do {
                let raw = try await generateFinal(
                    inputBlock: "Transcript :\n\(chunks[0])",
                    langName: langName
                )
                return renderFinalSection(from: raw)
            } catch {
                FileHandle.standardError.write(
                    "⚠️  Résumé échoué : \(error.localizedDescription)\n".data(using: .utf8)!)
                return nil
            }
        }

        // Multi-chunk : map (analyse partielle par passage) puis reduce (consolidation finale).
        var partials: [String] = []
        for (idx, chunk) in chunks.enumerated() {
            onStage?(.chunk(index: idx + 1, total: chunks.count))
            do {
                let raw = try await generatePartial(chunk: chunk, langName: langName)
                partials.append(raw)
            } catch {
                FileHandle.standardError.write(
                    "⚠️  Résumé du passage \(idx + 1)/\(chunks.count) échoué : \(error.localizedDescription)\n"
                        .data(using: .utf8)!)
            }
        }

        guard !partials.isEmpty else { return nil }

        onStage?(.finalizing)
        let joined = partials.enumerated().map { idx, md in
            "=== Passage \(idx + 1)/\(partials.count) ===\n\(md)"
        }.joined(separator: "\n\n")

        do {
            let raw = try await generateFinal(
                inputBlock: "Analyses des passages :\n\(joined)",
                langName: langName
            )
            return renderFinalSection(from: raw)
        } catch {
            FileHandle.standardError.write(
                "⚠️  Consolidation du résumé échouée : \(error.localizedDescription)\n"
                    .data(using: .utf8)!)
            var md = "## Résumé (consolidation échouée — analyses brutes)\n\n"
            for (idx, p) in partials.enumerated() {
                md += "### Passage \(idx + 1)\n\n\(p)\n\n"
            }
            return md
        }
    }

    // MARK: - Génération via FoundationModels

    private static func generatePartial(chunk: String, langName: String) async throws -> String {
        let instructions = Instructions("""
        Tu analyses des passages de transcript de réunion. Tu réponds en \(langName), \
        de façon strictement factuelle, sans préambule, sans guillemets, sans interprétation. \
        Tu ignores les digressions personnelles, le bavardage, les hésitations.
        """)
        let prompt = """
        Analyse ce passage. Réponds EXACTEMENT dans le format ci-dessous, rien de plus, rien de moins. \
        Si une rubrique est vide, écris la ligne « (aucune) ».

        FORMAT :
        SUJETS:
        - <thème abordé, 2 à 6 mots, sans phrase complète>

        DÉCISIONS:
        - <décision EXPLICITEMENT actée pendant le passage>

        ACTIONS:
        - <Acteur — verbe d'action — objet (— échéance si mentionnée)>

        Règles strictes :
        - N'invente JAMAIS. Si rien de concret, écris « (aucune) ».
        - Pas de guillemets autour des items.
        - Une simple observation n'est PAS une action.
        - Un sujet abordé n'est PAS une décision.

        Passage :
        \(chunk)
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        return response.content
    }

    private static func generateFinal(inputBlock: String, langName: String) async throws -> String {
        let instructions = Instructions("""
        Tu produis le résumé final d'une réunion professionnelle. Tu réponds en \(langName), \
        de façon strictement factuelle, concise, sans préambule, sans guillemets, \
        sans interprétation. Tu ignores les digressions personnelles et le bavardage. \
        Tu dédupliques agressivement.
        """)
        let prompt = """
        Produis le résumé final. Réponds EXACTEMENT dans le format ci-dessous, rien de plus, \
        rien de moins. Si une rubrique est vide, écris la ligne « (aucune) ».

        FORMAT :
        TLDR: <UNE phrase factuelle qui décrit l'objet principal et le résultat du call>

        POINTS CLÉS:
        - <point factuel précis, repris du transcript ; max 5 items>

        DÉCISIONS:
        - <décision EXPLICITEMENT actée pendant le call>

        ACTIONS:
        - <Acteur — verbe d'action — objet (— échéance si mentionnée)>

        Règles strictes :
        - N'invente JAMAIS. Si rien de concret pour une rubrique, écris « (aucune) ».
        - Pas de guillemets autour des items.
        - Une simple observation ou anecdote n'est PAS une action.
        - Un sujet abordé n'est PAS une décision sauf si quelqu'un a explicitement tranché.
        - Aucune répétition entre POINTS CLÉS, DÉCISIONS et ACTIONS.
        - Si le contenu est trop court ou personnel pour mériter un résumé professionnel, \
          mets « (aucune) » dans toutes les sections de listes et écris dans TLDR \
          « Test/échange court, pas de contenu structuré à résumer. »

        IMPORTANT : ne recopie JAMAIS d'éléments des exemples ci-dessous. Ils ne montrent que la FORME,
        pas le fond. Toute information doit provenir EXCLUSIVEMENT du transcript fourni.

        Exemple de FORME (à NE PAS recopier — placeholders abstraits) :
        TLDR: <une phrase factuelle décrivant l'objet et le résultat du call>
        POINTS CLÉS:
        - <fait précis tiré du transcript>
        DÉCISIONS:
        - <décision explicitement actée>
        ACTIONS:
        - <Personne — verbe — objet (— échéance si mentionnée)>

        Exemple de FORME pour un call trop court ou sans contenu :
        TLDR: Test/échange court, pas de contenu structuré à résumer.
        POINTS CLÉS:
        - (aucune)
        DÉCISIONS:
        - (aucune)
        ACTIONS:
        - (aucune)

        \(inputBlock)
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        return response.content
    }

    // MARK: - Chunking

    private static func chunkTranscript(_ text: String, maxChars: Int) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty && current.count + line.count + 1 > maxChars {
                chunks.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n" }
            current += String(line)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Parsing du format texte

    private struct Parsed {
        var tldr: String = ""
        var keyPoints: [String] = []
        var topics: [String] = []
        var decisions: [String] = []
        var actions: [String] = []
    }

    private static func parse(_ raw: String) -> Parsed {
        var out = Parsed()
        var section: String? = nil
        var tldrBuf: [String] = []

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let upper = line.uppercased()
            if upper.hasPrefix("TLDR") || upper.hasPrefix("TL;DR") || upper.hasPrefix("TL ;DR") {
                section = "tldr"
                let after = line.drop { $0 != ":" }.dropFirst()
                let val = String(after).trimmingCharacters(in: .whitespaces)
                if !val.isEmpty { tldrBuf.append(stripQuotes(val)) }
                continue
            }
            if upper.hasPrefix("POINTS CLÉS") || upper.hasPrefix("POINTS CLES") || upper.hasPrefix("KEY POINTS") {
                section = "keyPoints"; continue
            }
            if upper.hasPrefix("SUJETS") || upper.hasPrefix("TOPICS") {
                section = "topics"; continue
            }
            if upper.hasPrefix("DÉCISIONS") || upper.hasPrefix("DECISIONS") {
                section = "decisions"; continue
            }
            if upper.hasPrefix("ACTIONS") || upper.hasPrefix("ACTION ITEMS") {
                section = "actions"; continue
            }

            let cleaned = stripQuotes(stripBullet(line))
            if isEmptyMarker(cleaned) { continue }
            if cleaned.count < 4 { continue }

            switch section {
            case "tldr":      tldrBuf.append(cleaned)
            case "keyPoints": out.keyPoints.append(cleaned)
            case "topics":    out.topics.append(cleaned)
            case "decisions": out.decisions.append(cleaned)
            case "actions":   out.actions.append(cleaned)
            default:          break
            }
        }
        out.tldr = tldrBuf.joined(separator: " ")
        return out
    }

    private static func isEmptyMarker(_ s: String) -> Bool {
        let normalized = s.lowercased()
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces)
        return ["aucune", "aucun", "n/a", "néant", "neant", "_aucun_", "_aucune_"].contains(normalized)
    }

    private static func stripBullet(_ line: String) -> String {
        var s = line
        let prefixes = ["- ", "* ", "• ", "– ", "— "]
        for p in prefixes where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
            break
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Retire les guillemets et apostrophes typographiques en début/fin.
    private static func stripQuotes(_ s: String) -> String {
        let quoteChars: Set<Character> = ["\"", "'", "«", "»", "“", "”", "‘", "’", "`"]
        var trimmed = s.trimmingCharacters(in: .whitespaces)
        while let first = trimmed.first, quoteChars.contains(first) {
            trimmed.removeFirst()
        }
        while let last = trimmed.last, quoteChars.contains(last) {
            trimmed.removeLast()
        }
        // Cas guillemets imbriqués genre « "..." »
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, let last = trimmed.last,
           quoteChars.contains(first), quoteChars.contains(last) {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    // MARK: - Rendu markdown

    private static func renderFinalSection(from raw: String) -> String {
        let p = parse(raw)
        var md = "## Résumé\n\n"
        if !p.tldr.isEmpty {
            md += "**TL;DR** : \(p.tldr)\n\n"
        }
        md += sectionMd(title: "Points clés", items: p.keyPoints, checkbox: false)
        md += sectionMd(title: "Sujets", items: p.topics, checkbox: false)
        md += sectionMd(title: "Décisions", items: p.decisions, checkbox: false)
        md += sectionMd(title: "Actions", items: p.actions, checkbox: true)

        let nothing = p.tldr.isEmpty && p.keyPoints.isEmpty && p.topics.isEmpty
            && p.decisions.isEmpty && p.actions.isEmpty
        if nothing {
            md += raw.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        return md
    }

    private static func sectionMd(title: String, items: [String], checkbox: Bool) -> String {
        let clean = dedup(items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard !clean.isEmpty else { return "" }
        var s = "### \(title)\n\n"
        let prefix = checkbox ? "- [ ] " : "- "
        for item in clean { s += "\(prefix)\(item)\n" }
        s += "\n"
        return s
    }

    private static func dedup(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            let key = item.lowercased().trimmingCharacters(in: .whitespaces)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            out.append(item)
        }
        return out
    }

    private static func languageName(for code: String) -> String {
        switch code.prefix(2).lowercased() {
        case "fr": return "français"
        case "en": return "anglais"
        case "es": return "espagnol"
        case "de": return "allemand"
        case "it": return "italien"
        case "pt": return "portugais"
        case "nl": return "néerlandais"
        default: return "français"
        }
    }
}
