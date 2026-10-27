import AppKit
import SwiftUI

/// Transcriptions > Insights (docs/mockups/insights.html, 18 Oct 2026; rethought 21 Oct 2026,
/// docs/mockups/insights-revamp.html, A written as A1 Plain). Today leads, as a sum: what
/// SigmaFlow wrote plus what was typed is what the day needed, because today is what a person
/// holds in mind, not an all-time 3,574. The squares carry the time saved, worked out in plain
/// words; the bookcase carries the all-time numbers. A fun fact, never a goal: no streak, no
/// "next book", nothing that marks a book as done.
struct InsightsView: View {
    let insights: UsageInsights

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            TodayCard(dictated: insights.today.words, typed: TypedWords.shared.today)
            YearSquares(insights: insights)
            Bookshelf(insights: insights)
        }
    }
}

// MARK: - Today

/// "SigmaFlow wrote 97% of your words today", then the day as a sum, then what typing it all
/// would have cost. The words are SigmaFlow's, never "you said" (Gokul, 21 Oct 2026). Typed
/// words come from `TypedWords`, counted since the day that shipped.
private struct TodayCard: View {
    let dictated: Int
    let typed: Int

    private var total: Int { dictated + typed }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                Eyebrow("Today")
                Text(total == 0 ? "Nothing written yet today." : "SigmaFlow wrote \(share)% of your words today.")
                    .font(DS.Font.insightSentence)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: DS.Space.wide) {
                    term(dictated, "Written with\nSigmaFlow", ink: DS.Color.ink)
                    sign("+")
                    term(typed, "Typed\nby you", ink: DS.Color.inkSecondary)
                    sign("=")
                    term(total, "Your words\ntoday", ink: DS.Color.ink)
                }
                if total > 0 {
                    VStack(alignment: .leading, spacing: DS.Space.tight) {
                        Text("Without SigmaFlow, you\u{2019}d have typed all \(total.formatted()).")
                        Text("That would have taken you \(Self.typingTime(words: total)).")
                    }
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Space.roomy)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Never 100% while anything was typed, never 0% while SigmaFlow wrote anything.
    private var share: Int {
        guard typed > 0 else { return dictated > 0 ? 100 : 0 }
        guard dictated > 0 else { return 0 }
        return max(1, min(99, Int((Double(dictated) / Double(total) * 100).rounded())))
    }

    private func term(_ words: Int, _ caption: String, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            // Full size always: a day's words stay a few digits, so three numbers and two
            // signs fit even the narrowest window.
            Text(words.formatted())
                .font(DS.Font.insightNumber)
                .foregroundStyle(ink)
                .fixedSize()
            Text(caption)
                .font(DS.Font.micro)
                .foregroundStyle(DS.Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sign(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.insightNumber)
            .foregroundStyle(DS.Color.dim)
    }

    /// Typing at the usual 40 words a minute: "about 59 minutes", "about 1 hour 12 minutes".
    static func typingTime(words: Int) -> String {
        let minutes = Int((Double(words) / UsageInsights.typingWordsPerMinute).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes == 1 { return "about a minute" }
        if minutes < 60 { return "about \(minutes) minutes" }
        let hours = minutes / 60, rest = minutes % 60
        let lead = hours == 1 ? "about 1 hour" : "about \(hours) hours"
        return rest == 0 ? lead : lead + (rest == 1 ? " 1 minute" : " \(rest) minutes")
    }
}

// MARK: - The year of squares

/// GitHub's grid: the last 53 weeks, a column per week, Sunday on top, greener for more
/// words. Pointing at a day names its words and the time it saved (7 A).
private struct YearSquares: View {
    let insights: UsageInsights

    @State private var width: CGFloat = 0
    @State private var tip: HoverTip.Spot?

    /// The same calendar `UsageInsights` keys its days with.
    private static var calendar: Calendar { .current }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        return formatter
    }()

    /// Every day on the grid, worked out once per draw: `days[week][weekday]`, Sunday first.
    private struct Year {
        let today: Date
        let days: [[Date]]

        init(calendar: Calendar) {
            let today = calendar.startOfDay(for: Date())
            let weekday = calendar.component(.weekday, from: today)
            let thisSunday = calendar.date(byAdding: .day, value: 1 - weekday, to: today) ?? today
            let first = calendar.date(byAdding: .day, value: -7 * (DS.Material.heatWeeks - 1), to: thisSunday) ?? today
            self.today = today
            self.days = (0..<DS.Material.heatWeeks).map { week in
                (0..<7).map { day in calendar.date(byAdding: .day, value: week * 7 + day, to: first) ?? first }
            }
        }
    }

    private var size: CGFloat {
        let weeks = CGFloat(DS.Material.heatWeeks)
        let room = width - DS.Material.heatDayLabelWidth - DS.Material.heatGap * weeks
        return max(DS.Material.heatSquareMin, min(DS.Material.heatSquareMax, (room / weeks).rounded(.down)))
    }

    var body: some View {
        let year = Year(calendar: Self.calendar)
        let yearWords = insights.days.filter { $0.key >= year.days[0][0] }.reduce(0) { $0 + $1.value.words }
        let weekWords = insights.days.filter { $0.key >= year.days[DS.Material.heatWeeks - 1][0] }.reduce(0) { $0 + $1.value.words }
        let average = insights.averageDay()
        Card {
            VStack(alignment: .leading, spacing: DS.Space.roomy) {
                HStack(alignment: .firstTextBaseline) {
                    // Time saved leads here (21 Oct 2026, pointer 2); before there is any,
                    // the year's words.
                    Text(average.savedMinutes > 0
                         ? "Every day, SigmaFlow gives you about \(Self.minutes(average.savedMinutes)) back"
                         : "\(yearWords.formatted()) words in the last year")
                        .font(DS.Font.insightSentence)
                        .foregroundStyle(DS.Color.ink)
                    Spacer(minLength: DS.Space.wide)
                    Text("\(weekWords.formatted()) words this week")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.dim)
                }
                if average.savedMinutes > 0 {
                    // How it is worked out, in plain words (pointer 5); the three numbers add up.
                    Text("Typing the \(average.words.formatted()) words SigmaFlow writes on an average day takes \(Self.about(average.typingMinutes)). Saying them takes \(Self.about(average.talkingMinutes, short: true)). The other \(average.savedMinutes) are yours.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: DS.Space.measureTiles, alignment: .leading)
                }
                // The room is read off an empty strip the grid can't push wider, so the
                // squares' size never feeds back into the width it came from.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                grid(year)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topLeading) { HoverTip(spot: tip, width: width) }
                HStack(spacing: DS.Material.heatGap) {
                    Spacer()
                    Text("Less").padding(.trailing, DS.Space.tight)
                    ForEach(0...DS.Color.heatLevels.count, id: \.self) { level in
                        Square(color: Self.color(level: level), size: DS.Material.heatSquareMax)
                    }
                    Text("More").padding(.leading, DS.Space.tight)
                }
                .font(DS.Font.insightAxis)
                .foregroundStyle(DS.Color.dim)
            }
            .padding(DS.Space.roomy)
        }
    }

    private func grid(_ year: Year) -> some View {
        let size = size
        let gap = DS.Material.heatGap
        return HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .leading, spacing: gap) {
                Color.clear.frame(height: DS.Material.heatMonthRow)
                ForEach(0..<7, id: \.self) { day in
                    Text(day % 2 == 1 ? Self.dayFormatter.shortWeekdaySymbols[day] : "")
                        .frame(height: size)
                }
            }
            .frame(width: DS.Material.heatDayLabelWidth - gap, alignment: .leading)
            ForEach(0..<DS.Material.heatWeeks, id: \.self) { week in
                VStack(spacing: gap) {
                    Text(monthLabel(year.days[week][0], week: week))
                        .fixedSize()
                        .frame(width: size, height: DS.Material.heatMonthRow, alignment: .leading)
                    ForEach(0..<7, id: \.self) { day in
                        square(year, week: week, day: day, size: size)
                    }
                }
            }
        }
        .font(DS.Font.insightAxis)
        .foregroundStyle(DS.Color.dim)
    }

    /// A month's name over the first column that starts in it; never over the last column,
    /// where it would run off the card.
    private func monthLabel(_ sunday: Date, week: Int) -> String {
        guard week < DS.Material.heatWeeks - 1, Self.calendar.component(.day, from: sunday) <= 7 else { return "" }
        return Self.monthFormatter.string(from: sunday)
    }

    @ViewBuilder
    private func square(_ year: Year, week: Int, day: Int, size: CGFloat) -> some View {
        let date = year.days[week][day]
        let today = year.today
        if date > today {
            Color.clear.frame(width: size, height: size)
        } else {
            let usage = insights.days[date] ?? UsageInsights.Day()
            Square(color: Self.color(level: Self.level(words: usage.words)), size: size)
                .onHover { inside in
                    if inside {
                        let gap = DS.Material.heatGap
                        tip = HoverTip.Spot(
                            text: tipText(date: date, usage: usage, today: today),
                            x: DS.Material.heatDayLabelWidth + CGFloat(week) * (size + gap) + size / 2,
                            y: DS.Material.heatMonthRow + gap + CGFloat(day) * (size + gap))
                    } else if tip?.text == tipText(date: date, usage: usage, today: today) {
                        tip = nil
                    }
                }
        }
    }

    private func tipText(date: Date, usage: UsageInsights.Day, today: Date) -> String {
        let when = Self.dayFormatter.string(from: date) + (date == today ? " so far" : "")
        guard usage.words > 0 else { return "No words on \(when)" }
        return "\(usage.words.formatted()) words, \(Self.duration(usage.savedMinutes)) saved on \(when)"
    }

    /// "27 minutes", "a minute".
    private static func minutes(_ count: Int) -> String {
        count == 1 ? "a minute" : "\(count) minutes"
    }

    /// "about 49 minutes", or with `short` just "about 22", after a figure already in minutes.
    private static func about(_ count: Int, short: Bool = false) -> String {
        if count < 1 { return "under a minute" }
        if short { return "about \(count)" }
        return "about " + minutes(count)
    }

    /// "1 h 12 min", "40 min".
    private static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        guard total >= 60 else { return "\(total) min" }
        return "\(total / 60) h" + (total % 60 > 0 ? " \(total % 60) min" : "")
    }

    private static func level(words: Int) -> Int {
        guard words > 0 else { return 0 }
        return 1 + DS.Material.heatThresholds.filter { words >= $0 }.count
    }

    private static func color(level: Int) -> Color {
        level == 0 ? DS.Color.heatEmpty : DS.Color.heatLevels[level - 1]
    }
}

