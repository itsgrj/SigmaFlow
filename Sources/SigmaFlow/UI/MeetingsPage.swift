import AppKit
import SwiftUI

/// Meetings, to docs/mockups/meetings-simple.html as picked on 13 Oct 2026 (1C 2A 3B 4A 5D
/// 6A): record a meeting, it is transcribed on this Mac the moment you stop, and both files
/// sit in a folder in SigmaFlow/Meetings. Nothing else, on purpose: every further feature is
/// its own ask (Gokul: "do the simplest thing beautifully").
///
/// The title, Record meeting and the search box stay put; only the list scrolls. A meeting
/// being recorded is the first row of the list, drawn with the overlay's own parts, and the
/// same row goes on to Transcribing and then Open transcript.
///
/// The same page is Conversations, live notes' home (docs/mockups/notes-home.html, Gokul's
/// picks 16 Oct 2026, 1B 2C): its own folder, Take notes and ⌃⌥N in place of Record meeting,
/// and each row's photos as three stacks before Open transcript.
///
/// Deleting is hard to find on purpose (docs/mockups/delete-recordings.html, round 2, picked
/// 16 Oct 2026; Gokul: "we should not make it very easy for users to delete anything").
/// Faint text at the very end of the list starts it; only then does a tick box show, on the
/// row under the pointer until one is ticked, then on every row (1B). Nothing on a row
/// deletes it (2C). Every delete stops at `DeleteQuestionView`, and the footer offers Undo
/// for a few seconds after (6B).
struct MeetingsPage: View {
    enum Kind {
        case meetings
        case conversations

        @MainActor var library: MeetingLibrary { self == .meetings ? .shared : .conversations }
        var title: String { self == .meetings ? "Meetings" : "Conversations" }
        var subtitle: String {
            self == .meetings
                ? "Record a meeting and read it back the moment it ends."
                : "Write down a conversation in the room as it happens."
        }
        /// "meeting", "conversation": the count and the empty card.
        var noun: String { self == .meetings ? "meeting" : "conversation" }
        /// The page's key in `Settings.openTabs` and in snapshot runs.
        var key: String { self == .meetings ? "meetings" : "conversations" }
    }

    let kind: Kind
    private let library: MeetingLibrary
    @State private var session = MeetingSession.shared
    @State private var notes = NotesSession.shared
    @State private var claude = ClaudeConnection.shared
    /// The photo stacks' random pick: new each time the page appears, still while you look.
    @State private var seed = UInt64.random(in: .min ... .max)
    @State private var query = ""
    @State private var openID: String?
    /// The transcript row to open at, when a search moment was clicked.
    @State private var openRow: Int?
    /// Search's answer, by meeting id, for `searched` (docs/mockups/picture-search.html).
    @State private var hits: [String: SearchHit] = [:]
    @State private var searched: String?
    /// Recordings showing all their moments after "N more".
    @State private var expanded: Set<String> = []
    /// A picture opened from search, large over the page.
    @State private var viewing: Viewing?

    private struct Viewing {
        let meeting: Meeting
        let moment: SearchMoment
    }
    /// The one row being renamed. Opening another closes it.
    @State private var renamingID: String?
    @State private var listHeight: CGFloat = 0
    /// A recording is being dragged over the list (Gokul, 15 Oct 2026, 1A).
    @State private var isDropTargeted = false
    /// Deleting several: tick boxes are out, and these are ticked.
    @State private var isPicking = false
    @State private var ticked: Set<String> = []
    /// The question every delete stops at, while it is open.
    @State private var question: DeleteQuestion?
    @Environment(\.isSnapshotting) private var isSnapshotting

    init(kind: Kind = .meetings) {
        self.kind = kind
        library = kind.library
        // `--snapshot-dir … --pages meetings/transcript` draws the newest meeting's transcript.
        // Only during a snapshot run: openTabs persists, and a normal launch must open the list.
        if CommandLine.arguments.contains("--snapshot-dir"), Settings.shared.openTabs[kind.key] == "transcript" {
            _openID = State(initialValue: kind.library.meetings.first?.id)
        }
    }

    /// A meeting being recorded shows on Meetings only; live notes have their card.
    private var isRecordingHere: Bool { kind == .meetings && session.isRecording }

