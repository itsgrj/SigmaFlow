import SigmaFlowDictionary
import AppKit
import Foundation
import Observation

/// One completed dictation.
struct DictationRun: Codable, Sendable, Identifiable {
    /// Stable identity, so a single run can be deleted without matching on its text.
    ///
    /// Decoded leniently: runs written before this existed have no `id` field, and failing
    /// their whole line would throw away the user's history to add a delete button. Those
    /// get a fresh id on load, which is then persisted the next time the file is rewritten.
    var id: UUID = UUID()

    let date: Date
    let engine: String
    /// How long the key was held.
    let audioSeconds: Double
    /// Release → final text ready. This is the latency you actually feel.
    let processSeconds: Double
    /// What the user ended up with: as typed, then as they corrected it in the field, when
    /// the field could be read back (`CorrectionLearner`).
    var text: String

    /// Dictionary corrections that fired on this transcript. Recorded so history can show
    /// whether the dictionary is actually doing anything, rather than leaving it to faith.
    ///
    /// Optional for backwards compatibility: runs recorded before the dictionary existed
    /// decode with this nil rather than failing the whole line.
    var corrections: [AppliedCorrection]?

    var realtimeFactor: Double { audioSeconds / max(processSeconds, 0.0001) }
    var characters: Int { text.count }

    init(
        id: UUID = UUID(),
        date: Date,
        engine: String,
        audioSeconds: Double,
        processSeconds: Double,
        text: String,
        corrections: [AppliedCorrection]? = nil
    ) {
        self.id = id
        self.date = date
        self.engine = engine
        self.audioSeconds = audioSeconds
        self.processSeconds = processSeconds
        self.text = text
        self.corrections = corrections
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        engine = try container.decode(String.self, forKey: .engine)
        audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
        processSeconds = try container.decode(Double.self, forKey: .processSeconds)
        text = try container.decode(String.self, forKey: .text)
        // Older lines may carry a `group` key from the removed compare mode; unknown keys
        // are ignored, so those rows simply load as ordinary dictations.
        corrections = try container.decodeIfPresent([AppliedCorrection].self, forKey: .corrections)
    }
}

/// Live-updating store behind the Transcriptions page and the data export.
@MainActor
@Observable
final class RunStore {
    static let shared = RunStore()

    private(set) var runs: [DictationRun] = []

    /// What the last delete took, kept for `DS.Motion.undoHold` so Undo can put it back.
    private(set) var lastDeleted: Deleted?

    struct Deleted: Identifiable {
        let id = UUID()
        let runs: [DictationRun]
    }

    private var activationObserver: NSObjectProtocol?

    private init() {
        reload()
        // A month file edited by hand in another app shows here when SigmaFlow comes back.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                _ = RunLog.loadTakingHandEdits()
                RunStore.shared.reload()
            }
        }
    }

    func reload() {
        runs = RunLog.load()
    }

    /// Deletes the chosen runs; Undo shows for `DS.Motion.undoHold`, as on Meetings.
    func delete(_ chosen: [DictationRun]) {
        guard !chosen.isEmpty else { return }
        RunLog.delete(ids: Set(chosen.map(\.id)))
        let deleted = Deleted(runs: chosen)
        lastDeleted = deleted
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(DS.Motion.undoHold))
            if lastDeleted?.id == deleted.id { lastDeleted = nil }
        }
    }

    func undoDelete() {
        guard let deleted = lastDeleted else { return }
        lastDeleted = nil
        RunLog.restore(deleted.runs)
    }
}

/// Every dictation, kept in the SigmaFlow folder since 19 Oct 2026 (picks 1B 2B 3A 4A):
/// `Dictations/2026/10 October.md` and the other month files are what the person opens
/// (`DictationMarkdown`), and `Dictations/.dictations.jsonl` beside them holds the app's
/// details for each one, one JSON object per line, oldest first: id, timings, model,
/// dictionary corrections. Insights, export and the MCP helper read that file.
///
/// Before any month is written, its file is read back, so a word fixed there by hand reaches
/// the app instead of being overwritten (3A). While the SigmaFlow folder can't be found,
/// dictations wait in the app's own folder and are filed when it is back.
@MainActor
enum RunLog {
    /// The app's own folder in Application Support, for what isn't the person's record.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigmaFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Where every dictation lived before the move, and where new ones wait while the
    /// SigmaFlow folder can't be found.
    static var waitingURL: URL { directory.appendingPathComponent("runs.jsonl") }

    /// The history as it was before the move, kept as it was until Gokul says it can go.
    static var keptURL: URL { directory.appendingPathComponent("runs before the SigmaFlow folder.jsonl") }

    /// `~/SigmaFlow/Dictations`, or nil while the SigmaFlow folder can't be found.
    static var dictationsFolder: URL? {
        MeetingLibrary.shared.root?.appendingPathComponent("Dictations", isDirectory: true)
    }

    private static let detailsName = ".dictations.jsonl"

    /// The details file: in the SigmaFlow folder, or the waiting file while it is missing.
    static var runsURL: URL {
        guard let folder = dictationsFolder else { return waitingURL }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(detailsName)
    }

    static func record(_ run: DictationRun) {
        record([run])
    }

    static func record(_ new: [DictationRun]) {
        guard !new.isEmpty else { return }
        // Hand edits first: the month about to be written may have some.
        let runs = loadTakingHandEdits()
        new.forEach(append)
        writeMonths(of: runs + new, touching: new)
        RunStore.shared.reload()
    }

    private static func append(_ run: DictationRun) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(run) else { return }
        line.append(0x0A) // newline