private struct Square: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Material.heatRadius)
            .fill(color)
            .overlay(RoundedRectangle(cornerRadius: DS.Material.heatRadius).strokeBorder(DS.Color.heatEdge, lineWidth: DS.Border.hairline))
            .frame(width: size, height: size)
    }
}

// MARK: - The bookcase

/// Famous books on shelves, short to long, covers turned a little so the spine shows. All
/// in black and white; the books the user's words are at least as long as read clearly,
/// the longer ones sit back in the dark. Pointing at a book lifts it to face you and names
/// its length, nothing more.
private struct Bookshelf: View {
    let insights: UsageInsights

    @State private var width: CGFloat = 0
    @State private var lifted: String?
    @State private var tip: HoverTip.Spot?

    private var perShelf: Int {
        let room = width - 2 * DS.Material.shelfPadX + DS.Material.bookGap
        return max(1, Int(room / (DS.Material.bookWidth + DS.Material.bookGap)))
    }

    /// The gap that spreads a full shelf across the card; never tighter than `bookGap`.
    private var gap: CGFloat {
        let count = CGFloat(perShelf)
        guard count > 1 else { return DS.Material.bookGap }
        // Rounded down and a point short, so a full shelf is never wider than the width it
        // was measured from; a hair over would widen the card and measure again, forever.
        let room = width - 2 * DS.Material.shelfPadX - count * DS.Material.bookWidth - DS.Border.hairline
        return max(DS.Material.bookGap, (room / (count - 1)).rounded(.down))
    }