    var body: some View {
        Group {
            if let openID, let meeting = library.meeting(openID) {
                MeetingTranscriptView(
                    meeting: meeting,
                    library: library,
                    backTitle: kind.title,
                    query: query,
                    focusRow: openRow,
                    onBack: {
                        self.openID = nil
                        self.openRow = nil
                    },
                    onRename: { self.openID = $0 },
                    onDelete: { question = DeleteQuestion(subject: .meetings([meeting])) },
                    onDeletePicture: { path, time, isScreenshot in
                        question = DeleteQuestion(subject: .picture(meeting, path: path, time: time, isScreenshot: isScreenshot))
                    },
                    isCovered: question != nil || viewing != nil)
            } else {
                list
            }
        }
        .overlay {
            if let question {
                DeleteQuestionView(
                    question: question, noun: kind.noun,
                    onCancel: { self.question = nil },
                    onDelete: { answer(question) })
            } else if let viewing, let path = viewing.moment.path {
                PictureViewer(
                    url: viewing.meeting.folder.appendingPathComponent(path),
                    caption: "\(MeetingNaming.stem(for: viewing.meeting.date)), \(MeetingNaming.clock(viewing.moment.start))",
                    onGo: {
                        self.viewing = nil
                        open(viewing.meeting, at: viewing.moment.row)
                    },
                    onClose: { self.viewing = nil })
            }
        }
        .onAppear {
            library.reload()
            seed = UInt64.random(in: .min ... .max)
            // The search model loads in the background, so the first search answers by meaning.
            if SearchEncoder.isDownloaded, !isSnapshotting { Task { await SearchEncoder.shared.warm() } }
        }
        .task(id: trimmedQuery) { await search(trimmedQuery) }
        .onDisappear { stopPicking() }
    }

    private func answer(_ question: DeleteQuestion) {
        self.question = nil
        switch question.subject {
        case .meetings(let meetings):
            library.delete(meetings)
            stopPicking()
            if let openID, meetings.contains(where: { $0.id == openID }) { self.openID = nil }
        case .picture(let meeting, let path, _, _):
            library.deletePicture(path, of: meeting)
        case .transcriptions:
            break
        }
    }

    private func stopPicking() {
        isPicking = false
        ticked = []
    }

    // MARK: Search

    /// The exact words at once; after a pause, by meaning too, once the model is loaded. A
    /// search typed before then answers by its words and starts the load for the next one.
    private func search(_ q: String) async {
        expanded = []
        guard !q.isEmpty else {
            hits = [:]
            searched = nil
            return
        }
        let meetings = library.meetings
        let exact = await SearchIndex.shared.search(q, vector: nil, meetings: meetings, folderName: library.folderName)
        guard !Task.isCancelled else { return }
        hits = exact
        searched = q
        try? await Task.sleep(for: .seconds(DS.Motion.searchPause))
        guard !Task.isCancelled else { return }
        guard await SearchEncoder.shared.isWarm else {
            if SearchEncoder.isDownloaded { Task { await SearchEncoder.shared.warm() } }
            return
        }
        guard let vector = try? await SearchEncoder.shared.query(q), !Task.isCancelled else { return }
        let found = await SearchIndex.shared.search(q, vector: vector, meetings: meetings, folderName: library.folderName)
        guard !Task.isCancelled else { return }
        hits = found
    }

    /// Search's answer for what is typed now, or nil while it is still being worked out.
    private var currentHits: [String: SearchHit]? {
        searched == trimmedQuery && !trimmedQuery.isEmpty ? hits : nil
    }

    private func open(_ meeting: Meeting, at row: Int?) {
        openRow = row
        openID = meeting.id
    }

    private func clicked(_ moment: SearchMoment, in meeting: Meeting) {
        if moment.path != nil {
            viewing = Viewing(meeting: meeting, moment: moment)
        } else {
            open(meeting, at: moment.row)
        }
    }

    /// The ticked meetings still on the list, newest first.
    private var tickedMeetings: [Meeting] { library.meetings.filter { ticked.contains($0.id) } }

    // MARK: The list page

