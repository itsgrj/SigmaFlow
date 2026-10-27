import Foundation

// A meeting is a folder in SigmaFlow/Meetings, and nothing else:
//
//     Meetings/2026/10 October/[ 13 Oct ] Tue 2.30 pm - 48 min/
//         [ 13 Oct ] Tue 2.30 pm - 48 min.m4a
//         [ 13 Oct ] Tue 2.30 pm - 48 min.md
//         Photos/[ 13 Oct ] Tue 2.30 pm - 00-30.jpg     (live notes only)
//         Screens/[ 13 Oct ] Tue 2.30 pm - 00-45.jpg    (live notes only)
//
// The folder is the record. The app reads it back on every visit, so a meeting renamed,
// moved or deleted in Finder is renamed, moved or deleted in the app too. There is no
// second copy anywhere to fall out of step (Gokul, 13 Oct 2026).

/// One row of a transcript: where it starts in the recording, who said it, what was said.
struct MeetingLine: Hashable, Sendable {
    var start: Double
    /// "Speaker 1", "Speaker 2" for voices told apart by sound, in order of first
    /// appearance; a real name when someone typed one into the .md (or in a transcript from
    /// before 14 Oct 2026, which named the microphone side). Nil when there is no telling.
    var speaker: String?
    var text: String
    /// Live notes' camera photos taken while this row was spoken, as paths inside the
    /// meeting's folder ("Photos/[ 16 Oct ] Fri 10.32 am - 00-30.jpg").
    var photos: [String] = []
    /// A screenshot row: live notes' screenshot taken at `start`, on a row of its own with
    /// no words ("Screens/[ 16 Oct ] Fri 10.32 am - 00-45.jpg").
    var screens: [String] = []
    /// What is in each picture, by its path: the image text in the .md
    /// (`![a whiteboard with …](<Photos/…>)`), written by search's picture reader, or by hand.
    var descriptions: [String: String] = [:]

    var isScreenshot: Bool { !screens.isEmpty && text.isEmpty }
}

struct Meeting: Identifiable, Hashable, Sendable {
    /// The meeting's own folder.
    var folder: URL
    var audioURL: URL?
    var transcriptURL: URL?
    var date: Date
    /// Seconds.
    var duration: Double
    var lines: [MeetingLine]
    /// The call app it was recorded from, when it came from a call: "Zoom".
    var app: String? = nil
    /// What the transcript was heard as. Nil for transcripts from before 13 Oct 2026, which
    /// have no Language line.
    var language: MeetingLanguage? = nil
    /// Voices told apart, from the Speakers line. Two voices can share a name (Gokul, 14 Oct
    /// 2026, 3B), so the labels alone undercount.
    var speakers: Int? = nil
    /// Live notes' camera photos in the folder's Photos folder, for the list's stacks.
    var photos: [URL] = []

    /// The folder path: stable until the meeting is renamed, which is when it should change.
    var id: String { folder.path }
    var name: String { folder.lastPathComponent }
    var hasTranscript: Bool { transcriptURL != nil }

    var speakerCount: Int { speakers ?? Set(lines.compactMap(\.speaker)).count }

    /// Each label once, in the order it first speaks: the speakers row under the title.
    var speakerLabels: [String] {
        var seen = Set<String>()
        return lines.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }

    /// The words, for search.
    var spokenText: String { lines.map(\.text).joined(separator: " ") }

    /// The part a rename may change: what follows the date, time and length.
    var title: String? { MeetingNaming.title(in: name, date: date, duration: duration) }

    /// Still the name it was filed under, " 2" and all: never given a title in the app or in
    /// Finder. Only these are named automatically.
    var hasDateName: Bool {
        let base = MeetingNaming.name(for: date, duration: duration)
        guard name.hasPrefix(base) else { return false }
        let rest = name.dropFirst(base.count)
        return rest.isEmpty || (rest.first == " " && rest.dropFirst().allSatisfy(\.isNumber) && rest.count > 1)
    }
}

// MARK: - Names

