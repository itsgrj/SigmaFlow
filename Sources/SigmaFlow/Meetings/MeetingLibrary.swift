import AppKit
import AVFoundation
import Foundation
import Observation

/// The SigmaFlow folder and the meetings inside it.
///
/// The folder sits in the home folder, next to Documents rather than inside it, so nothing
/// syncs unless the user moves it into a synced folder themselves (Gokul, 13 Oct 2026). It
/// is found again by a bookmark, which follows a move within the same disk. When it cannot
/// be found the app says so and asks; it never quietly starts a new empty folder.
///
/// Meetings are read from disk, never cached anywhere else: `reload()` runs whenever the
/// page appears or the app comes back to the front, which is when a Finder edit can have
/// happened.
///
/// Two libraries share the SigmaFlow folder: Meetings (recordings, calls, dropped files) and
/// Conversations (live notes, Gokul 16 Oct 2026, docs/mockups/notes-home.html 1B 2C). The
/// Meetings one finds the folder; Conversations follows it.
@MainActor
@Observable
final class MeetingLibrary {
    static let shared = MeetingLibrary(folderName: "Meetings")
    static let conversations = MeetingLibrary(folderName: "Conversations", parent: shared)

    /// The folder inside the SigmaFlow folder this library keeps: "Meetings".
    let folderName: String
    /// The library that finds the SigmaFlow folder, for one that follows it.
    private let parent: MeetingLibrary?

    /// The SigmaFlow folder, or nil while it cannot be found.
    var root: URL? { parent == nil ? ownRoot : parent?.root }
    private var ownRoot: URL?
    /// Where the folder was last seen, for the "can't find it" message.
    var lastKnownPath: String? { parent == nil ? ownLastKnownPath : parent?.lastKnownPath }
    private var ownLastKnownPath: String?
    /// Newest first.
    private(set) var meetings: [Meeting] = []
    /// Transcriptions running now, by meeting id.
    private(set) var progress: [String: Double] = [:]
    /// Why the last transcription of a meeting failed, by meeting id. In memory only: after
    /// a relaunch an audio file with no transcript beside it reads as unfinished.
    private(set) var failures: [String: String] = [:]
    /// The call app a meeting was recorded from, until its transcript (which keeps it) exists.
    private var apps: [String: String] = [:]
    /// Dropped recordings not yet filed as meetings, oldest first.
    private(set) var adding: [Adding] = []
    /// One line per dropped file that could not become a meeting. Cleared on the next drop.
    private(set) var addErrors: [String] = []

    var isFolderMissing: Bool { root == nil }
    /// This library's folder: SigmaFlow/Meetings or SigmaFlow/Conversations.
    var meetingsURL: URL? { root?.appendingPathComponent(folderName, isDirectory: true) }

    private var activationObserver: NSObjectProtocol?

    private init(folderName: String, parent: MeetingLibrary? = nil) {
        self.folderName = folderName
        self.parent = parent
    }

