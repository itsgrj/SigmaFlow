import SigmaFlowDictionary
import AppKit
import SwiftUI

/// Transcriptions, to Figma window 20: everything dictated, newest first, grouped by day
/// inside one card. Search above, Copy and Delete on every row. A second tab, Insights,
/// shows how much has been said (`InsightsView`, 18 Oct 2026, 01 and 09 A).
///
/// Copy flips to "Copied" in place for a moment; nothing pops up. Deleting one row needs no
/// question. Deleting several works as on Meetings (docs/mockups/delete-recordings.html,
/// round 2): faint text fixed under the rows turns tick boxes on, Select all stands in for
/// the old Delete all, it stops at `DeleteQuestionView`, and the footer offers Undo for
/// `DS.Motion.undoHold`.
struct TranscriptionsPage: View {
    @Bindable var controller: DictationController

    @State private var store = RunStore.shared
    @State private var settings = Settings.shared
    @State private var query = ""
    @State private var isPicking = false
    @State private var ticked: Set<UUID> = []
    @State private var question: DeleteQuestion?
    @Environment(\.isSnapshotting) private var isSnapshotting

    enum Tab: String { case history, insights }

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: settings.openTabs["transcriptions"] ?? "") ?? .history },
            set: { settings.openTabs["transcriptions"] = $0.rawValue }
        )
    }

    private var runs: [DictationRun] {
        var all = store.runs.reversed().map { $0 }
        // The offscreen snapshot shows a page's worth, like the Figma window.
        if isSnapshotting { all = Array(all.prefix(DS.Material.snapshotRows)) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.text.localizedStandardContains(trimmed) }
    }

    /// Newest day first, each day's runs newest first.
    private var days: [(label: String, runs: [DictationRun])] {
        var out: [(String, [DictationRun])] = []
        for run in runs {
            let label = Self.dayLabel(for: run.date)
            if let last = out.indices.last, out[last].0 == label {
                out[last].1.append(run)
            } else {
                out.append((label, [run]))
            }
        }
        return out.map { (label: $0.0, runs: $0.1) }
    }

    var body: some View {
        switch tab.wrappedValue {
        case .history: history
        case .insights: insights
        }
    }

    /// The title and the tabs, in the same place on both tabs.
    @ViewBuilder
    private var header: some View {
        PageHeader(
            "Transcriptions",
            subtitle: "Everything you have dictated, newest first. Search it, copy a line back out, or delete what you no longer need."
        )
        TabStrip(tabs: [(.history, "History"), (.insights, "Insights")], selection: tab)
    }

    private var insights: some View {
        PageScroll {
            header
        } content: {
            if store.runs.isEmpty {
                Card {
                    EmptyCardBody(
                        "Nothing here yet",
                        detail: "Hold \(settings.pushToTalkKey.displayName) in any app and talk. When you let go, your words land where your cursor is, and a copy is kept here."
                    )
                }
            } else {
                InsightsView(insights: UsageInsights(runs: store.runs))
            }
        }
    }

    private var history: some View {
        ListPage {
            header
            ListToolbar(query: $query, placeholder: "Search transcriptions", count: countLabel)
            Card {
                if store.runs.isEmpty {
                    EmptyCardBody(
                        "Nothing here yet",
                        detail: "Hold \(settings.pushToTalkKey.displayName) in any app and talk. When you let go, your words land where your cursor is, and a copy is kept here."
                    )
                } else if runs.isEmpty {
                    EmptyCardBody("Nothing matches that search", detail: "Try fewer words, or a different spelling.")
                } else {
                    CardScroll { list }
                }
            } footer: {
                footer
            }
        }
        .overlay {
            if let question {
                DeleteQuestionView(
                    question: question, noun: "transcription",
                    onCancel: { self.question = nil },
                    onDelete: { answer(question) })
            }
        }
        .onExitCommand { if question == nil { stopPicking() } }
        .onDisappear { stopPicking() }
    }

    private func answer(_ question: DeleteQuestion) {
        self.question = nil
        if case .transcriptions(let chosen) = question.subject {
            withAnimation(DS.Motion.panel) { store.delete(chosen) }
        }
        stopPicking()
    }

    private func stopPicking() {
        isPicking = false
        ticked = []
    }

    /// The ticked runs still in the history, newest first.
    private var tickedRuns: [DictationRun] { store.runs.reversed().filter { ticked.contains($0.id) } }

    private var countLabel: String {
        let count = store.runs.count
        return "\(count.formatted()) recording\(count == 1 ? "" : "s")"
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            let groups = days
            ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, day in
                DayLabel(text: day.label)
                ForEach(Array(day.runs.enumerated()), id: \.element.id) { runIndex, run in
                    let isLast = groupIndex == groups.count - 1 && runIndex == day.runs.count - 1
                    TranscriptionRow(
                        run: run,
                        onDelete: { withAnimation(DS.Motion.panel) { store.delete([run]) } },
                        pick: isPicking
                            ? TranscriptionRow.Pick(isTicked: ticked.contains(run.id), anyTicked: !ticked.isEmpty) {
                                if ticked.contains(run.id) { ticked.remove(run.id) } else { ticked.insert(run.id) }
                            }
                            : nil)
                    if !isLast { CardDivider() }
                }
            }
        }
    }

    /// While ticking: how many, Select all, Cancel and Delete. Just after a delete: what
    /// went, and Undo. Otherwise the faint way in, fixed under the rows so no scrolling
    /// finds it (Gokul, 18 Oct 2026). The Dictations folder's path stays at the left through
    /// all three, as on Meetings (27 Oct 2026).
    @ViewBuilder
    private var footer: some View {
        if isPicking {
            let count = ticked.count
            let shown = runs
            CardFooter(hint: count == 0 ? "Tick the transcriptions to delete" : "\(count.formatted()) selected") {
                folderPath
            } actions: {
                if !shown.allSatisfy({ ticked.contains($0.id) }) {
                    AppButton(title: "Select all", kind: .secondary) { ticked.formUnion(shown.map(\.id)) }
                }
                AppButton(title: "Cancel", kind: .secondary) { stopPicking() }
                AppButton(
                    title: count == 0 ? "Delete" : "Delete \(count.formatted())", kind: .secondary, icon: "trash-can",
                    isEnabled: count > 0
                ) {
                    question = DeleteQuestion(subject: .transcriptions(tickedRuns))
                }
            }
        } else if let deleted = store.lastDeleted {
            let count = deleted.runs.count
            CardFooter(hint: "\(count.formatted()) transcription\(count == 1 ? "" : "s") deleted") {
                folderPath
            } actions: {
                AppButton(title: "Undo", kind: .secondary) { store.undoDelete() }
            }
        } else if !store.runs.isEmpty {
            FaintDelete(title: "Delete transcriptions") {
                folderPath
            } action: {
                isPicking = true
            }
        }
    }

    @ViewBuilder
    private var folderPath: some View {
        if let folder = RunLog.dictationsFolder { PathBar(folder: folder) }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    private static let dayWithYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    private static func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return dayFormatter.string(from: date)
        }
        return dayWithYearFormatter.string(from: date)
    }
}

