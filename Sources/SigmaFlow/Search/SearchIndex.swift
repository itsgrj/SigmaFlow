import Accelerate
import Foundation

/// What search knows about each recording beyond its .md: a vector for every spoken line, and
/// for every photo and screenshot the words on it, what Gemma saw in it, and two vectors, one
/// for those words and one for how the picture looks (docs/mockups/picture-search.html).
///
/// A cache, never the record: one JSON file per recording in
/// `Application Support/SigmaFlow/Search/<Meetings|Conversations>/`, named after the recording's
/// date and length, which a rename keeps. Deleting the folder costs only the time to read
/// everything again. The descriptions are also written into the .md (`MeetingMarkdown`), which
/// is where Claude reads them.
struct RecordingIndex: Codable, Sendable {
    var version = 1
    /// A line's words → its vector, as fp16 bytes. Keyed by the words, so a hand edit or a
    /// Transcribe again only costs the lines that changed.
    var lines: [String: Data] = [:]
    /// By the picture's path in the .md: "Photos/[ 16 Oct ] Fri 10.32 am - 00-30.jpg".
    var pictures: [String: Picture] = [:]

    struct Picture: Codable, Sendable {
        /// The file's size when it was read: a different size is a different picture.
        var bytes: Int
        /// The words on it, read by the Mac.
        var read: String
        /// What Gemma saw, or what the user wrote over it in the .md.
        var seen: String
        /// `seen` and `read` together, as a vector.
        var words: Data?
        /// How it looks, as a vector.
        var look: Data?
    }
}

/// One place a search landed: a spoken line, a photo, or a screenshot.
struct SearchMoment: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable { case line, photo, screenshot }

    let kind: Kind
    /// Seconds into the recording: the line's start, or when the picture was taken.
    let start: Double
    /// The transcript row to open at: the line, the line the photo was taken during, or the
    /// screenshot's own row.
    let row: Int
    /// The picture's path in the .md, for a photo or a screenshot.
    let path: String?
    let speaker: String?
    /// A line's words.
    let text: String
    /// A picture's words, as read by the Mac and as Gemma saw it.
    let read: String
    let seen: String
    let score: Float
    /// For a picture, the words' and the look's own scores before they were combined.
    var wordsScore: Float = 0
    var lookScore: Float = 0
    /// The typed words are in it, as typed.
    let isExact: Bool

    var id: String { "\(row)|\(path ?? "")" }
}

/// One recording's share of a search.
struct SearchHit: Sendable {
    /// Its best moments, at most `shown`, in the order they happened.
    var moments: [SearchMoment]
    /// How many moments matched in all.
    var total: Int
    /// Every matching moment, in the order they happened, for "N more".
    var all: [SearchMoment]
}

