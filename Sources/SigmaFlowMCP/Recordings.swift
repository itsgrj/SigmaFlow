import CoreFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Meetings and conversations, for Claude (Gokul, 16 Oct 2026: "maximum context").
//
// Read straight from the SigmaFlow folder the app keeps them in: each one a folder holding
// its audio, its transcript (.md), and for live notes a Photos and a Screens folder. Nothing
// is cached; every call reads the folder as it is now, so a rename or a new recording in the
// app is seen at once. Like the rest of this binary, it depends on nothing in the app: the
// .md format is read here on its own terms (see the app's MeetingMarkdown).

// MARK: - The folder

@MainActor
enum Recordings {
    /// The SigmaFlow folder: where the app says it is, or ~/SigmaFlow.
    nonisolated static var root: URL {
        if let path = CFPreferencesCopyAppValue("sigmaFlowFolderPath" as CFString, "com.grj.sigmaflow" as CFString) as? String,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("SigmaFlow", isDirectory: true)
    }

    struct Recording {
        /// "meeting" or "conversation".
        let kind: String
        let folder: URL
        var name: String { folder.lastPathComponent }
        /// Its address for the other tools: "Conversations/2026/10 October/[ 16 Oct ] Fri 10.46 am - 3 min".
        var id: String {
            let base = Recordings.root.path
            return folder.path.hasPrefix(base + "/") ? String(folder.path.dropFirst(base.count + 1)) : folder.path
        }
        let transcript: URL?
        let audio: URL?
        let photos: [String]
        let screens: [String]
        /// From the .md's Date line; the folder's creation date when there is no transcript yet.
        let date: Date
        let facts: [String: String]
        let rows: [Row]
    }

    struct Row {
        /// Seconds into the recording.
        let start: Double
        let stamp: String
        let speaker: String?
        let text: String
        /// Pictures in this row, as paths inside the recording's folder.
        let pictures: [String]
        /// What is in each picture, by path: its image text in the .md, written by the app's
        /// picture reader (Gemma 4 on the user's Mac) or by hand. Missing until it has run.
        let descriptions: [String: String]
    }

    static func all(kind: String = "all") -> [Recording] {
        var out: [Recording] = []
        if kind != "conversations" { out += scan(root.appendingPathComponent("Meetings"), kind: "meeting") }
        if kind != "meetings" { out += scan(root.appendingPathComponent("Conversations"), kind: "conversation") }
        return out.sorted { $0.date > $1.date }
    }

