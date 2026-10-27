import SigmaFlowDictionary
import AppKit
import Foundation

/// Everything SigmaFlow knows about you, as a folder you can carry to another Mac.
///
/// Five plain files: transcripts, dictionary, snippets, styles, settings. Cloud API keys
/// stay in the Keychain and never leave; speech models are downloads and are simply
/// fetched again on the other side. Import reads such a folder and either merges it into
/// what is here or replaces it outright.
@MainActor
enum DataPortability {
    /// What an export folder holds, counted so the import can say what it found.
    struct Manifest {
        var runs: [DictationRun] = []
        var dictionary: [DictionaryEntry] = []
        var snippets: [Snippet] = []
        var styles: [WritingStyle] = []
        var settings: [String: Any]?

        var summary: String {
            var parts: [String] = []
            parts.append("\(runs.count) recording\(runs.count == 1 ? "" : "s")")
            parts.append("\(dictionary.count) dictionary entr\(dictionary.count == 1 ? "y" : "ies")")
            parts.append("\(snippets.count) snippet\(snippets.count == 1 ? "" : "s")")
            parts.append("\(styles.count) style\(styles.count == 1 ? "" : "s")")
            if settings != nil { parts.append("settings") }
            return parts.joined(separator: ", ")
        }

        var isEmpty: Bool {
            runs.isEmpty && dictionary.isEmpty && snippets.isEmpty && styles.isEmpty && settings == nil
        }
    }

    enum Failure: LocalizedError {
        case notAnExport
        case io(String)

        var errorDescription: String? {
            switch self {
            case .notAnExport: "That folder does not look like a SigmaFlow export. Nothing was changed."
            case .io(let message): message
            }
        }
    }

    static var dataDirectory: URL { RunLog.directory }

    private static let runsName = "runs.jsonl"
    private static let dictionaryName = "dictionary.txt"
    private static let snippetsName = "snippets.json"
    private static let stylesName = "styles.json"
    private static let settingsName = "settings.json"

    // MARK: - Export

    /// Writes the export folder to the Desktop and returns it.
    static func export() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        var folder = desktop.appendingPathComponent("SigmaFlow Export \(formatter.string(from: Date()))", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = desktop.appendingPathComponent(
                "SigmaFlow Export \(formatter.string(from: Date())) \(suffix)", isDirectory: true
            )
            suffix += 1
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (source, name) in [
                (RunLog.runsURL, runsName), (DictionaryStore.fileURL, dictionaryName),
                (SnippetStore.fileURL, snippetsName), (StyleStore.fileURL, stylesName),
            ] where FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
            }
            let settings = try JSONSerialization.data(
                withJSONObject: Settings.shared.exported(), options: [.prettyPrinted, .sortedKeys]
            )
            try settings.write(to: folder.appendingPathComponent(settingsName), options: .atomic)
        } catch {
            throw Failure.io(error.localizedDescription)
        }
        Log.app.info("exported to \(folder.path, privacy: .public)")
        return folder
    }

    /// Bytes on disk across the four data files, for the manifest line.
    static func currentSize() -> Int64 {
        [RunLog.runsURL, DictionaryStore.fileURL, SnippetStore.fileURL, StyleStore.fileURL].reduce(0) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    // MARK: - Import

    /// Reads an export folder without changing anything.
    static func read(_ folder: URL) throws -> Manifest {
        var manifest = Manifest()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: folder.appendingPathComponent(runsName)) {
            manifest.runs = data.split(separator: 0x0A).compactMap { try? decoder.decode(DictationRun.self, from: Data($0)) }
        }
        if let text = try? String(contentsOf: folder.appendingPathComponent(dictionaryName), encoding: .utf8) {
            manifest.dictionary = DictionaryStore.parse(text)
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent(snippetsName)) {
            manifest.snippets = (try? JSONDecoder().decode([Snippet].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent(stylesName)) {
            manifest.styles = (try? JSONDecoder().decode([WritingStyle].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent(settingsName)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            manifest.settings = json
        }
        guard !manifest.isEmpty else { throw Failure.notAnExport }
        return manifest
    }

    /// Adds what is new; leaves this Mac's settings alone.
    static func merge(_ manifest: Manifest) -> String {
        let haveRuns = Set(RunStore.shared.runs.map(\.id))
        let newRuns = manifest.runs.filter { !haveRuns.contains($0.id) }
        if !newRuns.isEmpty { RunLog.record(newRuns) }
        let words = DictionaryStore.shared.merge(manifest.dictionary)
        let snippets = SnippetStore.shared.merge(manifest.snippets)
        let styles = StyleStore.shared.merge(manifest.styles)

        var parts = [
            "\(newRuns.count) recording\(newRuns.count == 1 ? "" : "s")",
            "\(words) dictionary entr\(words == 1 ? "y" : "ies")",
            "\(snippets) snippet\(snippets == 1 ? "" : "s")",
            "\(styles.added) style\(styles.added == 1 ? "" : "s")",
        ]
        if styles.skipped > 0 {
            parts.append("\(styles.skipped) style\(styles.skipped == 1 ? "" : "s") skipped for a clashing name or shortcut")
        }
        return "Merged: " + parts.joined(separator: ", ") + ". Settings were left as they are on this Mac."
    }

    /// Makes this Mac match the export.
    static func replace(with manifest: Manifest) -> String {
        RunLog.replaceAll(manifest.runs)
        DictionaryStore.shared.replaceAll(manifest.dictionary)
        SnippetStore.shared.replaceAll(manifest.snippets)
        StyleStore.shared.replaceAll(manifest.styles)
        if let settings = manifest.settings {
            Settings.shared.apply(exported: settings)
        }
        return "Replaced. This Mac now has \(manifest.summary). Your API keys were not touched."
    }

    /// The standard folder picker, pointed at the Desktop.
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a SigmaFlow Export folder."
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }
}