        if let handle = try? FileHandle(forWritingTo: runsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: runsURL)
        }
    }

    static func load() -> [DictationRun] {
        decode(runsURL)
    }

    private static func decode(_ url: URL) -> [DictationRun] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(DictationRun.self, from: Data(line))
        }
    }

    /// Replaces one run's text with what the user corrected it to.
    static func update(_ id: UUID, text: String) {
        var runs = loadTakingHandEdits()
        guard let i = runs.firstIndex(where: { $0.id == id }), runs[i].text != text else { return }
        runs[i].text = text
        rewrite(runs, touching: [runs[i]])
    }

    /// Deletes one run.
    static func delete(_ run: DictationRun) {
        delete(ids: [run.id])
    }

    static func delete(ids: Set<UUID>) {
        let runs = loadTakingHandEdits()
        rewrite(runs.filter { !ids.contains($0.id) }, touching: runs.filter { ids.contains($0.id) })
    }

    /// Puts deleted runs back in date order, beside anything dictated since.
    static func restore(_ runs: [DictationRun]) {
        let current = loadTakingHandEdits()
        let present = Set(current.map(\.id))
        let back = runs.filter { !present.contains($0.id) }
        rewrite((current + back).sorted { $0.date < $1.date }, touching: back)
    }

    /// Replaces the whole history with `runs`, used by import.
    static func replaceAll(_ runs: [DictationRun]) {
        let before = load()
        rewrite(runs, touching: before + runs)
    }

    /// Replaces the whole file. Deleting can't be an append, and rewriting also persists the
    /// ids that older runs were assigned on load.
    private static func rewrite(_ runs: [DictationRun], touching changed: [DictationRun]) {
        writeDetails(runs)
        writeMonths(of: runs, touching: changed)
        RunStore.shared.reload()
    }

    private static func writeDetails(_ runs: [DictationRun]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let body = runs.compactMap { run -> String? in
            guard let data = try? encoder.encode(run) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")

        // Atomic: a partial write here would lose history that the user didn't ask to delete.
        try? (body.isEmpty ? "" : body + "\n")
            .write(to: runsURL, atomically: true, encoding: .utf8)
    }

    // MARK: - The month files

    /// The history with any words fixed by hand in the month files taken in, and saved when
    /// there were some.
    static func loadTakingHandEdits() -> [DictationRun] {
        var runs = load()
        guard let folder = dictationsFolder else { return runs }
        var edits: [UUID: String] = [:]
        for (path, month) in Dictionary(grouping: runs, by: { DictationMarkdown.relativePath(for: $0.date) }) {
            guard let file = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8),
                  file != DictationMarkdown.render(month: month) else { continue }
            edits.merge(DictationMarkdown.handEdits(in: file, for: month)) { _, new in new }
        }
        guard !edits.isEmpty else { return runs }
        for i in runs.indices {
            if let text = edits[runs[i].id] { runs[i].text = text }
        }
        Log.app.info("dictations: \(edits.count, privacy: .public) edited by hand in the month files")
        writeDetails(runs)
        return runs
    }

    /// Writes the month files that `changed` falls in; every month when `changed` is nil.
    /// A month left with no dictations is written empty rather than left showing old rows.
    private static func writeMonths(of runs: [DictationRun], touching changed: [DictationRun]?) {
        guard let folder = dictationsFolder else { return }
        let byMonth = Dictionary(grouping: runs) { DictationMarkdown.relativePath(for: $0.date) }
        let months = changed.map { Set($0.map { DictationMarkdown.relativePath(for: $0.date) }) } ?? Set(byMonth.keys)
        for path in months {
            let url = folder.appendingPathComponent(path)
            let month = byMonth[path] ?? []
            let text = month.isEmpty ? "" : DictationMarkdown.render(month: month)
            if month.isEmpty, !FileManager.default.fileExists(atPath: url.path) { continue }
            guard (try? String(contentsOf: url, encoding: .utf8)) != text else { continue }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Into the folder

    /// At launch and whenever the SigmaFlow folder is found or changed: any dictations
    /// waiting in the app's folder join the ones in the SigmaFlow folder, the whole history
    /// the first time (4A), and every month file is brought up to date.
    static func settle() {
        guard dictationsFolder != nil else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: waitingURL.path) {
            let waiting = decode(waitingURL)
            let current = load()
            let present = Set(current.map(\.id))
            let merged = (current + waiting.filter { !present.contains($0.id) }).sorted { $0.date < $1.date }
            writeDetails(merged)
            // Let go of the waiting file only once every one of its dictations reads back
            // from the folder: the first time it is kept, renamed; later ones were only a
            // queue and go.
            let filed = Set(load().map(\.id))
            if waiting.allSatisfy({ filed.contains($0.id) }) {
                if fm.fileExists(atPath: keptURL.path) {
                    try? fm.removeItem(at: waitingURL)
                } else {
                    try? fm.moveItem(at: waitingURL, to: keptURL)
                }
                Log.app.info("dictations: \(waiting.count, privacy: .public) filed in the SigmaFlow folder")
            } else {
                Log.app.error("dictations: filing into the SigmaFlow folder did not read back; the waiting file stays")
            }
        }
        writeMonths(of: loadTakingHandEdits(), touching: nil)
        RunStore.shared.reload()
    }

    /// The person pointed the app at another folder. One with no dictations of its own takes
    /// the history along, so Transcriptions doesn't empty; the old folder keeps its copy.
    static func folderChanged(from old: URL?) {
        guard let old, let folder = dictationsFolder,
              old.standardizedFileURL != MeetingLibrary.shared.root?.standardizedFileURL else { return }
        let previous = old.appendingPathComponent("Dictations", isDirectory: true).appendingPathComponent(detailsName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: previous.path),
              !fm.fileExists(atPath: folder.appendingPathComponent(detailsName).path) else { return }
        writeDetails(decode(previous))
    }
}