    /// Meetings/<year>/<month>/<recording>/, the app's layout.
    private static func scan(_ base: URL, kind: String) -> [Recording] {
        func folders(_ url: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return folders(base).flatMap(folders).flatMap(folders).compactMap { read($0, kind: kind) }
    }

    private static func read(_ folder: URL, kind: String) -> Recording? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        func pick(_ ext: String) -> URL? {
            let matching = files.filter { $0.pathExtension.lowercased() == ext }
            return matching.first { $0.deletingPathExtension().lastPathComponent == folder.lastPathComponent } ?? matching.first
        }
        let audio = pick("m4a"), transcript = pick("md")
        guard audio != nil || transcript != nil else { return nil }
        func pictures(_ sub: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(sub).path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".jpg") }.sorted().map { "\(sub)/\($0)" }
        }
        var facts: [String: String] = [:]
        var rows: [Row] = []
        if let transcript, let text = try? String(contentsOf: transcript, encoding: .utf8) {
            (facts, rows) = parse(text)
        }
        let created = (audio ?? transcript).flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }
        let date = facts["Date"].flatMap { longDate.date(from: $0) } ?? created ?? .distantPast
        return Recording(
            kind: kind, folder: folder, transcript: transcript, audio: audio,
            photos: pictures("Photos"), screens: pictures("Screens"), date: date, facts: facts, rows: rows)
    }

    /// The app's "Tuesday 13 October 2026, 2.30 pm".
    static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM yyyy, h.mm a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    /// The labelled lines at the top, and the rows: `| [00:30] ![](<Photos/…>) | **Speaker 1:** … |`.
    static func parse(_ text: String) -> ([String: String], [Row]) {
        var facts: [String: String] = [:]
        var rows: [Row] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix("|"), let colon = line.range(of: ": ") {
                let key = String(line[..<colon.lowerBound])
                if ["Date", "Length", "From", "Speakers", "Language", "Audio"].contains(key) {
                    facts[key] = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard line.hasPrefix("| ["), let bracket = line.range(of: "]"),
                  let close = line.range(of: " |", range: bracket.upperBound..<line.endIndex) else { continue }
            let stamp = String(line[line.index(line.startIndex, offsetBy: 3)..<bracket.lowerBound])
            let parts = stamp.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 || parts.count == 3 else { continue }
            let start = parts.reduce(0) { $0 * 60 + $1 }
            var pictures = images(in: String(line[bracket.upperBound..<close.lowerBound]))
            var cell = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            if cell.hasSuffix("|"), !cell.hasSuffix("\\|") { cell.removeLast() }
            cell = cell.trimmingCharacters(in: .whitespaces)
            var speaker: String?
            if cell.hasPrefix("!["), !images(in: cell).isEmpty {
                // A screenshot's own row.
                pictures += images(in: cell)
                cell = ""
            } else if cell.hasPrefix("**"), let end = cell.range(of: ":** ") {
                speaker = String(cell[cell.index(cell.startIndex, offsetBy: 2)..<end.lowerBound])
                cell = String(cell[end.upperBound...])
            }
            var descriptions: [String: String] = [:]
            for picture in pictures where !picture.alt.isEmpty { descriptions[picture.path] = picture.alt }
            rows.append(Row(
                start: start, stamp: stamp, speaker: speaker,
                text: cell.replacingOccurrences(of: "\\|", with: "|"), pictures: pictures.map(\.path),
                descriptions: descriptions))
        }
        return (facts, rows)
    }

    /// Every `![what is in it](<path>)` in a cell; the image text is empty until read.
    private static func images(in text: String) -> [(path: String, alt: String)] {
        var out: [(String, String)] = []
        var rest = Substring(text)
        while let open = rest.range(of: "!["),
              let middle = rest.range(of: "](<", range: open.upperBound..<rest.endIndex),
              let end = rest.range(of: ">)", range: middle.upperBound..<rest.endIndex) {
            out.append((String(rest[middle.upperBound..<end.lowerBound]), String(rest[open.upperBound..<middle.lowerBound])))
            rest = rest[end.upperBound...]
        }
        return out
    }

    /// A recording by its id, its folder's name, or words in its name ("10.46", "webinar").
    static func find(_ key: String) -> Recording? {
        let key = key.trimmingCharacters(in: .whitespaces)
        let all = all()
        return all.first { $0.id == key } ?? all.first { $0.name == key }
            ?? all.first { $0.id.localizedCaseInsensitiveContains(key) }
    }

    /// "12:30", "1:02:30" or plain seconds.
    static func seconds(_ text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// The time a picture was taken, from its name: "[ 16 Oct ] Fri 10.32 am - 00-30.jpg".
    static func pictureTime(_ path: String) -> Double? {
        let name = (path as NSString).lastPathComponent
        guard let dash = name.range(of: " - ", options: .backwards) else { return nil }
        return seconds(name[dash.upperBound...].replacingOccurrences(of: ".jpg", with: "").replacingOccurrences(of: "-", with: ":"))
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - The tools

@MainActor let recordingTools: [[String: Any]] = [
    [
        "name": "list_recordings",
        "description": """
            List the user's SigmaFlow meetings and conversations, newest first. Meetings are \
            recordings and calls (and audio files the user added); conversations are live notes \
            taken in a room, often with camera photos and screenshots of the screen. Each entry \
            gives its id (pass it to read_recording and get_pictures), date, length, language, \
            number of speakers, how many photos and screenshots it has, and its opening words. \
            Start here when the user mentions a meeting or conversation.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["all", "meetings", "conversations"], "description": "Which to list. Default all."],
                "since": ["type": "string", "description": "ISO 8601 date. Only recordings on or after it."],
                "until": ["type": "string", "description": "ISO 8601 date. Only recordings before the end of that day."],
                "query": ["type": "string", "description": "Only recordings whose name or transcript contains these words."],
                "limit": ["type": "integer", "description": "Maximum to list. Default 50."],
            ],
        ],
    ],
    [
        "name": "search_recordings",
        "description": """
            Search every meeting and conversation transcript for words. Returns each matching \
            line with its time, speaker and the recording it is in, plus the line before and \
            after for context, and any picture taken at that moment. Use it to find when \
            something was discussed across all recordings.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Words to look for. Case-insensitive."],
                "kind": ["type": "string", "enum": ["all", "meetings", "conversations"], "description": "Where to look. Default all."],
                "limit": ["type": "integer", "description": "Maximum matching lines. Default 40."],
            ],
            "required": ["query"],
        ],
    ],
    [
        "name": "read_recording",
        "description": """
            Read one meeting or conversation in full: its facts (date, length, speakers, \
            language) and every line of its transcript with its time and speaker, with the \
            photos and screenshots placed at the moment they were taken, then an index of all \
            its pictures. Speakers are Speaker 1, 2, 3 unless the user named them. For long \
            recordings, read a stretch with from and to. Then call get_pictures to see the \
            photos or screenshots themselves.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The id from list_recordings, or the recording's name, or words in it."],
                "from": ["type": "string", "description": "Start time, as 12:30 or 1:02:30. Default the start."],
                "to": ["type": "string", "description": "End time. Default the end."],
            ],
            "required": ["id"],
        ],
    ],
    [
        "name": "get_pictures",
        "description": """
            See the camera photos and screenshots of a conversation, as images. Ask for \
            particular ones by the names read_recording lists, or for a stretch of time with \
            from and to. Screenshots show what was on the user's screen at that moment; photos \
            show the room from the Mac's camera. Up to 8 images a call, oldest first.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The id from list_recordings, or the recording's name."],
                "names": ["type": "array", "items": ["type": "string"], "description": "Pictures by name, as listed by read_recording (for example Screens/[ 16 Oct ] Fri 10.46 am - 00-45.jpg)."],
                "from": ["type": "string", "description": "Start time, as 12:30. Used when names are not given."],
                "to": ["type": "string", "description": "End time."],
                "which": ["type": "string", "enum": ["all", "photos", "screenshots"], "description": "Default all."],
                "limit": ["type": "integer", "description": "Maximum images, 1 to 8. Default 8."],
            ],
            "required": ["id"],
        ],
    ],
]

