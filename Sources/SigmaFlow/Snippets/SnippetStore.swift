import Foundation
import Observation

/// Text you type over and over, behind a short spoken phrase.
///
/// Say "my work email" mid-dictation and the address lands in its place. The trigger is
/// matched as a whole phrase, case-insensitively, anywhere in the utterance; the text can
/// run to as many lines as you like.
struct Snippet: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var trigger: String
    var text: String

    init(id: UUID = UUID(), trigger: String, text: String) {
        self.id = id
        self.trigger = trigger
        self.text = text
    }
}

/// The user's snippets, on disk beside their dictionary and styles.
@MainActor
@Observable
final class SnippetStore {
    static let shared = SnippetStore()

    private(set) var snippets: [Snippet] = []

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigmaFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("snippets.json")
    }

    private init() {
        load()
    }

    func save(_ snippet: Snippet) {
        var normalized = snippet
        normalized.trigger = Self.normalize(snippet.trigger)
        normalized.text = snippet.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.trigger.isEmpty, !normalized.text.isEmpty else { return }
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = normalized
        } else {
            snippets.insert(normalized, at: 0)
        }
        persist()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        persist()
    }

    /// Replaces everything, used by import.
    func replaceAll(_ new: [Snippet]) {
        snippets = new
        persist()
    }

    /// Adds anything whose trigger is not already taken, used by a merge import.
    func merge(_ incoming: [Snippet]) -> Int {
        let taken = Set(snippets.map { $0.trigger.lowercased() })
        let fresh = incoming.filter { !taken.contains($0.trigger.lowercased()) }
        guard !fresh.isEmpty else { return 0 }
        snippets.append(contentsOf: fresh)
        persist()
        return fresh.count
    }

    func reload() { load() }

    // MARK: - Expansion

    /// Expands every trigger that appears in `text` as a whole phrase. Longer triggers win
    /// over shorter ones that they contain, so "my work email" is never half-eaten by "my
    /// email". Trailing punctuation the engine attached to the last word is preserved.
    func expand(_ text: String) -> (text: String, applied: [String]) {
        guard !snippets.isEmpty, !text.isEmpty else { return (text, []) }
        var output = text
        var applied: [String] = []
        let ordered = snippets.sorted { $0.trigger.count > $1.trigger.count }
        for snippet in ordered {
            // The engine may print "my e-mail" or "my  email"; let the separators flex.
            let escaped = snippet.trigger
                .split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "[\\s\\-]+")
            guard let regex = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])",
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(output.startIndex..., in: output)
            guard regex.firstMatch(in: output, range: range) != nil else { continue }
            output = regex.stringByReplacingMatches(
                in: output, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: snippet.text)
            )
            applied.append(snippet.trigger)
        }
        return (output, applied)
    }

    /// Lowercased, single-spaced, no stray punctuation: the form triggers are stored in and
    /// matched by.
    static func normalize(_ trigger: String) -> String {
        trigger
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data)
        else {
            snippets = []
            return
        }
        snippets = decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snippets) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
