import Foundation

/// The numbers on Transcriptions > Insights (docs/mockups/insights.html, round 6), worked
/// out from the dictation history at read time. Nothing is stored; a deleted or edited
/// transcription changes them the next time the tab opens.
///
/// Dictations only: meetings and conversations are everyone talking, not the user. Fun
/// facts, never goals (Gokul, 18 Oct 2026): nothing here can drop after a missed day, and
/// nothing counts down to a book.
struct UsageInsights {
    /// The usual figure for an average typist; "time saved" compares talking with typing
    /// the same words at this speed.
    static let typingWordsPerMinute = 40.0
    /// About a paperback's page.
    static let wordsPerPage = 300

    struct Day {
        var words = 0
        var dictations = 0
        /// Talking plus waiting for the words to land.
        var seconds = 0.0

        /// Typing these words, less the time spent talking and waiting. Waiting counts
        /// against it, so a slow model shows up here.
        var savedMinutes: Double {
            max(0, Double(words) / UsageInsights.typingWordsPerMinute - seconds / 60)
        }
    }

    let words: Int
    let dictations: Int
    /// Keyed by the start of each calendar day.
    let days: [Date: Day]
    let today: Day
    /// The first day with a dictation; nil before the first one.
    let firstDay: Date?

    init(runs: [DictationRun], now: Date = Date(), calendar: Calendar = .current) {
        var days: [Date: Day] = [:]
        var words = 0
        for run in runs {
            let count = run.text.split(whereSeparator: \.isWhitespace).count
            guard count > 0 else { continue }
            let key = calendar.startOfDay(for: run.date)
            days[key, default: Day()].words += count
            days[key, default: Day()].dictations += 1
            days[key, default: Day()].seconds += run.audioSeconds + run.processSeconds
            words += count
        }
        self.days = days
        self.words = words
        self.dictations = days.values.reduce(0) { $0 + $1.dictations }
        self.today = days[calendar.startOfDay(for: now)] ?? Day()
        self.firstDay = days.keys.min()
    }

    /// An average day, in whole minutes that add up as the squares' card says them: typing
    /// these words takes this long, saying them that long, the rest is the time back.
    struct AverageDay {
        let words: Int
        let typingMinutes: Int
        let talkingMinutes: Int
        var savedMinutes: Int { max(0, typingMinutes - talkingMinutes) }
    }

    /// Spread over every day since the first dictation, today included, so a quiet day
    /// lowers the average the way it would on a stopwatch.
    func averageDay(now: Date = Date(), calendar: Calendar = .current) -> AverageDay {
        guard let firstDay else { return AverageDay(words: 0, typingMinutes: 0, talkingMinutes: 0) }
        let span = Double((calendar.dateComponents([.day], from: firstDay, to: calendar.startOfDay(for: now)).day ?? 0) + 1)
        let seconds = days.values.reduce(0) { $0 + $1.seconds }
        let words = Double(self.words) / span
        return AverageDay(
            words: Int(words.rounded()),
            typingMinutes: Int((words / Self.typingWordsPerMinute).rounded()),
            talkingMinutes: Int((seconds / 60 / span).rounded()))
    }

    var pages: Int { max(1, Int((Double(words) / Double(Self.wordsPerPage)).rounded())) }

    /// The longest famous book the words are at least as long as; nil below the shortest.
    var longestBookPassed: FamousBook? { FamousBook.all.last { $0.words <= words } }
}

/// A book everyone knows by name, with its commonly published English word count. Short to
/// long, so the sentence on Insights always has a book to name, from the first day (The
/// Cat in the Hat) to years in (In Search of Lost Time). The cover is
/// `Resources/BookCovers/<cover>.jpg`, from Open Library.
struct FamousBook: Identifiable {
    let title: String
    let words: Int
    let cover: String

    var id: String { cover }

    static let all: [FamousBook] = [
        FamousBook(title: "The Cat in the Hat", words: 1_626, cover: "cat-in-the-hat"),
        FamousBook(title: "The Little Prince", words: 17_000, cover: "little-prince"),
        FamousBook(title: "The Old Man and the Sea", words: 26_601, cover: "old-man-and-the-sea"),
        FamousBook(title: "A Christmas Carol", words: 28_944, cover: "christmas-carol"),
        FamousBook(title: "Of Mice and Men", words: 29_160, cover: "of-mice-and-men"),
        FamousBook(title: "Animal Farm", words: 29_966, cover: "animal-farm"),
        FamousBook(title: "Charlie and the Chocolate Factory", words: 30_644, cover: "charlie-chocolate-factory"),
        FamousBook(title: "The Alchemist", words: 39_000, cover: "alchemist"),
        FamousBook(title: "Fahrenheit 451", words: 46_118, cover: "fahrenheit-451"),
        FamousBook(title: "The Great Gatsby", words: 47_094, cover: "great-gatsby"),
        FamousBook(title: "The Catcher in the Rye", words: 73_404, cover: "catcher-in-the-rye"),
        FamousBook(title: "Frankenstein", words: 74_800, cover: "frankenstein"),
        FamousBook(title: "Harry Potter and the Philosopher's Stone", words: 76_944, cover: "harry-potter-1"),
        FamousBook(title: "Nineteen Eighty-Four", words: 88_942, cover: "nineteen-eighty-four"),
        FamousBook(title: "The Hobbit", words: 95_356, cover: "hobbit"),
        FamousBook(title: "The Hunger Games", words: 99_750, cover: "hunger-games"),
        FamousBook(title: "To Kill a Mockingbird", words: 100_388, cover: "to-kill-a-mockingbird"),
        FamousBook(title: "Pride and Prejudice", words: 122_189, cover: "pride-and-prejudice"),
        FamousBook(title: "The Da Vinci Code", words: 138_952, cover: "da-vinci-code"),
        FamousBook(title: "Jane Eyre", words: 183_858, cover: "jane-eyre"),
        FamousBook(title: "Little Women", words: 185_000, cover: "little-women"),
        FamousBook(title: "Moby-Dick", words: 206_052, cover: "moby-dick"),
        FamousBook(title: "Crime and Punishment", words: 211_591, cover: "crime-and-punishment"),
        FamousBook(title: "Harry Potter and the Order of the Phoenix", words: 257_045, cover: "harry-potter-5"),
        FamousBook(title: "A Game of Thrones", words: 292_727, cover: "game-of-thrones"),
        FamousBook(title: "Anna Karenina", words: 349_736, cover: "anna-karenina"),
        FamousBook(title: "The Lord of the Rings", words: 481_103, cover: "lord-of-the-rings"),
        FamousBook(title: "Les Misérables", words: 530_982, cover: "les-miserables"),
        FamousBook(title: "War and Peace", words: 587_287, cover: "war-and-peace"),
        FamousBook(title: "All seven Harry Potter books", words: 1_084_170, cover: "harry-potter-1-7"),
        FamousBook(title: "In Search of Lost Time", words: 1_267_069, cover: "in-search-of-lost-time"),
    ]
}