@MainActor
enum RecordingTools {
    /// Content blocks for a tools/call reply: text, and for get_pictures, images.
    static func call(_ name: String, _ arguments: [String: Any]) -> [[String: Any]]? {
        switch name {
        case "list_recordings": return [text(list(arguments))]
        case "search_recordings": return [text(search(arguments))]
        case "read_recording": return [text(read(arguments))]
        case "get_pictures": return pictures(arguments)
        default: return nil
        }
    }

    private static func text(_ string: String) -> [String: Any] { ["type": "text", "text": string] }

    private static func day(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: String(text.prefix(10)))
    }

    private static func summary(_ r: Recordings.Recording) -> String {
        var lines = ["\(r.kind == "meeting" ? "Meeting" : "Conversation"): \(r.name)", "id: \(r.id)"]
        lines.append("date: \(Recordings.longDate.string(from: r.date))")
        for key in ["Length", "Speakers", "Language", "From"] { if let value = r.facts[key] { lines.append("\(key.lowercased()): \(value)") } }
        if !r.photos.isEmpty || !r.screens.isEmpty {
            func many(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
            lines.append("pictures: \(many(r.photos.count, "photo")), \(many(r.screens.count, "screenshot"))")
        }
        if r.transcript == nil { lines.append("transcript: not transcribed yet") }
        if let first = r.rows.first(where: { !$0.text.isEmpty }) {
            lines.append("opens: \(first.text.prefix(160))")
        }
        return lines.joined(separator: "\n")
    }

    private static func list(_ a: [String: Any]) -> String {
        var items = Recordings.all(kind: a["kind"] as? String ?? "all")
        if let since = day(a["since"] as? String) { items = items.filter { $0.date >= since } }
        if let until = day(a["until"] as? String) { items = items.filter { $0.date < until.addingTimeInterval(86_400) } }
        if let query = (a["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            items = items.filter { r in
                r.name.localizedCaseInsensitiveContains(query) || r.rows.contains { $0.text.localizedCaseInsensitiveContains(query) }
            }
        }
        let limit = max(1, min(500, a["limit"] as? Int ?? 50))
        guard !items.isEmpty else { return "No meetings or conversations matched, in \(Recordings.root.path)." }
        return "\(items.count) found\(items.count > limit ? ", showing \(limit)" : "").\n\n"
            + items.prefix(limit).map(summary).joined(separator: "\n\n")
    }

    private static func search(_ a: [String: Any]) -> String {
        let query = (a["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "Provide words to search for." }
        let limit = max(1, min(300, a["limit"] as? Int ?? 40))
        var out: [String] = []
        var count = 0
        for r in Recordings.all(kind: a["kind"] as? String ?? "all") {
            for (index, row) in r.rows.enumerated()
            where row.text.localizedCaseInsensitiveContains(query)
                || row.descriptions.values.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
                count += 1
                guard out.count < limit else { continue }
                var block = ["\(r.kind == "meeting" ? "Meeting" : "Conversation") \(r.id) at [\(row.stamp)]"]
                if index > 0 { block.append("  before: \(line(r.rows[index - 1]))") }
                block.append("  match:  \(line(row))")
                if index + 1 < r.rows.count { block.append("  after:  \(line(r.rows[index + 1]))") }
                out.append(block.joined(separator: "\n"))
            }
        }
        guard !out.isEmpty else { return "No transcript mentions \"\(query)\"." }
        return "\(count) matching line\(count == 1 ? "" : "s")\(count > limit ? ", showing \(limit)" : "").\n\n" + out.joined(separator: "\n\n")
    }

    private static func line(_ row: Recordings.Row) -> String {
        let who = row.speaker.map { "\($0): " } ?? ""
        let words = row.text.isEmpty ? "(screenshot)" : row.text
        // Each picture with what is in it, once the app has read it.
        let named = row.pictures.map { path in row.descriptions[path].map { "\(path) (shows: \($0))" } ?? path }
        let pictures = row.pictures.isEmpty ? "" : "  [pictures: \(named.joined(separator: "; "))]"
        return "[\(row.stamp)] \(who)\(words)\(pictures)"
    }

    private static func read(_ a: [String: Any]) -> String {
        guard let r = Recordings.find(a["id"] as? String ?? "") else {
            return "No meeting or conversation matches that id. Call list_recordings for the ids."
        }
        let from = Recordings.seconds(a["from"] as? String) ?? 0
        let to = Recordings.seconds(a["to"] as? String) ?? .infinity
        var out = [summary(r)]
        guard r.transcript != nil else {
            return out.joined() + "\n\nIt has no transcript yet: the app has not finished transcribing it, or it failed."
        }
        let rows = r.rows.filter { $0.start >= from && $0.start <= to }
        out.append("")
        out.append(from > 0 || to.isFinite ? "Transcript from \(Recordings.clock(from)) to \(to.isFinite ? Recordings.clock(to) : "the end"):" : "Transcript:")
        out += rows.map(line)
        if !r.photos.isEmpty || !r.screens.isEmpty {
            out.append("")
            out.append("Pictures (pass names to get_pictures):")
            var shows: [String: String] = [:]
            for row in r.rows { shows.merge(row.descriptions) { first, _ in first } }
            for path in r.photos + r.screens {
                let at = Recordings.pictureTime(path).map(Recordings.clock) ?? "?"
                let what = shows[path].map { " shows: \($0)" } ?? ""
                out.append("  [\(at)] \(path.hasPrefix("Screens/") ? "screenshot" : "photo") \(path)\(what)")
            }
        }
        return out.joined(separator: "\n")
    }

    /// The images themselves. Screenshots are sent at most 1568 px on the long side, the most
    /// Claude looks at; photos are already smaller.
    private static func pictures(_ a: [String: Any]) -> [[String: Any]] {
        guard let r = Recordings.find(a["id"] as? String ?? "") else {
            return [text("No meeting or conversation matches that id. Call list_recordings for the ids.")]
        }
        let limit = max(1, min(8, a["limit"] as? Int ?? 8))
        var chosen: [String]
        if let names = a["names"] as? [String], !names.isEmpty {
            let all = r.photos + r.screens
            chosen = names.compactMap { name in all.first { $0 == name || $0.hasSuffix(name) || ($0 as NSString).lastPathComponent == name } }
        } else {
            let which = a["which"] as? String ?? "all"
            chosen = (which == "screenshots" ? [] : r.photos) + (which == "photos" ? [] : r.screens)
            let from = Recordings.seconds(a["from"] as? String) ?? 0
            let to = Recordings.seconds(a["to"] as? String) ?? .infinity
            chosen = chosen.filter { (Recordings.pictureTime($0) ?? 0) >= from && (Recordings.pictureTime($0) ?? 0) <= to }
        }
        chosen.sort { (Recordings.pictureTime($0) ?? 0) < (Recordings.pictureTime($1) ?? 0) }
        guard !chosen.isEmpty else {
            return [text("No pictures there. \(r.photos.count) photos and \(r.screens.count) screenshots in \(r.name); read_recording lists them.")]
        }
        var blocks: [[String: Any]] = [text(
            "\(min(chosen.count, limit)) of \(chosen.count) picture\(chosen.count == 1 ? "" : "s") from \(r.name)"
                + (chosen.count > limit ? "; ask again with a later from to see the rest." : "."))]
        for path in chosen.prefix(limit) {
            let at = Recordings.pictureTime(path).map(Recordings.clock) ?? "?"
            blocks.append(text("[\(at)] \(path.hasPrefix("Screens/") ? "Screenshot" : "Photo"): \(path)"))
            if let data = jpeg(r.folder.appendingPathComponent(path)) {
                blocks.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
            } else {
                blocks.append(text("(couldn't read that file)"))
            }
        }
        return blocks
    }

    private static func jpeg(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1568,
              ] as CFDictionary) else { return try? Data(contentsOf: url) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