    private var list: some View {
        VStack(alignment: .leading, spacing: DS.Space.sectionGap) {
            PageHeader(kind.title, subtitle: kind.subtitle) {
                if kind == .meetings { recordControl } else { notesControl }
            }
            VStack(alignment: .leading, spacing: DS.Space.base) {
                ListToolbar(query: $query, placeholder: "Search \(kind.noun)s", count: countLabel)
                if kind == .meetings, let error = session.lastError {
                    WarningLine(text: error)
                }
                ForEach(library.addErrors, id: \.self) { WarningLine(text: $0) }
            }
            Card { cardBody } footer: { footer }
                .overlay { if isDropTargeted { dropFrame } }
            // Until Claude Desktop has SigmaFlow: at the foot of the page, under the list
            // (docs/mockups/ask-claude.html, 1B 2A). Nothing when Claude isn't on this Mac.
            if claude.status != .connected, claude.status != .claudeNotInstalled {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: DS.Space.base) {
                    if case .failed(let message) = claude.status { WarningLine(text: message) }
                    ClaudeAskBar(noun: kind.noun) { claude.connect() }
                }
            }
        }
        .padding(.top, DS.Space.pageTop)
        .padding(.horizontal, DS.Space.pageSide)
        .padding(.bottom, DS.Space.pageBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Anywhere on the page takes the drop, the empty space under a short list included.
        .contentShape(Rectangle())
        // Dropped recordings are meetings; Conversations are what live notes wrote.
        .modifier(RecordingDrop(isEnabled: kind == .meetings && !isSnapshotting, isTargeted: $isDropTargeted) {
            library.add(recordings: $0)
        })
    }

    /// Record meeting, and the hotkey under it. While a meeting records the Stop button is
    /// in its row, so this steps aside without the header changing height.
    private var recordControl: some View {
        VStack(spacing: DS.Space.snug) {
            AppButton(title: "Record meeting", kind: .secondary, icon: "microphone") {
                session.start()
            }
            HStack(spacing: DS.Space.tight + DS.Space.hair) {
                Text("Press")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                KeyChip(text: "⌃⌥M")
            }
        }
        .opacity(session.isRecording ? 0 : 1)
        .disabled(session.isRecording)
    }

    /// Take notes, and its key under it, the way Record meeting sits on Meetings. While the
    /// notes card is open it steps aside; the card has the Stop.
    private var notesControl: some View {
        VStack(spacing: DS.Space.snug) {
            AppButton(title: "Take notes", kind: .secondary, icon: "camera") {
                notes.start()
            }
            HStack(spacing: DS.Space.tight + DS.Space.hair) {
                Text("Press")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                KeyChip(text: "⌃⌥N")
            }
        }
        .opacity(notes.isOpen ? 0 : 1)
        .disabled(notes.isOpen)
    }

