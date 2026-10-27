import Foundation

/// Dictations as files you can open without the app (docs/mockups/dictations-folder.html,
/// Gokul's picks 1B 2A 3A 4A, 20 Oct 2026): one Markdown file a month in the SigmaFlow
/// folder, `Dictations/2026/10 October.md`. Newest day first; each day a table of the time
/// and the words, oldest first:
///
///     # October 2026
///
///     Dictations: 1,447
///     Words: 52,310
///
///     ## [ 19 Oct ] Sun
///
///     | Time | Dictation |
///     |---|---|
///     | 9.02 am | Remind me to send the deck to Priya before Friday. |
///
/// The words in a row are read back (3A): a word fixed here by hand is fixed in the app.
/// A row is known by its day and time (in order, so two in one minute stay apart), so only
/// the words can be edited this way; a row deleted or changed beyond its words comes back
/// the next time the month is written. Until 20 Oct 2026 a Length column sat between time
/// and words (2B); files written then are still read, by their header.
enum DictationMarkdown {
    struct Row: Equatable {
        let day: String
        let time: String
        let text: String
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }

    // English names on purpose, as for meetings: a file name is an address.
    private static let dayFormatter = formatter("d MMM")
    private static let weekdayFormatter = formatter("EEE")
    private static let clockFormatter = formatter("h.mm a")
    private static let titleFormatter = formatter("MMMM yyyy")
    /// "1,447": grouped, the same on every Mac.
    private static let countLocale = Locale(identifier: "en_US")

    /// `2026/10 October.md`, under the Dictations folder: the same year and month folders
    /// meetings sit in, with the month a file rather than a folder.
    static func relativePath(for date: Date) -> String {
        "\(MeetingNaming.yearFolder(for: date))/\(MeetingNaming.monthFolder(for: date)).md"
    }

    /// `[ 19 Oct ] Sun`, a day's heading.
    static func day(_ date: Date) -> String {
        "[ \(dayFormatter.string(from: date)) ] \(weekdayFormatter.string(from: date))"
    }

    /// `9.02 am`.
    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    static func key(of run: DictationRun) -> (day: String, time: String) {
        (day(run.date), clock(run.date))
    }

    /// One month's dictations in the order the file lists them: days newest first, each
    /// day's dictations oldest first.
    static func ordered(_ month: [DictationRun]) -> [DictationRun] {
        let byDay = Dictionary(grouping: month) { Calendar.current.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).flatMap { dayStart in
            byDay[dayStart, default: []].sorted { $0.date < $1.date }
        }
    }

    /// The whole file for one month's dictations (all from the same month).
    static func render(month: [DictationRun]) -> String {
        let runs = ordered(month)
        guard let first = runs.first else { return "" }
        let words = runs.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        var out = "# \(titleFormatter.string(from: first.date))\n\n"
        out += "Dictations: \(runs.count.formatted(.number.locale(countLocale)))  \n"
        out += "Words: \(words.formatted(.number.locale(countLocale)))\n"
        var currentDay: String?
        for run in runs {
            let (day, time) = key(of: run)
            if day != currentDay {
                currentDay = day
                out += "\n## \(day)\n\n| Time | Dictation |\n|---|---|\n"
            }
            out += "| \(time) | \(escape(run.text)) |\n"
        }
        return out
    }

    /// Every dictation row in a month's file, under the day heading it sits beneath.
    static func rows(in markdown: String) -> [Row] {
        var rows: [Row] = []
        var day = ""
        // Which column the words are in, from the table's header: the second, or the third
        // in a file from before 20 Oct 2026 with Length between.
        var wordsColumn = 1
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                day = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("| Time |") {
                wordsColumn = cells(of: line).contains("Length") ? 2 : 1
                continue
            }
            guard line.hasPrefix("|"), !line.hasPrefix("|---") else { continue }
            let cells = cells(of: line)
            guard cells.count > wordsColumn else { continue }
            // A pipe typed by hand without its backslash splits the words; they rejoin here.
            let text = cells[wordsColumn...].joined(separator: "|")
            rows.append(Row(day: day, time: cells[0], text: unescape(text)))
        }
        return rows
    }

    /// A table row's cells, split on pipes that are not escaped, trimmed.
    private static func cells(of line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line.dropFirst() {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { cells.append(tail) }
        return cells
    }

    /// What a table cell can hold: a pipe would end the cell and a line break the row.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    static func unescape(_ cell: String) -> String {
        var out = ""
        var escaped = false
        for character in cell {
            if escaped {
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out.replacingOccurrences(of: "<br>", with: "\n")
    }

    /// The words of `month` as edited by hand in `file`, by position: each dictation takes
    /// the next row, from where the last match was, with its day and time. Rows
    /// added by hand match nothing and are left out; a row whose words were emptied keeps
    /// the dictation's words. - Returns: the changed texts by run id.
    static func handEdits(in file: String, for month: [DictationRun]) -> [UUID: String] {
        let rows = rows(in: file)
        var edits: [UUID: String] = [:]
        var next = 0
        for run in ordered(month) {
            let key = key(of: run)
            guard next < rows.count,
                  let found = rows[next...].firstIndex(where: {
                      $0.day == key.day && $0.time == key.time
                  }) else { continue }
            next = found + 1
            // Cells lose the spaces at their ends, so a dictation is compared the same way.
            let text = rows[found].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != run.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                edits[run.id] = text
            }
        }
        return edits
    }
}
