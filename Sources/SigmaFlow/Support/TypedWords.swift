import AppKit
import Carbon.HIToolbox
import Foundation

/// Words typed by hand, a count per day, for the Today's words tile on Insights
/// (docs/mockups/said-and-typed.html, round 3, 02; Gokul, 21 Oct 2026). Only the number is
/// kept, never what was typed: `typed-words.json` in the app's folder, `{"2026-10-21": 214}`.
///
/// The keys come from `HotkeyMonitor`'s tap, which already sees every key going down in
/// every app. macOS hides password fields from it (Secure Input), so they never count.
/// Counting starts the day this shipped; nothing from before can be recovered.
@MainActor
@Observable
final class TypedWords {
    static let shared = TypedWords()

    /// Set in `eventSourceUserData` on every key SigmaFlow presses itself (the paste, Power
    /// mode's Return, a style's ⌘C), so the tap knows them and they never count as typing.
    nonisolated static let ownEventMark: Int64 = 0x5349_474D_4146

    /// What one key going down does to the word being typed.
    enum Keystroke: Sendable {
        /// A letter or a digit: the word goes on.
        case letter
        /// A space, Return, Tab, an arrow, or a ⌘ or ⌃ shortcut: the word ends.
        case end
        /// Delete: a letter goes, or, just after a word ended, that word is taken back.
        case back
        /// Option-Delete: the whole word goes.
        case backWord
        case other
    }

    private(set) var days: [String: Int] = [:]
    /// Letters in the word being typed now. Not observed: Insights redraws per word, not per key.
    @ObservationIgnored private var letters = 0
    /// The last word counted, and whether nothing but its ending has come since: a Delete
    /// then is going back into it.
    @ObservationIgnored private var lastWordLetters = 0
    @ObservationIgnored private var justEnded = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let stored = try? JSONDecoder().decode([String: Int].self, from: data) {
            days = stored
        }
    }

    /// Typed so far today.
    var today: Int { stagedToday ?? days[Self.key(for: Date())] ?? 0 }
    /// Set only by `--readme-frames`: Insights shows this for today. Never saved.
    var stagedToday: Int?

    func note(_ key: Keystroke) {
        switch key {
        case .letter:
            letters += 1
            justEnded = false
        case .end:
            guard letters > 0 else { return }
            add(1)
            lastWordLetters = letters
            letters = 0
            justEnded = true
        case .back:
            if letters > 0 {
                letters -= 1
            } else if justEnded, lastWordLetters > 0 {
                // Back over the space and into the word just counted: it is uncounted, and
                // counts again when it ends again.
                add(-1)
                letters = lastWordLetters
                lastWordLetters = 0
                justEnded = false
            }
        case .backWord:
            if letters > 0 {
                letters = 0
            } else if justEnded, lastWordLetters > 0 {
                add(-1)
                lastWordLetters = 0
                justEnded = false
            }
        case .other:
            break
        }
    }

    /// Writes the counts now rather than after the pause; at quit.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? JSONEncoder.sorted.encode(days) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    private func add(_ words: Int) {
        let key = Self.key(for: Date())
        days[key] = max(0, (days[key] ?? 0) + words)
        // A word every second or two while someone types; the file is written once things
        // go quiet, not per word.
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Sorts a key going down into a `Keystroke`, from the plain values the tap reads.
    nonisolated static func keystroke(keyCode: Int64, flags: CGEventFlags, characters: String) -> Keystroke {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .end }
        switch Int(keyCode) {
        case kVK_Delete:
            return flags.contains(.maskAlternate) ? .backWord : .back
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return .end
        default:
            break
        }
        // Words end at spaces, as a dictation's words are counted: "it's" and "well-known"
        // are one word each, and punctuation neither starts nor ends one.
        guard let scalar = characters.unicodeScalars.first else { return .other }
        if CharacterSet.alphanumerics.contains(scalar) { return .letter }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return .end }
        return .other
    }

    private static var url: URL { RunLog.directory.appendingPathComponent("typed-words.json") }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func key(for date: Date) -> String { dayFormatter.string(from: date) }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}