/// How everything in the Meetings folder is named. English month and day names on
/// purpose: a folder name is an address, and it must read the same on every Mac.
enum MeetingNaming {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }

    private static let dayFormatter = formatter("d MMM")
    private static let weekdayFormatter = formatter("EEE")
    private static let clockFormatter = formatter("h.mm a")
    private static let yearFormatter = formatter("yyyy")
    private static let monthFormatter = formatter("MM MMMM")
    private static let longDateFormatter = formatter("EEEE d MMMM yyyy, h.mm a")

    /// Whole minutes, never zero: a 40-second meeting is "1 min".
    static func minutes(_ seconds: Double) -> Int {
        max(1, Int((seconds / 60).rounded()))
    }

    /// `[ 13 Oct ] Tue 2.30 pm`, the name of a meeting still recording.
    static func stem(for date: Date) -> String {
        "[ \(dayFormatter.string(from: date)) ] \(weekdayFormatter.string(from: date)) \(clockFormatter.string(from: date))"
    }

    /// `[ 13 Oct ] Tue 2.30 pm - 48 min`, a finished meeting.
    static func name(for date: Date, duration: Double) -> String {
        "\(stem(for: date)) - \(minutes(duration)) min"
    }

    /// A renamed meeting keeps the full name and adds the title after it (Gokul, 3B).
    static func name(for date: Date, duration: Double, title: String?) -> String {
        let base = name(for: date, duration: duration)
        guard let title = title.map(sanitized), !title.isEmpty else { return base }
        return "\(base) - \(title)"
    }

    /// What follows the full name in a renamed meeting, or nil when it was never renamed
    /// (or was renamed in Finder into something else entirely).
    static func title(in folderName: String, date: Date, duration: Double) -> String? {
        let prefix = name(for: date, duration: duration) + " - "
        guard folderName.hasPrefix(prefix) else { return nil }
        let title = String(folderName.dropFirst(prefix.count))
        return title.isEmpty ? nil : title
    }

    /// `2026` and `10 October`: the two folders above every meeting. Twelve months at most
    /// inside a year, so the Meetings folder never turns into a wall.
    static func yearFolder(for date: Date) -> String { yearFormatter.string(from: date) }
    static func monthFolder(for date: Date) -> String { monthFormatter.string(from: date) }

    /// `Tuesday 13 October 2026, 2.30 pm`, the Date line inside the .md.
    static func longDate(_ date: Date) -> String { longDateFormatter.string(from: date) }
    static func parseLongDate(_ text: String) -> Date? { longDateFormatter.date(from: text) }

    /// `48 min`, `1 h 55 min`.
    static func length(_ seconds: Double) -> String {
        let total = minutes(seconds)
        return total >= 60 ? "\(total / 60) h \(total % 60) min" : "\(total) min"
    }

    /// The inverse of `length`, to the minute.
    static func parseLength(_ text: String) -> Double? {
        let parts = text.split(separator: " ").map(String.init)
        var minutes = 0
        var index = 0
        while index + 1 < parts.count {
            guard let value = Int(parts[index]) else { return nil }
            switch parts[index + 1] {
            case "h": minutes += value * 60
            case "min": minutes += value
            default: return nil
            }
            index += 2
        }
        return minutes > 0 ? Double(minutes * 60) : nil
    }

    /// `00:48` under an hour, `01:02:15` past it.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total >= 3600 {
            return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func parseClock(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3, parts.count == text.split(separator: ":").count else { return nil }
        return Double(parts.reduce(0) { $0 * 60 + $1 })
    }

    /// `[ 16 Oct ] Fri 10.32 am - 00-30.jpg`: the meeting's start, then how far into it the
    /// photo was taken, `01-02-30` past an hour. Renaming the meeting changes none of them
    /// (docs/mockups/live-notes.html, 2B).
    static func photoName(stem: String, at seconds: Double) -> String {
        "\(stem) - \(clock(seconds).replacingOccurrences(of: ":", with: "-")).jpg"
    }

    /// The time a photo was taken, read back from its name.
    static func photoTime(_ fileName: String) -> Double? {
        guard let dash = fileName.range(of: " - ", options: .backwards) else { return nil }
        let stamp = fileName[dash.upperBound...].replacingOccurrences(of: ".jpg", with: "")
        return parseClock(stamp.replacingOccurrences(of: "-", with: ":"))
    }

    /// The label for a voice told apart by sound.
    static func speaker(_ number: Int) -> String { "Speaker \(number)" }

    /// A typed speaker name, made safe for the .md: no line breaks, and nothing that would
    /// end the bold label or the table cell early.
    static func speakerLabel(_ typed: String) -> String {
        typed.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isNumberedSpeaker(_ label: String) -> Bool {
        label.hasPrefix("Speaker ") && Int(label.dropFirst("Speaker ".count)) != nil
    }

    /// Finder forbids a colon and treats a slash as one; a leading dot would hide the folder.
    static func sanitized(_ title: String) -> String {
        var clean = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }
        return clean
    }
}

