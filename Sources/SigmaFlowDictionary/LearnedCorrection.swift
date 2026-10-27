import Foundation

/// What SigmaFlow is willing to offer as a dictionary rule after watching the user edit
/// text it just typed.
///
/// The interesting half is what this *refuses*. Anything the user changes inside dictated
/// text is a candidate, but almost none of it is a mishearing: people fix their own wording,
/// swap a preposition, reach for a different verb. A rule made from one of those is applied
/// to every future dictation forever, and the user pays for it in the Dictionary page long
/// after they've forgotten the sentence that caused it. So a candidate has to look like the
/// engine getting a word wrong, not like the user changing their mind:
///
/// - **Two words at most, on each side.** Three-word runs are rewrites in practice.
/// - **Three characters at least.** `in` → `on` is grammar; no rule should carry it.
/// - **Nothing SigmaFlow would warn about if you typed it.** `DictionaryWarning` already
///   knows which triggers misfire — ordinary words like `there`, `cloud`, `team`, and
///   anything too short to be distinctive. A rule the app would talk you out of by hand is
///   not a rule it should propose on its own, so that check is reused verbatim.
/// - **No numbers.** `5` → `five` is a formatting taste, and cleanup's job.
/// - **It has to sound like the target.** Compared with spaces and case removed — so
///   `sigma flow` → `SigmaFlow` is a distance of zero, exactly the rule worth having — and
///   then held to a small edit distance. This is what separates `clode` → `Claude` from
///   `the meeting` → `our standup`.
///
/// Lives here, in the platform-neutral target, because it is pure string work and because
/// this is the part that needs to be tested: it is a heuristic, and a heuristic without
/// vectors drifts. The cases are in `dictionary-test-vectors.json` under `learningCases`.
public struct LearnedCorrection: Equatable, Sendable {
    /// The misheard form, as the engine wrote it. Lowercased; the rule matches any case.
    public let hear: String
    /// What it should have said, verbatim.
    public let write: String

    public init(hear: String, write: String) {
        self.hear = hear
        self.write = write
    }

    /// The rule worth offering for an edit from `before` to `after`, or nil when the change
    /// doesn't look like a mishearing being fixed.
    public static func propose(from before: String, to after: String) -> LearnedCorrection? {
        guard let change = changedPhrase(from: before, to: after), isMishearing(change) else {
            return nil
        }
        return change
    }

    /// Splits text the way the diff and the caller both need it.
    public static func words(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    // MARK: - The diff

    /// The single short run of words that differs between two texts: everything matching is
    /// peeled off both ends, and what's left in the middle is the change. Nil when nothing
    /// changed, when too much did, or when only punctuation and case moved.
    static func changedPhrase(from before: String, to after: String) -> LearnedCorrection? {
        let a = words(of: before), b = words(of: after)
        guard !a.isEmpty, !b.isEmpty else { return nil }

        var i = 0
        while i < a.count, i < b.count, key(a[i]) == key(b[i]) { i += 1 }
        var j = 0
        while j < a.count - i, j < b.count - i, key(a[a.count - 1 - j]) == key(b[b.count - 1 - j]) { j += 1 }

        let spoken = Array(a[i..<(a.count - j)])
        let written = Array(b[i..<(b.count - j)])
        guard (1...maxWords).contains(spoken.count), (1...maxWords).contains(written.count) else {
            return nil
        }

        let hear = clean(spoken.joined(separator: " ")).lowercased()
        let write = clean(written.joined(separator: " "))
        guard !hear.isEmpty, !write.isEmpty, hear != write.lowercased() else { return nil }
        return LearnedCorrection(hear: hear, write: write)
    }

    // MARK: - The shape test

    /// How many words a mishearing may span on either side. Two, so `sigma flow` still
    /// reaches `SigmaFlow`.
    private static let maxWords = 2
    /// Below this many characters a change is grammar, not a misheard word.
    private static let minLength = 3

    static func isMishearing(_ change: LearnedCorrection) -> Bool {
        let heard = compact(change.hear)
        let written = compact(change.write)
        guard heard.count >= minLength, written.count >= minLength else { return false }
        guard !heard.allSatisfy(\.isNumber), !written.allSatisfy(\.isNumber) else { return false }
        // The same test the UI runs on a rule the user types in. If it has anything to say
        // about this trigger, the rule is one the user should choose deliberately, not one
        // that arrives on its own.
        guard DictionaryWarning.check(
            DictionaryEntry(kind: .correction, write: change.write, hear: change.hear)
        ).isEmpty else { return false }
        return editDistance(heard, written) <= allowedDistance(max(heard.count, written.count))
    }

    /// Two edits for a short word — enough for `fone` → `phone` — and three once the word is
    /// long enough that two would be a coincidence.
    private static func allowedDistance(_ length: Int) -> Int {
        max(2, min(3, length / 3))
    }

    // MARK: - String work

    /// Comparison key: case-folded, trailing punctuation dropped, so "Friday." matches
    /// "friday".
    private static func key(_ word: String) -> String {
        clean(word).lowercased()
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()"))
    }

    /// Down to the sound of it: case, spaces and punctuation gone, so a rule that only
    /// joins or capitalises words scores as no change at all.
    private static func compact(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Levenshtein, two rows.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let substitution = previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
