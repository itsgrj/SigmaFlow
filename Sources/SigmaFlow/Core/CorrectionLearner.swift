import SigmaFlowDictionary
import AppKit
import ApplicationServices
import Foundation

/// Learns dictionary rules from what the user fixes after dictating.
///
/// Nobody remembers the exact string an engine mishears, so the Dictionary page alone
/// never captures the real mistakes. This does: after SigmaFlow types into a field, it
/// keeps reading that field for a short while. If the user changes one short phrase inside
/// what was inserted, that change becomes a rule: a card in the HUD says ADDING TO
/// DICTIONARY, a bar fills for a few seconds, and when it reaches the end the rule is in
/// the store. Not now stops it. Afterwards the card says ADDED with an Undo for a moment.
///
/// **Silence is yes.** Decided on 10 October 2026, reversing the September change that made
/// the notice ask first. It is bearable because the rule is visible (the LEARNED tag in the
/// Dictionary), reversible (Undo on the card, ⌥⌫, Delete all learned) and because the bar
/// holds while the pointer is over the card. If repeated undoing shows up again, the
/// default is wrong, not the timer: see docs/DESIGN-SPEC.md, section 3.
///
/// What counts as a candidate at all is `LearnedCorrection`, in the dictionary target,
/// where it can be tested: most of what a user changes in dictated text is their own
/// wording, and a rule made from that follows them forever.
///
/// The same watch keeps the saved transcript in step with the field (Gokul, 17 Oct 2026:
/// the history should hold what was corrected, not what first landed). Whenever an edit
/// settles, the words now standing where the dictation was replace that run's text in
/// `runs.jsonl`, rewording included, for as long as they are still recognisably the
/// dictation (`dictatedText`). That part runs whether or not learning is on.
///
/// Reading a field back is only possible where the app exposes its value through
/// Accessibility. Apple's own apps do; Electron and browsers mostly do not, and there the
/// learner simply never fires and the transcript stays as it was typed. It never reads
/// anything except the one field it just typed into, and it stops when the window closes
/// or the field can no longer be read.
@MainActor
final class CorrectionLearner {
    static let shared = CorrectionLearner()

    /// How long after insertion an edit can still become a rule.
    private let window: TimeInterval = 15
    /// How long after insertion an edit still reaches the saved transcript. Longer than the
    /// learning window: fixing a typo in a long message can take a while.
    private let followWindow: TimeInterval = 60
    /// How long the text must sit unchanged before a change counts as finished.
    private let settle: TimeInterval = 1.0
    /// Fields longer than this are documents, not messages; diffing them is a bad bet.
    private let maxLength = 20_000

    private var watchTask: Task<Void, Never>?
    private var notice: CorrectionNoticePanel?
    /// The rule on offer, built but not yet in the store.
    private var offered: DictionaryEntry?
    /// The rule the user accepted, for as long as undo still means something.
    private var lastLearned: DictionaryEntry?
    private var noticeTimer: Task<Void, Never>?

    private init() {}

    // MARK: - Watching