actor SearchIndex {
    static let shared = SearchIndex()

    /// `Application Support/SigmaFlow/Search`; the `--search-check` mode uses its own.
    nonisolated(unsafe) static var root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SigmaFlow/Search", isDirectory: true)

    // Tuned on the 18 and 19 Oct test data (`--search-check --raw`, 11 recordings, 22
    // searches): matching lines and descriptions score 0.70 and up, unrelated ones 0.60 to
    // 0.69, short stock lines ("Okay, where were we?") up to 0.77 against anything. A picture's
    // look scores about 0.06 lower than words about the same thing, so it is lifted before
    // comparing: without the lift the red t-shirt only its look finds (0.658) is lost. These
    // found 23 of 25 targets with no wrong recording shown; lower floors and tighter margins
    // all let stock lines in. Missed: a long Tamil phrase spelled unlike Gemma's copy (0.69);
    // one Tamil word still finds it by its letters.
    static let floor: Float = 0.70
    /// Only moments this close to the best one in the whole search are kept.
    static let margin: Float = 0.08
    static let lookLift: Float = 0.06
    /// Moments shown under a recording before "N more".
    static let shown = 3

    static func file(for meeting: Meeting, in folderName: String) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("\(MeetingNaming.name(for: meeting.date, duration: meeting.duration)).json")
    }

    // MARK: Files

    private struct Loaded {
        var modified: Date
        var index: RecordingIndex
        var lines: [String: [Float]]
        var words: [String: [Float]]
        var looks: [String: [Float]]
    }

    private var loaded: [URL: Loaded] = [:]

    func index(at url: URL) -> RecordingIndex? {
        load(url)?.index
    }

    private func load(_ url: URL) -> Loaded? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let cached = loaded[url], cached.modified == modified { return cached }
        guard let data = try? Data(contentsOf: url), let index = try? JSONDecoder().decode(RecordingIndex.self, from: data) else {
            loaded[url] = nil
            return nil
        }
        let entry = Loaded(
            modified: modified, index: index,
            lines: index.lines.mapValues(Self.floats),
            words: index.pictures.compactMapValues { $0.words.map(Self.floats) },
            looks: index.pictures.compactMapValues { $0.look.map(Self.floats) })
        loaded[url] = entry
        return entry
    }

    func save(_ index: RecordingIndex, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(index).write(to: url, options: .atomic)
        } catch {
            Log.search.error("index write failed: \(error.localizedDescription, privacy: .public)")
        }
        loaded[url] = nil
    }

    static func data(_ vector: [Float]) -> Data {
        vector.map { Float16($0) }.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in raw.bindMemory(to: Float16.self).map { Float($0) } }
    }

    // MARK: Searching

    /// Every recording's moments for `query`, by meeting id. `vector` is the query's vector, or
    /// nil while the model is not ready, when only exact words count. A recording that matches
    /// by its name alone comes back with no moments.
    /// `raw` keeps every moment, best first: `--search-check --raw`, for tuning the cutoff.
    func search(_ query: String, vector: [Float]?, meetings: [Meeting], folderName: String, raw: Bool = false) -> [String: SearchHit] {
        var candidates: [(meeting: Meeting, moments: [SearchMoment])] = []
        var best: Float = 0
        for meeting in meetings {
            let entry = load(Self.file(for: meeting, in: folderName))
            let moments = Self.moments(for: query, vector: vector, in: meeting, entry: entry)
            for moment in moments where !moment.isExact { best = max(best, moment.score) }
            candidates.append((meeting, moments))
        }
        let cutoff = raw ? -1 : max(Self.floor, best - Self.margin)
        var out: [String: SearchHit] = [:]
        for (meeting, moments) in candidates {
            let kept = moments.filter { $0.isExact || $0.score >= cutoff }
            guard !kept.isEmpty || meeting.name.localizedStandardContains(query) else { continue }
            // Where the typed words themselves are, only those show under the row; what matched
            // by meaning waits behind "N more" (a code like INV-20431 found a circuit board too).
            let pool = kept.contains(where: \.isExact) ? kept.filter(\.isExact) : kept
            let ranked = pool.sorted { $0.score > $1.score }
            out[meeting.id] = SearchHit(
                moments: ranked.prefix(Self.shown).sorted { $0.start < $1.start },
                total: kept.count,
                all: kept.sorted { $0.start < $1.start })
        }
        return out
    }

    private static func moments(for query: String, vector: [Float]?, in meeting: Meeting, entry: Loaded?) -> [SearchMoment] {
        var out: [SearchMoment] = []
        for (row, line) in meeting.lines.enumerated() {
            if !line.isScreenshot {
                let exact = line.text.localizedStandardContains(query)
                let score = vector.flatMap { v in entry?.lines[line.text].map { dot(v, $0) } } ?? 0
                if exact || score > 0 {
                    out.append(SearchMoment(
                        kind: .line, start: line.start, row: row, path: nil, speaker: line.speaker, text: line.text,
                        read: "", seen: "", score: score, isExact: exact))
                }
            }
            let pictures = line.photos.map { ($0, SearchMoment.Kind.photo) } + line.screens.map { ($0, .screenshot) }
            for (path, kind) in pictures {
                let picture = entry?.index.pictures[path]
                let seen = picture?.seen ?? line.descriptions[path] ?? ""
                let read = picture?.read ?? ""
                let exact = seen.localizedStandardContains(query) || read.localizedStandardContains(query)
                var wordsScore: Float = 0
                var lookScore: Float = 0
                if let vector {
                    if let words = entry?.words[path] { wordsScore = dot(vector, words) }
                    if let look = entry?.looks[path] { lookScore = dot(vector, look) }
                }
                let score = max(wordsScore, lookScore > 0 ? lookScore + lookLift : 0)
                guard exact || score > 0 else { continue }
                let time = MeetingNaming.photoTime((path as NSString).lastPathComponent) ?? line.start
                out.append(SearchMoment(
                    kind: kind, start: time, row: row, path: path, speaker: nil, text: "",
                    read: read, seen: seen, score: score, wordsScore: wordsScore, lookScore: lookScore, isExact: exact))
            }
        }
        return out
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
}