    private var shelves: [[FamousBook]] {
        let books = FamousBook.all
        return stride(from: 0, to: books.count, by: perShelf).map { Array(books[$0..<min($0 + perShelf, books.count)]) }
    }

    private var shelfHeight: CGFloat { DS.Material.shelfTop + DS.Material.bookHeight + DS.Material.plankHeight }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.roomy) {
                Eyebrow("Your words, written down")
                Text(sentence)
                    .font(DS.Font.insightSentence)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DS.Space.measureTiles, alignment: .leading)
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                VStack(spacing: DS.Material.shelfGap) {
                    ForEach(Array(shelves.enumerated()), id: \.offset) { row, books in
                        shelf(row: row, books: books)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) { HoverTip(spot: tip, width: width) }
            }
            .padding(DS.Space.roomy)
        }
    }

    private func shelf(row: Int, books: [FamousBook]) -> some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(DS.Color.plank)
                .frame(height: DS.Material.plankHeight)
                .overlay(alignment: .top) { Rectangle().fill(DS.Color.plankEdge).frame(height: DS.Border.hairline) }
                .shadow(color: DS.Color.shelfShadow, radius: DS.Material.plankShadowBlur, y: DS.Material.plankShadowY)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(books.enumerated()), id: \.element.id) { column, book in
                    BookView(book: book, isAhead: book.words > insights.words, isLifted: lifted == book.id)
                        .zIndex(lifted == book.id ? 1 : 0)
                        .onHover { inside in
                            withAnimation(DS.Motion.bookLift) {
                                if inside {
                                    lifted = book.id
                                } else if lifted == book.id {
                                    lifted = nil
                                }
                            }
                            if inside {
                                tip = HoverTip.Spot(
                                    text: "\(book.title), \(book.words.formatted()) words",
                                    x: DS.Material.shelfPadX + CGFloat(column) * (DS.Material.bookWidth + gap) + DS.Material.bookWidth / 2,
                                    y: CGFloat(row) * (shelfHeight + DS.Material.shelfGap) + DS.Material.shelfTop - DS.Material.bookLift)
                            } else if tip?.text.hasPrefix(book.title + ",") == true {
                                tip = nil
                            }
                        }
                }
            }
            // No Spacer to push a short shelf left: it would add one more gap to a full
            // shelf, the window would widen to fit it, and the gap would grow with it.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Material.shelfPadX)
            .padding(.top, DS.Material.shelfTop)
            .padding(.bottom, DS.Material.plankHeight)
        }
        .frame(height: shelfHeight)
    }

    /// The all-time numbers live here (21 Oct 2026, pointers 1 and 4): every word SigmaFlow
    /// has written and every dictation, as a page count and the longest famous book as long.
    private var sentence: String {
        let words = insights.words.formatted()
        let runs = insights.dictations == 1 ? "1 dictation" : "\(insights.dictations.formatted()) dictations"
        let pages = insights.pages
        let lead = "SigmaFlow has written \(words) words for you, in \(runs)."
        guard let book = insights.longestBookPassed else {
            return lead + (pages == 1 ? " That\u{2019}s a page." : " That\u{2019}s \(pages.formatted()) pages.")
        }
        return lead + " That\u{2019}s \(Self.article(pages)) \(pages.formatted())-page book, as long as \(book.title)."
    }

    /// "an 8-page book", "an 11-page book", "a 336-page book".
    private static func article(_ number: Int) -> String {
        var leading = number
        while leading >= 1000 { leading /= 1000 }
        let spokenWithVowel = String(leading).hasPrefix("8") || leading == 11 || leading == 18
        return spokenWithVowel ? "an" : "a"
    }
}