    /// Starts watching `element` for an edit to `inserted`. Any previous watch is dropped.
    /// An edit updates the saved run `run`, and, when `learn` is on, may offer a rule.
    func watch(_ element: AXUIElement, inserted: String, run: UUID?, learn: Bool) {
        stop()
        let insertedWords = LearnedCorrection.words(of: inserted)
        guard !insertedWords.isEmpty, run != nil || learn else { return }

        watchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Let the target app finish laying the text in before reading the baseline.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            // Autocorrect or smart quotes may have touched the tail; the opening words are
            // enough to prove the text landed in this field.
            let opening = insertedWords.prefix(4).joined(separator: " ")
            guard let baseline = TextInjector.stringValue(of: element),
                  baseline.count <= maxLength,
                  baseline.localizedCaseInsensitiveContains(opening)
            else {
                Log.inject.info("learner: field not readable, not watching")
                return
            }

            let start = Date()
            // Where the dictation sits: the text before it and after it. When the field
            // doesn't hold it word for word (autocorrect got there first), there is no
            // telling which words are ours, and the transcript is left as typed.
            let place = run == nil ? nil : Self.locate(inserted, in: baseline)
            var saved = inserted
            var learning = learn
            var last = baseline
            var changedAt: Date?

            while !Task.isCancelled, Date().timeIntervalSince(start) < followWindow {
                if !learning || Date().timeIntervalSince(start) >= window {
                    learning = false
                    if place == nil { return }
                }
                try? await Task.sleep(for: .milliseconds(400))
                guard let current = TextInjector.stringValue(of: element) else { return }
                if current != last {
                    last = current
                    changedAt = Date()
                    continue
                }
                guard let since = changedAt, Date().timeIntervalSince(since) >= settle else { continue }
                changedAt = nil
                // The edit has settled. The transcript takes what now stands in the
                // dictation's place; a sent message or a field cleared keeps the last of it.
                if let run, let place,
                   let edited = Self.dictatedText(in: current, at: place, original: inserted),
                   edited != saved {
                    saved = edited
                    RunLog.update(run, text: edited)
                    Log.inject.info("follow: transcript updated to the edited text")
                }
                // One misheard-looking phrase inside what we typed?
                if learning,
                   let fix = LearnedCorrection.propose(from: baseline, to: current),
                   inserted.localizedCaseInsensitiveContains(fix.hear) {
                    offer(fix)
                    learning = false
                }
                // Anything else (a rephrase, a deletion) is no rule; keep watching, so a
                // later single-word fix can still be caught.
            }
        }
    }

    // MARK: - Following the transcript

    /// The text on either side of the dictation in the field, which an edit inside the
    /// dictation leaves alone.
    struct Place {
        let before: String
        let after: String
    }

    /// Finds `inserted` in `field`; the last match, since it went in at the caret.
    static func locate(_ inserted: String, in field: String) -> Place? {
        guard let range = field.range(of: inserted, options: .backwards) else { return nil }
        return Place(before: String(field[..<range.lowerBound]), after: String(field[range.upperBound...]))
    }

    /// What stands in the dictation's place in `field` now, or nil when it can't be told or
    /// is no longer the dictation: text around it changed, it was emptied, most of its words
    /// are gone, or far more was typed than was said (a message carried on by hand).
    static func dictatedText(in field: String, at place: Place, original: String) -> String? {
        guard field.count >= place.before.count + place.after.count,
              field.hasPrefix(place.before), field.hasSuffix(place.after) else { return nil }
        let from = field.index(field.startIndex, offsetBy: place.before.count)
        let to = field.index(field.endIndex, offsetBy: -place.after.count)
        let text = field[from..<to].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let plain = { (s: String) in
            LearnedCorrection.words(of: s.lowercased()).map {
                $0.trimmingCharacters(in: .punctuationCharacters)
            }.filter { !$0.isEmpty }
        }
        let was = plain(original), now = plain(text)
        let kept = was.filter(Set(now).contains).count
        guard kept * 2 >= was.count,
              now.count <= was.count + max(3, was.count / 2)
        else { return nil }
        return text
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    // MARK: - Offering

    /// Builds the rule and puts it on screen with the bar filling. It reaches the store
    /// when the bar ends, in `accept()`.
    private func offer(_ change: LearnedCorrection) {
        // Never ask about a rule the user already has.
        guard !DictionaryStore.shared.entries.contains(where: {
            $0.kind == .correction && $0.hear.caseInsensitiveCompare(change.hear) == .orderedSame
        }) else { return }

        offered = DictionaryEntry(
            kind: .correction,
            write: change.write,
            hear: change.hear,
            learnedOn: Date()
        )
        Log.inject.info("learner: offering \(change.hear, privacy: .public) -> \(change.write, privacy: .public)")
        showNotice(change)
    }

    /// The bar reached the end. Now it is a rule; the card confirms it and offers Undo.
    private func accept() {
        // Nothing on offer means nothing to confirm; the card must still go, never sit
        // full on screen (it did, 10 to 16 Oct 2026, when `showNotice` cleared `offered`).
        guard let entry = offered else {
            dismissNotice()
            return
        }
        offered = nil
        DictionaryStore.shared.add(entry)
        lastLearned = entry
        Log.inject.info("learner: added \(entry.hear, privacy: .public) -> \(entry.write, privacy: .public)")
        notice?.showAdded()
    }

    /// Takes back a rule that was just added. Bound to the card's Undo and to ⌥⌫.
    /// - Returns: `true` when there was something to undo.
    @discardableResult
    func undo() -> Bool {
        guard let entry = lastLearned else { return false }
        DictionaryStore.shared.delete(entry)
        lastLearned = nil
        notice?.showUndone()
        return true
    }

    /// Whether undo means something, so ⌥⌫ is only swallowed while it does: a rule was
    /// added and its card is still up.
    var canUndo: Bool { lastLearned != nil && notice?.isVisible == true }

    // MARK: - Notice

    private func showNotice(_ change: LearnedCorrection) {
        // Take down a card still up from an earlier rule, but not through `dismissNotice`:
        // that also clears `offered`, which by now is this card's rule, and the bar would
        // fill with nothing to add.
        if let old = notice {
            notice = nil
            old.orderOut(nil)
        }
        lastLearned = nil
        let panel = CorrectionNoticePanel(
            spoken: change.hear,
            written: change.write,
            window: DS.Motion.noticeWindow,
            // The bar reached the end: silence is yes.
            onExpire: { [weak self] in self?.accept() },
            onUndo: { [weak self] in self?.undo() },
            // Not now, or a confirmation that has had its moment: the card goes. Whatever
            // was still on offer is dropped, an added rule stays, and ⌥⌫ stops meaning undo.
            onDecline: { [weak self] in
                self?.offered = nil
                self?.lastLearned = nil
                self?.dismissNotice()
            }
        )
        notice = panel
        noticeTimer?.cancel()
        noticeTimer = nil
        panel.present()
    }

    private func dismissNotice(now: Bool = false) {
        noticeTimer?.cancel()
        noticeTimer = nil
        offered = nil
        guard let notice else { return }
        self.notice = nil
        if now { notice.orderOut(nil) } else { notice.dismiss() }
    }

    // The diff and the test for whether a change looks like a mishearing at all live in
    // `LearnedCorrection`, in the platform-neutral dictionary target, so CI can gate them.
}