    /// Over the list while a recording is dragged onto the page: a white edge and one line.
    private var dropFrame: some View {
        ZStack {
            DS.Color.dropVeil
            VStack(spacing: DS.Space.base) {
                CarbonIcon(name: "add", size: DS.Control.iconSize)
                Text("Drop to transcribe")
                    .font(DS.Font.transcript)
            }
            .foregroundStyle(DS.Color.ink)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.ink, lineWidth: DS.Border.hairline))
        .allowsHitTesting(false)
    }

    /// While ticking: how many, Cancel and Delete. Just after a delete: what went, and Undo.
    /// Otherwise the faint way in to deleting, fixed under the rows so no scrolling finds it
    /// (Gokul, 18 Oct 2026).
    @ViewBuilder
    private var footer: some View {
        if isPicking {
            let count = tickedMeetings.count
            CardFooter(hint: count == 0 ? "Tick the \(kind.noun)s to delete" : "\(count.formatted()) selected") {
                AppButton(title: "Cancel", kind: .secondary) { stopPicking() }
                AppButton(
                    title: count == 0 ? "Delete" : "Delete \(count.formatted())", kind: .secondary, icon: "trash-can",
                    isEnabled: count > 0
                ) {
                    question = DeleteQuestion(subject: .meetings(tickedMeetings))
                }
            }
        } else if let deleted = library.lastDeleted {
            CardFooter(hint: "\(deleted.label) deleted") {
                AppButton(title: "Undo", kind: .secondary) { library.undoDelete() }
            }
        } else if !library.meetings.isEmpty, !library.isFolderMissing {
            FaintDelete(title: "Delete \(kind.noun)s") {
                renamingID = nil
                isPicking = true
            }
        }
    }

    private var countLabel: String {
        let count = library.meetings.count
        return "\(count.formatted()) \(kind.noun)\(count == 1 ? "" : "s")"
    }

    // MARK: Card

    @ViewBuilder
    private var cardBody: some View {
        if library.isFolderMissing {
            EmptyCardBody(
                "Can't find your \(kind.noun)s",
                detail: "Show SigmaFlow where they are now."
            ) {
                AppButton(title: "Find it", kind: .secondary) { library.pickFolder() }
            }
        } else if library.meetings.isEmpty && !isRecordingHere && library.adding.isEmpty {
            // Hidden, not removed, under the drop frame: the card keeps its height and the
            // two lines never show through "Drop to transcribe".
            EmptyCardBody(
                "No \(kind.noun)s yet",
                detail: kind == .meetings ? "Press Record meeting, or drop a recording here." : "Press Take notes to start."
            )
            .opacity(isDropTargeted ? 0 : 1)
        } else if groups.isEmpty {
            EmptyCardBody(
                "Nothing matches that search",
                detail: "Try another word."
            )
        } else if isSnapshotting {
            // The offscreen renderer cannot draw a scroll view's content.
            rows
        } else {
            ScrollView {
                rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollEdgeFade()
            // As tall as the rows, never taller than the room left: a short list ends where
            // its rows end, a long one scrolls inside the card.
            .frame(maxHeight: listHeight > 0 ? listHeight : nil)
        }
    }

    private enum Item: Identifiable {
        case recording(Date)
        case adding(MeetingLibrary.Adding)
        case meeting(Meeting)

        var id: String {
            switch self {
            case .recording: "recording"
            case .adding(let item): item.id.uuidString
            case .meeting(let meeting): meeting.id
            }
        }

        var date: Date {
            switch self {
            case .recording(let date): date
            case .adding(let item): item.date
            case .meeting(let meeting): meeting.date
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Month groups, newest first; the meeting being recorded, if any, at the very top.
    private var groups: [(label: String, items: [Item])] {
        var items: [Item] = []
        if isRecordingHere, let started = session.startedAt { items.append(.recording(started)) }
        // Dropped recordings still being copied, newest drop first, like the meetings below.
        items += library.adding.reversed().map { .adding($0) }
        let q = trimmedQuery
        let found = currentHits
        for meeting in library.meetings {
            // Search's answer once it is in; until then, the words as typed.
            let matches = q.isEmpty
                || found.map { $0[meeting.id] != nil }
                ?? (meeting.name.localizedStandardContains(q) || meeting.spokenText.localizedStandardContains(q))
            if matches { items.append(.meeting(meeting)) }
        }
        if isSnapshotting { items = Array(items.prefix(DS.Material.snapshotRows)) }

        var out: [(String, [Item])] = []
        for item in items {
            let label = Self.monthFormatter.string(from: item.date)
            if let last = out.indices.last, out[last].0 == label {
                out[last].1.append(item)
            } else {
                out.append((label, [item]))
            }
        }
        return out.map { (label: $0.0, items: $0.1) }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            let all = groups
            ForEach(Array(all.enumerated()), id: \.offset) { groupIndex, group in
                DayLabel(text: group.label)
                ForEach(Array(group.items.enumerated()), id: \.element.id) { itemIndex, item in
                    switch item {
                    case .recording(let started):
                        RecordingRow(session: session, started: started)
                    case .adding(let item):
                        AddingRow(item: item)
                    case .meeting(let meeting):
                        let hit = currentHits?[meeting.id]
                        MeetingRow(
                            meeting: meeting,
                            photos: kind == .conversations ? meeting.photos : [],
                            seed: seed,
                            // Its moments say where the words are; the old line is for before they come.
                            query: hit?.moments.isEmpty == false ? "" : trimmedQuery,
                            progress: library.progress[meeting.id],
                            failure: library.failures[meeting.id],
                            onOpen: { open(meeting, at: nil) },
                            onRetry: { library.transcribe(meeting) },
                            onRename: { library.rename(meeting, title: $0) },
                            renamingID: $renamingID,
                            pick: isPicking
                                ? MeetingRow.Pick(isTicked: ticked.contains(meeting.id), anyTicked: !ticked.isEmpty) {
                                    if ticked.contains(meeting.id) { ticked.remove(meeting.id) } else { ticked.insert(meeting.id) }
                                }
                                : nil)
                        if let hit, !hit.moments.isEmpty, !isPicking {
                            moments(hit, of: meeting)
                        }
                    }
                    let isLast = groupIndex == all.count - 1 && itemIndex == group.items.count - 1
                    if !isLast { CardDivider() }
                }
            }
        }
    }

    /// Up to three moments under the row, then "N more", which shows the rest in place (01 B).
    @ViewBuilder
    private func moments(_ hit: SearchHit, of meeting: Meeting) -> some View {
        let isOpen = expanded.contains(meeting.id)
        VStack(spacing: 0) {
            ForEach(isOpen ? hit.all : hit.moments) { moment in
                MomentRow(moment: moment, folder: meeting.folder, query: trimmedQuery) { clicked(moment, in: meeting) }
            }
            if !isOpen, hit.total > hit.moments.count {
                MoreMomentsRow(count: hit.total - hit.moments.count, noun: kind.noun) { expanded.insert(meeting.id) }
            }
        }
        .padding(.bottom, DS.Material.momentPadY)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    /// `~/SigmaFlow` rather than `/Users/grj/SigmaFlow`.
    static func displayPath(_ path: String?) -> String {
        guard let path else { return "your home folder" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Recordings dragged from Finder. Left off in a snapshot run: the offscreen renderer
/// draws a drop target as its "unsupported" stand-in over the whole page.
private struct RecordingDrop: ViewModifier {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                onDrop(files)
                return true
            } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

// MARK: - Rows

/// The meeting being recorded: its name so far, and the overlay's status row (the steady
/// dot, REC, the timer, the green dots) with Stop beside it.
private struct RecordingRow: View {
    let session: MeetingSession
    let started: Date

    var body: some View {
        HStack(spacing: DS.Space.roomy) {
            VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                Text(MeetingNaming.stem(for: started))
                    .lineLimit(1)
                    .font(DS.Font.transcript)
                    .foregroundStyle(DS.Color.ink)
                Text("Recording")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: DS.Space.roomy - DS.Space.hair) {
                HStack(spacing: DS.Space.snug) {
                    HUDGlyph(kind: .dot)
                    Eyebrow("Rec", color: DS.Color.ink)
                }
                .fixedSize()
                Readout(text: MeetingNaming.clock(session.elapsed))
                VUMeter(level: session.level, isActive: true)
                    .frame(width: VUMeter.naturalWidth, height: DS.Material.meterDotSize * 2)
                AppButton(title: "Stop", kind: .secondary, icon: "stop") { session.stop() }
            }
            // The controls never give way; a narrow window shortens the name instead.
            .fixedSize()
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY)
        .background(DS.Color.editorFill)
    }
}

/// A dropped recording being copied in. It reads as Transcribing from the first moment;
/// the meeting row that replaces it carries the same line on.
private struct AddingRow: View {
    let item: MeetingLibrary.Adding

    var body: some View {
        HStack(spacing: DS.Space.roomy) {
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(DS.Font.transcript)
                .foregroundStyle(DS.Color.ink)
            Spacer(minLength: 0)
            HStack(spacing: DS.Space.base) {
                Text("Transcribing")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                ProgressLine(fraction: item.fraction)
            }
            .fixedSize()
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    /// A conversation's camera photos, shown as stacks before the row's button.
    let photos: [URL]
    let seed: UInt64
    let query: String
    let progress: Double?
    let failure: String?
    let onOpen: () -> Void
    let onRetry: () -> Void
    let onRename: (String) -> Void
    @Binding var renamingID: String?
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

    /// A row being transcribed can't be deleted.
    private var canTick: Bool { pick != nil && !isTranscribing }

    private var isEditing: Bool {
        get { renamingID == meeting.id }
        nonmutating set { renamingID = newValue ? meeting.id : nil }
    }

    private var isTranscribing: Bool { progress != nil }

    var body: some View {
        HStack(spacing: DS.Space.roomy) {
            if let pick {
                // The box's room is kept while it is hidden, so names don't shift as it shows.
                TickBox(isOn: pick.isTicked)
                    .opacity(canTick && (pick.isTicked || pick.anyTicked || isHovering) ? 1 : 0)
            }
            VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                if isEditing {
                    RenameField(meeting: meeting, onSave: { title in
                        isEditing = false
                        onRename(title)
                    }, onCancel: { isEditing = false })
                } else {
                    HStack(spacing: DS.Space.snug) {
                        Text(meeting.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(DS.Font.transcript)
                            .foregroundStyle(DS.Color.ink)
                        AppButton(title: "", icon: "edit") { isEditing = true }
                            .opacity(isHovering && !isTranscribing && pick == nil ? 1 : 0)
                            .disabled(isTranscribing || pick != nil)
                    }
                }
                if let hit = searchHit {
                    Text(hit)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
            }
            .layoutPriority(isEditing ? 1 : 0)
            Spacer(minLength: 0)
            // The photos step aside while the name is typed: beside the field and the button
            // they made the row wider than the window, and the page with it (16 Oct 2026).
            if !photos.isEmpty, !isEditing {
                PhotoStacks(photos: photos, seed: seed)
            }
            // While ticking, nothing on the row but its name, its photos and its box.
            if pick == nil || isTranscribing {
                trailing
                    .fixedSize()
            }
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY)
        .background(pick?.isTicked == true ? DS.Color.selectedFill : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if canTick { pick?.toggle() } }
        .onHover { isHovering = $0 }
    }

    /// "Said in this meeting: “quiz”" when the match is in the words, not the name.
    private var searchHit: AttributedString? {
        guard !query.isEmpty, !meeting.name.localizedStandardContains(query),
              meeting.spokenText.localizedStandardContains(query) else { return nil }
        var said = AttributedString("Said in this meeting: ")
        var word = AttributedString("“\(query)”")
        word.foregroundColor = DS.Color.ink
        said.append(word)
        return said
    }

    @ViewBuilder
    private var trailing: some View {
        if let progress {
            HStack(spacing: DS.Space.base) {
                Text("Transcribing")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                ProgressLine(fraction: progress)
            }
        } else if !meeting.hasTranscript {
            HStack(spacing: DS.Space.base) {
                WarningLine(text: failure ?? "The transcript didn't finish.")
                AppButton(title: "Try again", kind: .secondary, icon: "renew", isEnabled: meeting.audioURL != nil, action: onRetry)
            }
        } else {
            AppButton(title: "Open transcript", trailingIcon: "arrow--right", action: onOpen)
        }
    }
}

/// Renaming in place. The date, time and length stay; what you type is added after them
/// (Gokul, 3B). Return saves, Esc cancels, an empty title takes it back to the plain name.
struct RenameField: View {
    let meeting: Meeting
    var font: Font = DS.Font.transcript
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        RenameLayout(spacing: DS.Space.snug) {
            Text(MeetingNaming.name(for: meeting.date, duration: meeting.duration) + " -")
                .font(font)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize()
            FormField(prompt: "Add a title", text: $draft) { onSave(draft) }
                .focused($isFocused)
            // The key as a chip, like ⌃⌥N under Take notes: "Return to save" read as go
            // back somewhere (Gokul, 16 Oct 2026). Offered no width, it falls to nothing.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.tight + DS.Space.hair) {
                    Text("Press")
                    KeyChip(text: "Return")
                    Text("to save")
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onExitCommand(perform: onCancel)
        .onAppear {
            draft = meeting.title ?? ""
            isFocused = true
        }
    }
}

/// The rename row: the date as it stands, the field, the hint. Never wider than it is
/// offered: beside Play, the photos or Open transcript, a fixed field and hint pushed the
/// page past the window's right margin (16 Oct 2026). The field is up to 300 pt and never
/// under 160; the hint shows only while the field keeps 200 beside it, and goes first.
private struct RenameLayout: Layout {
    let spacing: CGFloat

    private struct Widths { var prefix, field, hint: CGFloat }

    private func widths(_ offered: CGFloat?, _ subviews: Subviews) -> Widths {
        let prefix = subviews[0].sizeThatFits(.unspecified).width
        let hint = subviews[2].sizeThatFits(.unspecified).width
        let room = (offered ?? .infinity) - prefix - spacing
        let max = DS.Material.editorFieldWidth, min = DS.Material.renameFieldMinWidth
        if room - spacing - hint >= DS.Material.renameFieldWidthBesideHint {
            return Widths(prefix: prefix, field: Swift.min(max, room - spacing - hint), hint: hint)
        }
        return Widths(prefix: prefix, field: Swift.max(min, Swift.min(max, room)), hint: 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = widths(proposal.width, subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: w.prefix + spacing + w.field + (w.hint > 0 ? spacing + w.hint : 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(bounds.width, subviews)
        var x = bounds.minX
        for (view, width) in zip(subviews, [w.prefix, w.field, w.hint]) {
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }
}

/// A warning glyph and one line in secondary ink. Not a status line: those carry a green
/// check, and this is the opposite of done.
struct WarningLine: View {
    let text: String

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            CarbonIcon(name: "warning", size: DS.Control.iconSizeSmall)
                .foregroundStyle(DS.Color.inkSecondary)
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
        }
    }
}