// MARK: - Row

private struct TranscriptionRow: View {
    let run: DictationRun
    let onDelete: () -> Void
    /// Set while deleting several: the row takes a tick box, and a click ticks it.
    var pick: Pick? = nil

    struct Pick {
        let isTicked: Bool
        /// Once one row is ticked every row shows its box; until then only the one under
        /// the pointer does.
        let anyTicked: Bool
        let toggle: () -> Void
    }

    @State private var isHovering = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.roomy) {
            if let pick {
                // The box's room is kept while it is hidden, so lines don't shift as it shows.
                TickBox(isOn: pick.isTicked)
                    .opacity(pick.isTicked || pick.anyTicked || isHovering ? 1 : 0)
            }
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text(run.text)
                    .font(DS.Font.transcript)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)
                    // While ticking, a click on the words ticks the row instead of selecting.
                    .allowsHitTesting(pick == nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DS.Space.measureCaption, alignment: .leading)

                HStack(spacing: DS.Space.roomy) {
                    Text(Self.timeFormatter.string(from: run.date))
                    Text(run.engine)
                }
                .font(DS.Font.data)
                .foregroundStyle(DS.Color.inkSecondary)

                if let corrections = run.corrections, !corrections.isEmpty {
                    CorrectionLine(corrections: corrections)
                }
            }

            Spacer(minLength: 0)

            // While ticking, nothing on the row but its words and its box.
            if pick == nil {
                HStack(spacing: DS.Space.tight) {
                    CopyButton(text: run.text)
                    AppButton(title: "Delete", icon: "trash-can", action: onDelete)
                }
            }
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY)
        .background(pick?.isTicked == true ? DS.Color.selectedFill : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { pick?.toggle() }
        .onHover { isHovering = $0 }
    }
}

/// Shows that the dictionary fired, and on what: CORRECTED, the misheard form struck
/// through, the word that was typed instead.
private struct CorrectionLine: View {
    let corrections: [AppliedCorrection]

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Eyebrow("Corrected")
            ForEach(corrections, id: \.self) { correction in
                HStack(spacing: DS.Space.snug) {
                    Text(correction.from)
                        .strikethrough()
                    Text(correction.to)
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            }
        }
    }
}