private struct BookView: View {
    let book: FamousBook
    let isAhead: Bool
    let isLifted: Bool

    @Environment(\.isSnapshotting) private var isSnapshotting

    private var spine: CGFloat {
        DS.Material.spineBase + DS.Material.spinePerThousandRoot * sqrt(CGFloat(book.words) / 1000)
    }

    var body: some View {
        let turn = isLifted ? 0 : DS.Material.bookTurn
        ZStack(alignment: .leading) {
            cover
                .rotation3DEffect(.degrees(turn), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: DS.Material.bookPerspective)
            // The spine stands at the cover's left edge and runs back from it, so turning the
            // book brings it round into view.
            spineFace
                .rotation3DEffect(.degrees(turn - 90), axis: (x: 0, y: 1, z: 0), anchor: .trailing, perspective: DS.Material.bookPerspective)
                .offset(x: -spine)
        }
        .frame(width: DS.Material.bookWidth, height: DS.Material.bookHeight)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(DS.Color.shelfShadow)
                .frame(height: DS.Material.bookShadowHeight)
                .blur(radius: DS.Material.bookShadowBlur)
                .offset(y: DS.Material.bookShadowHeight / 2)
        }
        .scaleEffect(isLifted ? DS.Material.bookLiftScale : 1, anchor: .bottom)
        .offset(y: isLifted ? -DS.Material.bookLift : 0)
    }

    private var cover: some View {
        art
            .frame(width: DS.Material.bookWidth, height: DS.Material.bookHeight)
            .clipped()
            .overlay(isAhead ? DS.Color.bookAheadShade : Color.clear)
    }

    /// The cover's own left edge, darkened: reads as the spine without a colour of its own.
    private var spineFace: some View {
        art
            .frame(width: DS.Material.bookWidth, height: DS.Material.bookHeight, alignment: .leading)
            .frame(width: spine, alignment: .leading)
            .clipped()
            .overlay(DS.Color.spineShade)
            .overlay(isAhead ? DS.Color.bookAheadShade : Color.clear)
    }

    @ViewBuilder
    private var art: some View {
        if let image = BookCovers.image(book.cover) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .grayscale(1)
        } else {
            DS.Color.gray300
        }
    }
}

/// The covers in Resources/BookCovers, read once each.
@MainActor
private enum BookCovers {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let image = cache[name] { return image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "BookCovers"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}

// MARK: - Hover label

/// A small label above whatever the pointer is on, kept inside the card's width.
private struct HoverTip: View {
    struct Spot: Equatable {
        let text: String
        /// The centre of the thing pointed at, and its top, in the overlaid view's space.
        let x: CGFloat
        let y: CGFloat
    }

    let spot: Spot?
    let width: CGFloat

    @State private var size: CGSize = .zero

    var body: some View {
        if let spot {
            Text(spot.text)
                .font(DS.Font.insightTip)
                .foregroundStyle(DS.Color.ink)
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.tight + DS.Space.hair)
                .background(DS.Color.tipFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .offset(
                    x: max(0, min(width - size.width, spot.x - size.width / 2)),
                    y: spot.y - size.height - DS.Space.snug)
                .allowsHitTesting(false)
        }
    }
}
