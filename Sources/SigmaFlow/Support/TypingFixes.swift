import AppKit
import Foundation
import SigmaFlowDictionary

// Fix spelling as you type, in the browser (docs/mockups/browser-autocorrect.html, picks 02 04
// 06 08, 16 Nov 2026). macOS fixes typos as you type in Mail, Notes and Messages; Chromium
// browsers don't. The extension sends the word you just finished (and the few words before it,
// for the language) through the same connection as everything else (BrowserBridge), and this
// answers with a fix or nothing. Nothing typed is kept or logged.
//
// The fix is the Mac's own: `NSSpellChecker.correction(forWordRange:)` is the call behind
// "Correct spelling automatically", and it knows the words this Mac has been taught. Your
// SigmaFlow dictionary goes on top: a word in it is right as typed, and a one-word rule in it
// (sigmaflow -> SigmaFlow) is the fix, but only for a word the Mac also finds wrong, so a rule
// learned from a mishearing ("there -> their") never rewrites a real word you typed.
//
// Delete straight after a fix puts your word back (the extension does that) and sends it here:
// it becomes a word in your Dictionary tagged LEARNED (pick 08), so it is never changed again,
// dictation hears it that way, and Delete all learned clears it with the rest.

@MainActor
enum TypingFixes {
    private static let tag = NSSpellChecker.uniqueSpellDocumentTag()
    /// Words taken back while learning is off: never changed again until SigmaFlow quits, and
    /// never written anywhere.
    private static var keptThisRun: Set<String> = []

    static let longestWord = 40
    static let longestText = 300

    /// The first answer from the spell checker takes about 60 ms; every one after, about 2.
    static func warm() {
        _ = suggestion(for: "teh", in: "teh")
    }

    /// The fix for `word`, the last word of `text`, when fixing is on.
    static func fix(word: String, in text: String) -> String? {
        guard Settings.shared.fixSpellingAsYouType else { return nil }
        return suggestion(for: word, in: text)
    }

    /// The fix whether or not the switch is on (for `--typing-check`).
    static func suggestion(for word: String, in text: String) -> String? {
        guard isCandidate(word), text.count <= longestText, text.hasSuffix(word) else { return nil }
        if keptThisRun.contains(word.lowercased()) { return nil }
        let entries = DictionaryStore.shared.entries.filter(\.isEnabled)
        if entries.contains(where: { same($0.write, word) }) { return nil }

        let checker = NSSpellChecker.shared
        if checker.hasLearnedWord(word) { return nil }
        let ns = text as NSString
        let range = NSRange(location: ns.length - (word as NSString).length, length: (word as NSString).length)
        let mac = checker.correction(forWordRange: range, in: text, language: checker.language(), inSpellDocumentWithTag: tag)

        if let rule = entries.first(where: { $0.kind == .correction && same($0.hear, word) }),
           rule.write != word, mac != nil || isMisspelled(range, in: text) {
            return rule.write
        }
        guard let mac, !mac.isEmpty, mac != word else { return nil }
        // Leave sentence case to the writer: "dont" at a sentence's start may come back as
        // "Don't", and a lowercase word typed mid-sentence must not gain a capital.
        if let typed = word.first, let fixed = mac.first, typed.isLowercase, fixed.isUppercase { return nil }
        return mac
    }

    /// A word you took back with Delete. Into the Dictionary as LEARNED while learning is on;
    /// otherwise only remembered until SigmaFlow quits.
    static func keep(_ word: String) {
        guard isCandidate(word) else { return }
        guard Settings.shared.learnFromCorrections else {
            keptThisRun.insert(word.lowercased())
            return
        }
        let store = DictionaryStore.shared
        if store.entries.contains(where: { same($0.write, word) }) { return }
        store.add(DictionaryEntry(kind: .term, write: word, learnedOn: Date()))
    }

    // MARK: Which words count

    /// Latin letters only, with apostrophes inside ("don't"), 2 to 40 of them. Never all
    /// capitals (an acronym), never a capital after a small letter (camelCase, iPhone-like
    /// names the person typed on purpose), never digits, and never Tamil or any other script.
    static func isCandidate(_ word: String) -> Bool {
        guard (2...longestWord).contains(word.count),
              word.range(of: #"^\p{Latin}+(?:['’]\p{Latin}+)*$"#, options: .regularExpression) != nil
        else { return false }
        let letters = word.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return false }
        var previous: Character?
        for character in letters {
            if let previous, previous.isLowercase, character.isUppercase { return false }
            previous = character
        }
        return true
    }

    private static func isMisspelled(_ range: NSRange, in text: String) -> Bool {
        let miss = NSSpellChecker.shared.checkSpelling(
            of: text, startingAt: range.location, language: nil, wrap: false,
            inSpellDocumentWithTag: tag, wordCount: nil)
        return miss.location == range.location && miss.length == range.length
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive]) == .orderedSame
    }
}

// MARK: - Checking it

/// `SigmaFlow --typing-check "TEXT" ["TEXT" ...]`: what the browser would get for the last word
/// of each text, with this Mac's dictionary and the saved SigmaFlow dictionary, whether or not
/// the switch is on. Prints and quits; nothing is learned.
enum TypingCheck {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--typing-check") else { return false }
        let texts = args[(index + 1)...].prefix { !$0.hasPrefix("--") }
        Task { @MainActor in
            TypingFixes.warm()
            for text in texts {
                let word = String(text.split(whereSeparator: \.isWhitespace).last ?? "")
                let start = Date()
                let fix = TypingFixes.suggestion(for: word, in: text)
                let ms = Date().timeIntervalSince(start) * 1000
                print("\(word) -> \(fix ?? "(left)")  \(String(format: "%.1f", ms)) ms")
            }
            exit(0)
        }
        return true
    }
}