    // MARK: The folder

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("SigmaFlow", isDirectory: true)
    }

    /// Finds the folder, making it the first time the app runs. Called at launch.
    func locate() {
        let settings = Settings.shared
        if let bookmark = settings.sigmaFlowFolderBookmark {
            var isStale = false
            let resolved = try? URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &isStale)
            if let resolved, Self.isUsable(resolved) {
                adopt(resolved, refreshBookmark: isStale || resolved.path != settings.sigmaFlowFolderPath)
            } else {
                ownRoot = nil
                ownLastKnownPath = settings.sigmaFlowFolderPath
                Log.meetings.error("SigmaFlow folder not found (last seen at \(self.lastKnownPath ?? "?", privacy: .public))")
            }
        } else {
            // First run: make the folder where the user will look for it.
            let url = Self.defaultRoot
            try? FileManager.default.createDirectory(
                at: url.appendingPathComponent("Meetings", isDirectory: true), withIntermediateDirectories: true)
            adopt(url, refreshBookmark: true)
        }
        reload()
        Self.conversations.reload()

        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    MeetingLibrary.shared.reload()
                    MeetingLibrary.conversations.reload()
                }
            }
        }
    }

    /// Change or Find it: point the app at a folder the user picked.
    func choose(_ url: URL) {
        let old = root
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent("Meetings", isDirectory: true), withIntermediateDirectories: true)
        adopt(url, refreshBookmark: true)
        reload()
        Self.conversations.reload()
        // Dictations live here too: they follow, or are filed if they were waiting.
        RunLog.folderChanged(from: old)
        RunLog.settle()
    }

    /// The open panel behind Change and Find it.
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Choose your SigmaFlow folder"
        panel.directoryURL = root?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(url)
    }

    /// Upload meeting (docs/mockups/meeting-drop-discover.html, pick 05): the file picker,
    /// then exactly what a drop does.
    func pickRecordings() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = MeetingImport.fileTypes
        panel.prompt = "Upload"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        add(recordings: panel.urls)
    }

    func revealRoot() {
        guard let root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    private func adopt(_ url: URL, refreshBookmark: Bool) {
        ownRoot = url
        ownLastKnownPath = url.path
        guard refreshBookmark else { return }
        Settings.shared.sigmaFlowFolderBookmark = try? url.bookmarkData()
        Settings.shared.sigmaFlowFolderPath = url.path
    }

    /// A folder in the Trash still resolves; it is not where the user keeps meetings.
    private static func isUsable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return !url.path.contains("/.Trash/")
    }

    /// For `--readme-frames` only: reads a made-up SigmaFlow folder in place of the real one,
    /// for this run. The bookmark and the settings are not touched.
    func stageForPicture(root: URL) {
        ownRoot = root
        reload()
    }

    // MARK: Reading

    func reload() {
        if parent == nil, let root, !Self.isUsable(root) {
            ownRoot = nil
        }
        guard let meetingsURL else {
            meetings = []
            return
        }
        meetings = Self.scan(meetingsURL)
        // Forget failures and jobs whose folder has gone (deleted or renamed in Finder).
        let ids = Set(meetings.map(\.id))
        failures = failures.filter { ids.contains($0.key) }
    }

    /// Follows an automatic rename, so a transcript opened under the old name stays open.
    func meeting(_ id: String) -> Meeting? {
        meetings.first { $0.id == id } ?? namedFrom[id].flatMap { meeting($0) }
    }

    /// Meetings/<year>/<month>/<meeting>/. A folder counts as a meeting when it holds an
    /// audio file or a transcript; anything else the user keeps in there is left alone.
    private static func scan(_ meetingsURL: URL) -> [Meeting] {
        let fm = FileManager.default
        func folders(in url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }

        var found: [Meeting] = []
        for year in folders(in: meetingsURL) {
            for month in folders(in: year) {
                for folder in folders(in: month) {
                    if let meeting = read(folder) { found.append(meeting) }
                }
            }
        }
        return found.sorted { $0.date > $1.date }
    }

    static func read(_ folder: URL) -> Meeting? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        let name = folder.lastPathComponent
        // The file named after the folder wins; any other one of the right kind will do.
        func pick(_ ext: String) -> URL? {
            let matching = files.filter { $0.pathExtension.lowercased() == ext }
            return matching.first { $0.deletingPathExtension().lastPathComponent == name } ?? matching.first
        }
        let audio = pick("m4a")
        let transcript = pick("md")
        let photosFolder = folder.appendingPathComponent("Photos", isDirectory: true)
        let photos = ((try? FileManager.default.contentsOfDirectory(
            at: photosFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
        guard audio != nil || transcript != nil else { return nil }

        var parsed = MeetingMarkdown.Parsed()
        if let transcript, let text = try? String(contentsOf: transcript, encoding: .utf8) {
            parsed = MeetingMarkdown.parse(text)
        }
        let created = (audio ?? transcript).flatMap {
            try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate
        }
        let duration = parsed.duration ?? audio.map(audioSeconds) ?? 0
        return Meeting(
            folder: folder, audioURL: audio, transcriptURL: transcript,
            date: parsed.date ?? created ?? Date.distantPast, duration: duration, lines: parsed.lines,
            app: parsed.app, language: parsed.language, speakers: parsed.speakers, photos: photos)
    }

    nonisolated static func audioSeconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    // MARK: Writing

    /// Makes `Meetings/<year>/<month>/<name>/` for a finished recording and moves the audio
    /// in. A second meeting started in the same minute gets " 2".
    /// `photos`, `screens`: live notes' staging folders of camera photos and screenshots,
    /// named by seconds into the recording (`00-30.jpg`); they move into the meeting's
    /// Photos and Screens folders, renamed after it.
    func file(
        recording staged: URL, date: Date, duration: Double, app: String? = nil, title: String? = nil,
        photos: URL? = nil, screens: URL? = nil
    ) throws -> Meeting {
        guard let meetingsURL else { throw LibraryError.folderMissing }
        let month = meetingsURL
            .appendingPathComponent(MeetingNaming.yearFolder(for: date), isDirectory: true)
            .appendingPathComponent(MeetingNaming.monthFolder(for: date), isDirectory: true)
        let base = MeetingNaming.name(for: date, duration: duration, title: title)
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: month.appendingPathComponent(name).path) {
            name = "\(base) \(n)"
            n += 1
        }
        let folder = month.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("\(name).m4a")
        try FileManager.default.moveItem(at: staged, to: audio)
        if let photos { Self.movePictures(from: photos, into: folder, as: "Photos", stem: MeetingNaming.stem(for: date)) }
        if let screens { Self.movePictures(from: screens, into: folder, as: "Screens", stem: MeetingNaming.stem(for: date)) }
        let meeting = Meeting(folder: folder, audioURL: audio, transcriptURL: nil, date: date, duration: duration, lines: [], app: app)
        if let app { apps[meeting.id] = app }
        reload()
        return meeting
    }

    /// Live notes' pictures into `<meeting>/Photos/` or `<meeting>/Screens/`, named after
    /// the meeting. The staging folder goes once it is empty.
    static func movePictures(from staged: URL, into folder: URL, as kind: String, stem: String) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: staged, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
        guard !files.isEmpty else {
            try? fm.removeItem(at: staged)
            return
        }
        let target = folder.appendingPathComponent(kind, isDirectory: true)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for file in files {
            guard let seconds = MeetingNaming.parseClock(
                file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: ":")) else { continue }
            try? fm.moveItem(at: file, to: target.appendingPathComponent(MeetingNaming.photoName(stem: stem, at: seconds)))
        }
        if ((try? fm.contentsOfDirectory(atPath: staged.path)) ?? []).isEmpty { try? fm.removeItem(at: staged) }
    }

    /// The meeting's photos, each in the row that was being spoken when it was taken: the
    /// last row of words starting at or before it, the first for one taken before anyone spoke.
    /// Read from the Photos folder every time, so Transcribe again keeps them.
    static func placingPhotos(_ lines: [MeetingLine], in folder: URL) -> [MeetingLine] {
        guard !lines.isEmpty else { return lines }
        let photosFolder = folder.appendingPathComponent("Photos", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: photosFolder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".jpg") }
        var out = lines
        for index in out.indices { out[index].photos = [] }
        let timed = names.compactMap { name in MeetingNaming.photoTime(name).map { (name, $0) } }.sorted { $0.1 < $1.1 }
        // Photos go with the words: never on a screenshot's own row.
        let spoken = out.indices.filter { !out[$0].isScreenshot }
        guard let first = spoken.first else { return out }
        for (name, time) in timed {
            let row = spoken.last { out[$0].start <= time } ?? first
            out[row].photos.append("Photos/\(name)")
        }
        return out
    }

    /// The meeting's screenshots, each on a row of its own at its time (Gokul, 16 Oct 2026,
    /// 6B): the rows a transcript was given are kept, earlier screenshot rows are dropped
    /// and made again from the Screens folder, so Transcribe again keeps them.
    static func placingScreens(_ lines: [MeetingLine], in folder: URL) -> [MeetingLine] {
        let screensFolder = folder.appendingPathComponent("Screens", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: screensFolder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".jpg") }
        var out = lines.filter { !$0.isScreenshot }
        let timed = names.compactMap { name in MeetingNaming.photoTime(name).map { (name, $0) } }.sorted { $0.1 < $1.1 }
        for (name, time) in timed {
            let index = out.firstIndex { $0.start > time } ?? out.count
            out.insert(MeetingLine(start: time, speaker: nil, text: "", screens: ["Screens/\(name)"]), at: index)
        }
        return out
    }

    /// Renames the folder and both files, and the heading inside the transcript. Returns
    /// the meeting's id afterwards, which is its new folder path.
    @discardableResult
    func rename(_ meeting: Meeting, title: String) -> String {
        guard progress[meeting.id] == nil else { return meeting.id }
        let newName = MeetingNaming.name(for: meeting.date, duration: meeting.duration, title: title)
        guard newName != meeting.name else { return meeting.id }
        let fm = FileManager.default
        let target = meeting.folder.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
        guard !fm.fileExists(atPath: target.path) else { return meeting.id }
        do {
            try fm.moveItem(at: meeting.folder, to: target)
            if let audio = meeting.audioURL {
                try? fm.moveItem(
                    at: target.appendingPathComponent(audio.lastPathComponent),
                    to: target.appendingPathComponent("\(newName).m4a"))
            }
            if let transcript = meeting.transcriptURL {
                let moved = target.appendingPathComponent("\(newName).md")
                try? fm.moveItem(at: target.appendingPathComponent(transcript.lastPathComponent), to: moved)
                if let text = try? String(contentsOf: moved, encoding: .utf8) {
                    let renamed = Self.retitled(text, oldName: meeting.name, newName: newName)
                    try? renamed.write(to: moved, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            Log.meetings.error("rename failed: \(error.localizedDescription, privacy: .public)")
            reload()
            return meeting.id
        }
        reload()
        return target.path
    }

    /// The heading and the Audio line carry the name; nothing else in the file is touched.
    private static func retitled(_ text: String, oldName: String, newName: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices {
            if lines[index].hasPrefix("# ") {
                lines[index] = "# \(newName)"
            } else if lines[index].hasPrefix("Audio: ") {
                lines[index] = "Audio: \(newName).m4a"
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Speakers

    /// Gives every line of one speaker a new label, in the .md itself, so the file stays the
    /// record. An empty name goes back to a number. The Speakers line is left alone: two
    /// voices given one name still count as two (Gokul, 14 Oct 2026, 3B).
    func renameSpeaker(_ meeting: Meeting, from old: String, to typed: String) {
        guard progress[meeting.id] == nil, let url = meeting.transcriptURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var name = MeetingNaming.speakerLabel(typed)
        if name.isEmpty { name = Self.numberBack(for: old, in: meeting) }
        guard name != old else { return }
        // The cell break before the name: "] | " in a plain row, ">) | " after a photo.
        let renamed = text.components(separatedBy: "\n").map { line in
            line.hasPrefix("| [") ? line.replacingOccurrences(of: " | **\(old):** ", with: " | **\(name):** ") : line
        }
        do {
            try renamed.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.meetings.error("speaker rename failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        reload()
        if let updated = self.meeting(meeting.id) { learnVoices(updated) }
    }

    /// The number a speaker had before it was named: its place among the speakers, or the
    /// first number nobody else is using.
    private static func numberBack(for label: String, in meeting: Meeting) -> String {
        let labels = meeting.speakerLabels
        let taken = Set(labels.filter { $0 != label })
        let place = (labels.firstIndex(of: label) ?? labels.count) + 1
        if !taken.contains(MeetingNaming.speaker(place)) { return MeetingNaming.speaker(place) }
        var n = 1
        while taken.contains(MeetingNaming.speaker(n)) { n += 1 }
        return MeetingNaming.speaker(n)
    }

    /// One learning at a time, in the order the renames happened, so the last name wins.
    private var learning: Task<Void, Never>?

    /// Keeps the voices of a meeting's named speakers, quietly, so the next meeting knows them.
    private func learnVoices(_ meeting: Meeting) {
        guard let audio = meeting.audioURL else { return }
        let previous = learning
        let lines = meeting.lines
        let duration = meeting.duration
        let key = VoiceMemory.key(for: meeting.date)
        learning = Task.detached(priority: .utility) {
            await previous?.value
            await VoiceMemory.shared.learn(audio: audio, lines: lines, duration: duration, meeting: key)
        }
    }

    // MARK: Deleting

    // docs/mockups/delete-recordings.html, round 2 as picked on 16 Oct 2026. Whatever is
    // deleted goes to the Mac's Trash, so a mistake can still be found in Finder; the app
    // never says so (Gokul: people would look for a Trash inside SigmaFlow). Undo is offered
    // for a few seconds (6B) and moves it back.

    /// A folder or a picture moved to the Trash: where it was, and where it is now.
    struct Moved: Sendable {
        let from: URL
        let to: URL
    }

    /// The last meetings deleted, while Undo is still offered.
    struct Deleted: Identifiable {
        let id = UUID()
        /// "2 conversations": the footer reads "2 conversations deleted".
        let label: String
        let moved: [Moved]
        /// Their remembered voices, put back by Undo.
        let voices: [VoiceMemory.Print]
    }

    /// The last picture deleted from a transcript, while Undo is still offered.
    struct RemovedPicture: Identifiable {
        let id = UUID()
        let meetingID: String
        /// As the transcript names it: "Photos/[ 16 Oct ] Fri 10.32 am - 00-30.jpg".
        let path: String
        let moved: Moved
        /// The transcript's rows as they were, so the picture keeps its place as Undo.
        let lines: [MeetingLine]
        /// The .md before and after, so Undo puts it back only if nothing has changed it since.
        let transcript: URL?
        let before: String?
        let after: String?
    }

    private(set) var lastDeleted: Deleted?
    private(set) var lastPicture: RemovedPicture?

    /// "meeting", "conversation".
    var noun: String { String(folderName.lowercased().dropLast()) }

    /// Moves each meeting's whole folder (audio, transcript, photos, screenshots) to the
    /// Trash. One being transcribed is left alone.
    func delete(_ chosen: [Meeting]) {
        let fm = FileManager.default
        var moved: [Moved] = []
        var keys = Set<String>()
        for meeting in chosen where progress[meeting.id] == nil {
            if let audio = meeting.audioURL, MeetingPlayer.shared.playing == audio { MeetingPlayer.shared.stop() }
            var trashed: NSURL?
            do {
                try fm.trashItem(at: meeting.folder, resultingItemURL: &trashed)
                if let trashed { moved.append(Moved(from: meeting.folder, to: trashed as URL)) }
                keys.insert(VoiceMemory.key(for: meeting.date))
            } catch {
                Log.meetings.error("delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        reload()
        guard !moved.isEmpty else { return }
        let label = "\(moved.count) \(noun)\(moved.count == 1 ? "" : "s")"
        Task { @MainActor in
            let voices = await VoiceMemory.shared.forget(meetings: keys)
            let deleted = Deleted(label: label, moved: moved, voices: voices)
            lastDeleted = deleted
            try? await Task.sleep(for: .seconds(DS.Motion.undoHold))
            if lastDeleted?.id == deleted.id { lastDeleted = nil }
        }
    }

    func undoDelete() {
        guard let deleted = lastDeleted else { return }
        lastDeleted = nil
        for item in deleted.moved { Self.moveBack(item) }
        reload()
        let voices = deleted.voices
        Task { await VoiceMemory.shared.restore(voices) }
    }

    /// Moves one photo or screenshot to the Trash and takes it out of the transcript: a
    /// photo from its row's time cell, a screenshot's row whole.
    func deletePicture(_ path: String, of meeting: Meeting) {
        guard progress[meeting.id] == nil else { return }
        let file = meeting.folder.appendingPathComponent(path)
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
        } catch {
            Log.meetings.error("picture delete failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let trashed else { return }
        var before: String?
        var after: String?
        if let url = meeting.transcriptURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            let edited = Self.removing(path, from: text)
            do {
                try edited.write(to: url, atomically: true, encoding: .utf8)
                before = text
                after = edited
            } catch {
                Log.meetings.error("transcript write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let removed = RemovedPicture(
            meetingID: meeting.id, path: path, moved: Moved(from: file, to: trashed as URL),
            lines: meeting.lines, transcript: meeting.transcriptURL, before: before, after: after)
        lastPicture = removed
        reload()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(DS.Motion.undoHold))
            if lastPicture?.id == removed.id { lastPicture = nil }
        }
    }

    func undoPicture() {
        guard let removed = lastPicture else { return }
        lastPicture = nil
        Self.moveBack(removed.moved)
        if let url = removed.transcript, let before = removed.before,
           (try? String(contentsOf: url, encoding: .utf8)) == removed.after {
            try? before.write(to: url, atomically: true, encoding: .utf8)
        }
        reload()
    }

    /// From the Trash to where it was, unless something has taken its place since.
    private static func moveBack(_ item: Moved) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: item.from.path) else { return }
        do {
            try fm.createDirectory(at: item.from.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: item.to, to: item.from)
        } catch {
            Log.meetings.error("undo failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The transcript without one picture. Every other byte, hand edits included, stays.
    static func removing(_ path: String, from text: String) -> String {
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            // The mark with whatever image text it has: `![…](<path>)`.
            guard line.hasPrefix("| ["), let range = MeetingMarkdown.imageRange(of: path, in: line) else {
                out.append(line)
                continue
            }
            // A screenshot's own row goes when it was the only picture on it.
            if let row = MeetingMarkdown.parse(line).lines.first, row.isScreenshot, row.screens == [path] { continue }
            let mark = String(line[range])
            out.append(line
                .replacingOccurrences(of: " " + mark, with: "")
                .replacingOccurrences(of: mark + " ", with: "")
                .replacingOccurrences(of: mark, with: ""))
        }
        return out.joined(separator: "\n")
    }

    // MARK: Dropped recordings

    /// A recording dropped onto the page, on its way to being a meeting.
    struct Adding: Identifiable, Sendable {
        let id = UUID()
        let source: URL
        /// When it was dropped: that is the meeting's date (Gokul, 15 Oct 2026, 2B).
        let date: Date
        /// The file's own name, which the meeting keeps as its title (3A).
        let title: String
        var duration: Double?
        var fraction: Double = 0

        /// The meeting's name as it will be filed, once the length is known.
        var name: String {
            guard let duration else { return "\(MeetingNaming.stem(for: date)) - \(title)" }
            return MeetingNaming.name(for: date, duration: duration, title: title)
        }
    }

    /// The share of a dropped recording's progress line that is the copy; transcription
    /// carries on from there.
    private static let copyShare = 0.05
    private var isAdding = false

    /// Drop: each file is copied into the recorder's format, filed under the moment it was
    /// dropped and the file's name, and transcribed, one after another. The original is
    /// only read.
    func add(recordings urls: [URL]) {
        addErrors = []
        guard !isFolderMissing else {
            addErrors = [LibraryError.folderMissing.localizedDescription]
            return
        }
        let now = Date()
        for url in urls {
            let title = MeetingNaming.sanitized(url.deletingPathExtension().lastPathComponent)
            adding.append(Adding(source: url, date: now, title: title))
        }
        startNextAdd()
    }

    private func startNextAdd() {
        guard !isAdding, let item = adding.first else { return }
        isAdding = true
        let id = item.id
        let staged = MeetingSession.stagingFolder.appendingPathComponent("\(UUID().uuidString).import.m4a")
        let library = self

        Task.detached(priority: .userInitiated) {
            let result: Result<Double, Error>
            do {
                let length = try await MeetingImport.length(of: item.source)
                await MainActor.run { library.update(id) { $0.duration = length } }
                let seconds = try await MeetingImport.convert(item.source, into: staged) { fraction in
                    Task { @MainActor in
                        library.update(id) { $0.fraction = fraction * MeetingLibrary.copyShare }
                    }
                }
                result = .success(seconds)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                library.finishAdd(item, staged: staged, result: result)
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Adding) -> Void) {
        guard let index = adding.firstIndex(where: { $0.id == id }) else { return }
        change(&adding[index])
    }

    private func finishAdd(_ item: Adding, staged: URL, result: Result<Double, Error>) {
        adding.removeAll { $0.id == item.id }
        isAdding = false
        let fileName = item.source.lastPathComponent
        switch result {
        case .failure(let error):
            try? FileManager.default.removeItem(at: staged)
            addErrors.append("Can't open \(fileName).")
            Log.meetings.error("couldn't add a recording: \(error.localizedDescription, privacy: .public)")
        case .success(let seconds) where seconds < 2:
            try? FileManager.default.removeItem(at: staged)
            addErrors.append("\(fileName) is too short.")
        case .success(let seconds):
            do {
                let meeting = try file(recording: staged, date: item.date, duration: seconds, title: item.title)
                transcribe(meeting)
                progress[meeting.id] = Self.copyShare
                Log.meetings.info("added a dropped recording, \(Int(seconds)) s")
            } catch {
                try? FileManager.default.removeItem(at: staged)
                addErrors.append("Couldn't save \(fileName).")
                Log.meetings.error("filing a dropped recording failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        startNextAdd()
    }

    // MARK: Transcribing

    /// Meetings waiting their turn. One transcription runs at a time: each one already uses
    /// the whole Neural Engine, and two side by side would only both be slower.
    private var queue: [(meeting: Meeting, language: MeetingLanguage?)] = []
    private var isWorking = false

    /// Transcribes a meeting's audio and writes the .md beside it. Try again calls it again;
    /// Transcribe again calls it with a language, and the new .md replaces the old one, hand
    /// edits included (Gokul, 13 Oct 2026, 4B: no Undo).
    func transcribe(_ meeting: Meeting, language: MeetingLanguage? = nil) {
        guard meeting.audioURL != nil, progress[meeting.id] == nil else { return }
        progress[meeting.id] = 0
        failures[meeting.id] = nil
        queue.append((meeting, language))
        startNext()
    }

    private func startNext() {
        guard !isWorking, !queue.isEmpty else { return }
        let (meeting, language) = queue.removeFirst()
        guard let audio = meeting.audioURL else { return startNext() }
        let id = meeting.id
        isWorking = true
        let library = self

        Task.detached(priority: .userInitiated) {
            do {
                let transcript = try await MeetingProcessor.transcribe(audio: audio, language: language) { fraction in
                    Task { @MainActor in
                        guard let shown = library.progress[id] else { return }
                        // Never backwards: a dropped recording's line starts past its copy.
                        library.progress[id] = max(shown, fraction)
                    }
                }
                await MainActor.run {
                    library.finish(meeting, transcript: transcript)
                }
            } catch {
                await MainActor.run {
                    library.progress[id] = nil
                    library.failures[id] = error.localizedDescription
                    Log.meetings.error("transcription failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            await MainActor.run {
                library.isWorking = false
                library.startNext()
            }
        }
    }

    private func finish(_ meeting: Meeting, transcript: MeetingProcessor.Transcript) {
        progress[meeting.id] = nil
        let lines = Self.placingScreens(Self.placingPhotos(transcript.lines, in: meeting.folder), in: meeting.folder)
        let markdown = MeetingMarkdown.render(
            name: meeting.name, date: meeting.date, duration: meeting.duration, lines: lines,
            audioFileName: meeting.audioURL?.lastPathComponent ?? "\(meeting.name).m4a",
            app: meeting.app ?? apps[meeting.id], language: transcript.language, speakers: transcript.speakers)
        let url = meeting.folder.appendingPathComponent("\(meeting.name).md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            apps[meeting.id] = nil
            Log.meetings.info("meeting ready: \(meeting.name, privacy: .public), \(lines.count) rows")
        } catch {
            failures[meeting.id] = "Couldn't save the transcript."
            Log.meetings.error("transcript write failed: \(error.localizedDescription, privacy: .public)")
            reload()
            return
        }
        reload()
        if meeting.hasDateName {
            nameAutomatically(meeting.id, texts: lines.map(\.text), language: transcript.language)
        }
        // Lines and pictures for search, quietly, once the transcript is there.
        if let written = self.meeting(meeting.id) { PictureReader.shared.enqueue(written, in: self) }
    }

    /// Ids a meeting had before it was named automatically, to the id it has now, so a
    /// transcript open at that moment stays open.
    private var namedFrom: [String: String] = [:]

    /// Gives a meeting a title from its transcript (Gokul, 16 Oct 2026; Tamil too since
    /// 20 Oct, through Gemma). Only a meeting still under its date name when the title comes
    /// back is renamed: one renamed by hand meanwhile, moved, or being transcribed again is
    /// left alone.
    private func nameAutomatically(_ id: String, texts: [String], language: MeetingLanguage) {
        Task {
            let title: String?
            if language == .tamil {
                // Gemma takes 4 GB and the GPU: never while something records or listens.
                await PictureReader.shared.waitWhileBusy()
                title = await MeetingTitler.title(for: texts, language: language)
                await PictureReader.shared.releaseModelsIfIdle()
            } else {
                title = await MeetingTitler.title(for: texts)
            }
            guard let title else { return }
            guard progress[id] == nil, let current = meeting(id), current.hasDateName, current.hasTranscript else { return }
            let renamed = rename(current, title: title)
            if renamed != id {
                namedFrom[id] = renamed
                Log.meetings.info("named automatically: \(title, privacy: .public)")
            }
        }
    }

    enum LibraryError: LocalizedError {
        case folderMissing
        var errorDescription: String? {
            "Can't find your meetings. Show SigmaFlow where they are in Settings, Your data."
        }
    }
}
