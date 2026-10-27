import Foundation

/// Reads what search needs from each recording, quietly, after its transcript is written:
/// a vector for every spoken line, and for every photo and screenshot the words on it (the
/// Mac's own reading), what is in it (Gemma 4 E2B), and how it looks (EmbeddingGemma 2).
/// Recordings from before this existed are read too, one after another, oldest work last.
///
/// Nothing shows while it works (Gokul, 19 Oct 2026, 04 A): a search simply finds more a few
/// minutes after Stop. It steps aside while a meeting or notes record, while a transcript is
/// being written, and while dictation runs, so it never costs those a moment.
///
/// What it reads is kept in `SearchIndex`; the descriptions also go into each .md as image
/// text, where Claude and any Markdown app see them.
@MainActor
final class PictureReader {
    static let shared = PictureReader()

    /// Set by `DictationController` while its microphone is open or it is finishing.
    var isDictating = false

    private struct Job: Equatable {
        let id: String
        let library: String
    }

    private var queue: [Job] = []
    private var running: Task<Void, Never>?

    /// After launch: every recording in both libraries whose lines or pictures are not all in
    /// the index yet.
    func catchUp() {
        for library in [MeetingLibrary.shared, MeetingLibrary.conversations] {
            for meeting in library.meetings where meeting.hasTranscript {
                enqueue(meeting, in: library)
            }
        }
    }

    /// One recording, after its transcript is written (or written again).
    func enqueue(_ meeting: Meeting, in library: MeetingLibrary) {
        let job = Job(id: meeting.id, library: library.folderName)
        guard !queue.contains(job) else { return }
        queue.append(job)
        guard running == nil else { return }
        running = Task { @MainActor in
            while !queue.isEmpty {
                let job = queue.removeFirst()
                let library = job.library == MeetingLibrary.conversations.folderName ? MeetingLibrary.conversations : .shared
                guard let meeting = library.meeting(job.id), meeting.hasTranscript else { continue }
                await read(meeting, folderName: library.folderName) { [weak self] in await self?.waitWhileBusy() }
                library.reload()
            }
            // The 4 GB model and the picture encoder only while there are pictures to read.
            await PictureDescriber.shared.release()
            await SearchEncoder.shared.releasePictures()
            running = nil
        }
    }

    private var isBusy: Bool {
        isDictating || MeetingSession.shared.isRecording || NotesSession.shared.isOpen
            || !MeetingLibrary.shared.progress.isEmpty || !MeetingLibrary.conversations.progress.isEmpty
    }

    /// Also awaited by a Tamil recording's title, which runs on the same model.
    func waitWhileBusy() async {
        while isBusy { try? await Task.sleep(for: .seconds(2)) }
    }

    /// After a Tamil title: lets Gemma go, unless pictures are still being read (that run
    /// lets it go when it ends).
    func releaseModelsIfIdle() async {
        guard running == nil else { return }
        await PictureDescriber.shared.release()
    }

    // MARK: Reading one recording

    /// Brings one recording's index up to date and writes its descriptions into the .md.
    /// `pause` is awaited before each piece of heavy work. Also run by `--search-check`.
    func read(_ meeting: Meeting, folderName: String, pause: () async -> Void) async {
        let file = SearchIndex.file(for: meeting, in: folderName)
        var index = await SearchIndex.shared.index(at: file) ?? RecordingIndex()
        var changed = false

        // Lines: only the words not already there, and nothing left for words since edited away.
        let texts = Set(meeting.lines.filter { !$0.isScreenshot && !$0.text.isEmpty }.map(\.text))
        let stale = index.lines.keys.filter { !texts.contains($0) }
        for text in stale { index.lines[text] = nil }
        changed = changed || !stale.isEmpty
        let missing = texts.filter { index.lines[$0] == nil }.sorted()
        if !missing.isEmpty {
            await pause()
            do {
                let vectors = try await SearchEncoder.shared.documents(missing)
                for (text, vector) in zip(missing, vectors) { index.lines[text] = SearchIndex.data(vector) }
                changed = true
            } catch {
                Log.search.error("lines not indexed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        // Pictures: each one new or changed since it was read.
        var described: [String: String] = [:]
        let pictures = meeting.lines.flatMap { line in (line.photos + line.screens).map { (path: $0, line: line) } }
        let present = Set(pictures.map(\.path))
        for path in index.pictures.keys where !present.contains(path) {
            index.pictures[path] = nil
            changed = true
        }
        for (path, line) in pictures {
            let url = meeting.folder.appendingPathComponent(path)
            guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            let typed = line.descriptions[path]
            if var known = index.pictures[path], known.bytes == bytes {
                // Image text changed by hand in the .md: that is what is in it now.
                if let typed, typed != MeetingMarkdown.altText(known.seen) {
                    known.seen = typed
                    known.words = try? await SearchEncoder.shared.documents([Self.words(known)]).first.map(SearchIndex.data)
                    index.pictures[path] = known
                    changed = true
                    await SearchIndex.shared.save(index, to: file)
                }
                if typed == nil, !known.seen.isEmpty { described[path] = known.seen }
                continue
            }
            await pause()
            let started = Date()
            do {
                let read = await PictureText.read(url)
                let seen: String
                if let typed { seen = typed } else { seen = try await PictureDescriber.shared.describe(url) }
                var picture = RecordingIndex.Picture(bytes: bytes, read: read, seen: seen)
                picture.words = try await SearchEncoder.shared.documents([Self.words(picture)]).first.map(SearchIndex.data)
                picture.look = SearchIndex.data(try await SearchEncoder.shared.picture(url))
                index.pictures[path] = picture
                if typed == nil { described[path] = seen }
                // Saved after every picture: a quit half way through loses one picture, not all.
                await SearchIndex.shared.save(index, to: file)
                changed = false
                Log.search.info("read \(path, privacy: .public) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            } catch {
                Log.search.error("picture not read: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
        if changed { await SearchIndex.shared.save(index, to: file) }
        if !described.isEmpty { Self.write(described, into: meeting) }
    }

    /// What a picture's words vector is made of: what is in it, then what is written on it.
    private static func words(_ picture: RecordingIndex.Picture) -> String {
        [picture.seen, picture.read].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The descriptions into the .md as image text, where a picture has none yet. Left alone
    /// while the recording is being transcribed again, which rewrites the file anyway.
    private static func write(_ descriptions: [String: String], into meeting: Meeting) {
        guard let url = meeting.transcriptURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard MeetingLibrary.shared.progress[meeting.id] == nil, MeetingLibrary.conversations.progress[meeting.id] == nil else { return }
        let described = MeetingMarkdown.describing(text, with: descriptions)
        guard described != text else { return }
        do {
            try described.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.search.error("descriptions not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