// MARK: - The .md file

/// The transcript file: a heading, labelled lines, and a two-column table, time on the
/// left and what was said on the right (Gokul, 13 Oct 2026). It reads as a table in any
/// app that renders Markdown and stays legible as plain text. The app reads it back, so
/// an edit made in a text editor shows up in the app.
enum MeetingMarkdown {
    static func render(
        name: String, date: Date, duration: Double, lines: [MeetingLine], audioFileName: String, app: String? = nil,
        language: MeetingLanguage? = nil, speakers: Int? = nil
    ) -> String {
        var out = "# \(name)\n\n"
        out += "Date: \(MeetingNaming.longDate(date))  \n"
        out += "Length: \(MeetingNaming.length(duration))  \n"
        if let app { out += "From: \(app)  \n" }
        let speakers = speakers ?? Set(lines.compactMap(\.speaker)).count
        if speakers > 0 { out += "Speakers: \(speakers)  \n" }
        if let language { out += "Language: \(language.label)  \n" }
        out += "Audio: \(audioFileName)\n\n"
        out += "| Time | Transcription |\n"
        out += "|---|---|\n"
        for line in lines {
            let who = line.speaker.map { "**\($0):** " } ?? ""
            // A photo shows in its row in any Markdown app; the file sits beside the .md, and
            // what is in it, once read, is its image text.
            let photos = line.photos.map { " " + image($0, line.descriptions[$0]) }.joined()
            // A screenshot row: the picture where the words go.
            let words = line.isScreenshot
                ? line.screens.map { image($0, line.descriptions[$0]) }.joined(separator: " ")
                : who + escaped(line.text)
            out += "| [\(MeetingNaming.clock(line.start))]\(photos) | \(words) |\n"
        }
        return out
    }

    struct Parsed {
        var date: Date?
        var duration: Double?
        var app: String?
        var language: MeetingLanguage?
        var speakers: Int?
        var lines: [MeetingLine] = []
    }

    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Date: ") {
                parsed.date = MeetingNaming.parseLongDate(String(line.dropFirst("Date: ".count)))
            } else if line.hasPrefix("From: ") {
                parsed.app = String(line.dropFirst("From: ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Language: ") {
                parsed.language = MeetingLanguage(label: String(line.dropFirst("Language: ".count)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("Speakers: ") {
                parsed.speakers = Int(line.dropFirst("Speakers: ".count).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("Length: ") {
                parsed.duration = MeetingNaming.parseLength(String(line.dropFirst("Length: ".count)))
            } else if line.hasPrefix("| ["), let row = row(line) {
                parsed.lines.append(row)
            }
        }
        return parsed
    }

    /// `| [00:09] | **Speaker 2:** The first four lessons are recorded. |`, and with live
    /// notes' photos in the time cell: `| [00:30] ![](<Photos/… - 00-30.jpg>) | … |`.
    private static func row(_ line: String) -> MeetingLine? {
        guard let bracket = line.range(of: "]"),
              let close = line.range(of: " |", range: bracket.upperBound..<line.endIndex) else { return nil }
        let stamp = line[line.index(line.startIndex, offsetBy: 3)..<bracket.lowerBound]
        guard let start = MeetingNaming.parseClock(String(stamp)) else { return nil }
        var descriptions: [String: String] = [:]
        let photos = images(in: line[bracket.upperBound..<close.lowerBound]).map { image in
            if !image.alt.isEmpty { descriptions[image.path] = image.alt }
            return image.path
        }
        var cell = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        if cell.hasSuffix("|"), !cell.hasSuffix("\\|") { cell.removeLast() }
        cell = cell.trimmingCharacters(in: .whitespaces)

        // `**Ravi:** ` or `**Speaker 2:** ` at the head of the cell is who said it.
        var speaker: String?
        if cell.hasPrefix("**"), let end = cell.range(of: ":** ") {
            let label = String(cell[cell.index(cell.startIndex, offsetBy: 2)..<end.lowerBound])
            if !label.isEmpty, !label.contains("**") {
                speaker = label
                cell = String(cell[end.upperBound...])
            }
        }
        // A screenshot row: only pictures where the words go.
        if speaker == nil, cell.hasPrefix("!["), !images(in: Substring(cell)).isEmpty {
            let screens = images(in: Substring(cell)).map { image in
                if !image.alt.isEmpty { descriptions[image.path] = image.alt }
                return image.path
            }
            return MeetingLine(start: start, speaker: nil, text: "", photos: photos, screens: screens, descriptions: descriptions)
        }
        return MeetingLine(start: start, speaker: speaker, text: unescaped(cell), photos: photos, descriptions: descriptions)
    }

    // MARK: Pictures

    /// `![what is in it](<Photos/… - 00-30.jpg>)`, or `![](<…>)` before it has been read.
    static func image(_ path: String, _ alt: String?) -> String {
        "![\(alt.map(altText) ?? "")](<\(path)>)"
    }

    /// Every `![alt](<path>)` in a cell, in order.
    static func images(in text: Substring) -> [(path: String, alt: String)] {
        var out: [(String, String)] = []
        var rest = text
        while let open = rest.range(of: "!["),
              let middle = rest.range(of: "](<", range: open.upperBound..<rest.endIndex),
              let end = rest.range(of: ">)", range: middle.upperBound..<rest.endIndex) {
            out.append((String(rest[middle.upperBound..<end.lowerBound]), String(rest[open.upperBound..<middle.lowerBound])))
            rest = rest[end.upperBound...]
        }
        return out
    }

    /// Where one picture's mark sits in a row, its image text included.
    static func imageRange(of path: String, in line: String) -> Range<String.Index>? {
        guard let tail = line.range(of: "](<\(path)>)"),
              let open = line.range(of: "![", options: .backwards, range: line.startIndex..<tail.lowerBound) else { return nil }
        return open.lowerBound..<tail.upperBound
    }

    /// A description made safe for image text: one line, and nothing that would end the image,
    /// the cell or the row early, or read as Markdown.
    static func altText(_ text: String) -> String {
        var clean = text
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        for mark in ["[", "]", "<", ">", "|", "*", "`", "\\"] { clean = clean.replacingOccurrences(of: mark, with: "") }
        while clean.contains("  ") { clean = clean.replacingOccurrences(of: "  ", with: " ") }
        return String(clean.prefix(600)).trimmingCharacters(in: .whitespaces)
    }

    /// The transcript with each picture that has no image text yet given its description.
    /// Image text already there, written by hand or earlier, is left as it is, and so is every
    /// other byte of the file.
    static func describing(_ text: String, with descriptions: [String: String]) -> String {
        text.components(separatedBy: "\n").map { line in
            guard line.hasPrefix("| [") else { return line }
            var out = line
            for (path, description) in descriptions {
                let empty = "![](<\(path)>)"
                guard out.contains(empty) else { continue }
                out = out.replacingOccurrences(of: empty, with: image(path, description))
            }
            return out
        }.joined(separator: "\n")
    }

    /// A pipe would end the cell early; a line break would end the row.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\|", with: "|")
    }
}
