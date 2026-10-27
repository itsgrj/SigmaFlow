import AppKit
import SwiftUI

/// One meeting's transcript, to docs/mockups/meetings-simple.html tab 02.
///
/// The name, Play and the column bar stay put; only the transcript scrolls, inside its card,
/// and a short meeting ends where its text ends. Copy (.md) and Download (.md) sit on the
/// transcript itself, the same width as each other. Nothing is downloaded: the .md is
/// already in its meeting folder, so Download shows it there in Finder.
///
/// Opened from a search, the searched word is underlined, the lines without it fall back,
/// and the transcript starts at the first match (Gokul, 5D).
///
/// Transcribe again sits on the bar beside the pair, as a ghost so it does not compete with
/// them, and redoes the meeting as English or as Tamil and English, replacing the .md
/// (docs/mockups/meeting-language.html, 1B 2B 3A 4B).
///
/// Deleting (docs/mockups/delete-recordings.html round 2): the whole meeting from faint text
/// after its last line, a photo or a screenshot from a faint bin on its larger view. Nothing
/// near the title or Play.
struct MeetingTranscriptView: View {
    let meeting: Meeting
    /// Meetings', or Conversations': where renames and Transcribe again happen.
    var library: MeetingLibrary = .shared
    /// The page the back button returns to.
    var backTitle = "Meetings"
    let query: String
    /// The row a search moment opened it at: scrolled to, and lightly filled while it is open
    /// (docs/mockups/picture-search.html, 03).
    var focusRow: Int? = nil
    let onBack: () -> Void
    let onRename: (String) -> Void
    /// Both ask first: the page opens the question.
    var onDelete: () -> Void = {}
    var onDeletePicture: (_ path: String, _ time: Double, _ isScreenshot: Bool) -> Void = { _, _, _ in }
    /// Something covers the transcript (a question, a picture opened large): a click there
    /// must not also play the line under it.
    var isCovered = false

    @State private var isEditing = false
    @State private var isHoveringTitle = false
    @State private var didCopy = false
    @State private var listHeight: CGFloat = 0
    @State private var player = MeetingPlayer.shared
    @State private var claude = ClaudeConnection.shared
    /// Ask Claude's questions are open under it (docs/mockups/ask-claude.html, 4C).
    @State private var isAsking = false
    @Environment(\.isSnapshotting) private var isSnapshotting

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// While a Transcribe again runs.
    private var redoProgress: Double? { library.progress[meeting.id] }

    /// A picture just deleted here, while Undo is offered: the rows as they were, so it
    /// keeps its place.
    private var removedPicture: MeetingLibrary.RemovedPicture? {
        library.lastPicture.flatMap { $0.meetingID == meeting.id ? $0 : nil }
    }

    private var shownLines: [MeetingLine] { removedPicture?.lines ?? meeting.lines }

    /// This meeting's audio is playing or paused part way.
    private var isLoaded: Bool { meeting.audioURL != nil && player.playing == meeting.audioURL }

    /// The line the sound is in: the last one starting at or before it, playing or paused
    /// (docs/mockups/conversation-playback.html, 3A).
    private var playingRow: Int? {
        guard isLoaded else { return nil }
        return shownLines.lastIndex { $0.start <= player.elapsed } ?? (shownLines.isEmpty ? nil : 0)
    }

    private func isHit(_ line: MeetingLine) -> Bool {
        !trimmedQuery.isEmpty && line.text.localizedCaseInsensitiveContains(trimmedQuery)
    }

    /// Lines without the searched words fall back only when some line has them, and not when
    /// a moment opened the transcript: a search that found it by meaning fades nothing.
    private var fadesMisses: Bool { focusRow == nil && meeting.lines.contains(where: isHit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppButton(title: backTitle, icon: "arrow--left", action: onBack)
                .padding(.leading, -DS.Control.padXQuiet)
                .padding(.bottom, DS.Space.base)
            header
                .padding(.bottom, DS.Space.wide)
            Card {
                bar
                transcript
            }
            Spacer(minLength: 0)
        }
        .padding(.top, DS.Space.pageTop)
        .padding(.horizontal, DS.Space.pageSide)
        .padding(.bottom, DS.Space.pageBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Ask Claude's questions, over everything, right edge under the button's; a click
        // anywhere else or Esc closes them.
        .overlayPreferenceValue(AskClaudeAnchor.self) { anchor in
            if isAsking, let anchor {
                GeometryReader { proxy in
                    let button = proxy[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { isAsking = false }
                        AskClaudeQuestions(meeting: meeting, noun: library.noun) { text in
                            isAsking = false
                            claude.ask(text)
                        }
                        .offset(x: button.maxX - DS.Material.askQuestionsWidth, y: button.maxY + DS.Space.tight)
                    }
                }
            }
        }
        .onExitCommand { isAsking = false }
        // Leaving the transcript (back, another page, the window closed) stops the audio.
        .onDisappear {
            player.stop()
            isAsking = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.wide) {
            VStack(alignment: .leading, spacing: DS.Space.headerGap) {
                if isEditing {
                    RenameField(meeting: meeting, font: DS.Font.title, onSave: { title in
                        isEditing = false
                        onRename(library.rename(meeting, title: title))
                    }, onCancel: { isEditing = false })
                } else {
                    HStack(spacing: DS.Space.snug) {
                        Text(meeting.name)
                            .font(DS.Font.title)
                            .foregroundStyle(DS.Color.ink)
                            .textSelection(.enabled)
                        AppButton(title: "", icon: "edit") { isEditing = true }
                            .opacity(isHoveringTitle ? 1 : 0)
                    }
                    .onHover { isHoveringTitle = $0 }
                }
                if !facts.isEmpty {
                    HStack(spacing: DS.Space.wide) {
                        ForEach(facts, id: \.label) { fact in
                            HStack(spacing: DS.Space.snug) {
                                Text(fact.label).foregroundStyle(DS.Color.dim)
                                Text(fact.value).foregroundStyle(DS.Color.inkSecondary)
                            }
                            .font(DS.Font.caption)
                        }
                    }
                }
                // The speakers, each one renamable where it stands (Gokul, 14 Oct 2026, 1B).
                if !meeting.speakerLabels.isEmpty, redoProgress == nil {
                    SpeakerRow(labels: meeting.speakerLabels) { old, new in
                        library.renameSpeaker(meeting, from: old, to: new)
                    }
                }
            }
            // First call on the width, so the rename field is offered everything Play leaves.
            .layoutPriority(1)
            Spacer(minLength: 0)
            // "Play 48 min": obviously audio, so it does not say so, and no format (Gokul).
            // It plays here, in SigmaFlow, and while it does the same button pauses it, with
            // how far it has got; Play then carries on from there (2A). Handed to another app
            // it played with nothing to stop it.
            HStack(alignment: .top, spacing: DS.Space.snug) {
                askClaude
                Group {
                    if let audio = meeting.audioURL, isLoaded {
                        if player.isPaused {
                            AppButton(title: "Play \(MeetingNaming.clock(player.elapsed))", kind: .secondary, icon: "play") {
                                player.play(audio)
                            }
                        } else {
                            AppButton(title: "Pause \(MeetingNaming.clock(player.elapsed))", kind: .secondary, icon: "pause") {
                                player.pause()
                            }
                        }
                    } else {
                        AppButton(
                            title: "Play \(MeetingNaming.length(meeting.duration))", kind: .secondary, icon: "play",
                            isEnabled: meeting.audioURL != nil
                        ) {
                            if let audio = meeting.audioURL { player.play(audio) }
                        }
                    }
                }
                // Play never gives way to the title; the rename field does.
                .fixedSize()
            }
        }
    }

    /// About this one recording (docs/mockups/ask-claude.html, 3C): before Claude has
    /// SigmaFlow its first click brings Claude's Install box, after that the questions.
    /// Nothing when Claude Desktop isn't on this Mac.
    @ViewBuilder
    private var askClaude: some View {
        if claude.status != .claudeNotInstalled {
            AppButton(title: "Ask Claude", kind: .secondary, icon: "anthropic") {
                if claude.status == .connected { isAsking.toggle() } else { claude.connect() }
            }
            .fixedSize()
            .anchorPreference(key: AskClaudeAnchor.self, value: .bounds) { $0 }
        }
    }

    private var facts: [(label: String, value: String)] {
        var out: [(String, String)] = []
        if let app = meeting.app { out.append(("From", app)) }
        if meeting.speakerCount > 0 { out.append(("Speakers", "\(meeting.speakerCount)")) }
        if let language = meeting.language { out.append(("Language", language.label)) }
        if !trimmedQuery.isEmpty, meeting.lines.contains(where: isHit) { out.append(("Found", "“\(trimmedQuery)”")) }
        return out.map { (label: $0.0, value: $0.1) }
    }

    // MARK: The bar on the transcript

    private var bar: some View {
        HStack(spacing: 0) {
            Eyebrow("Time", color: DS.Color.dim)
                .frame(width: DS.Material.transcriptTimeColumn, alignment: .leading)
            Eyebrow("Transcription", color: DS.Color.dim)
            Spacer(minLength: DS.Space.roomy)
            TranscribeAgainMenu(current: meeting.language ?? .english, isBusy: redoProgress != nil) { language in
                library.transcribe(meeting, language: language)
            }
            .padding(.trailing, DS.Space.snug)
            EqualWidthPair {
                PairButton(icon: didCopy ? "checkmark" : "copy", title: didCopy ? "Copied" : "Copy", format: didCopy ? nil : "(.md)") {
                    copyTranscript()
                }
                PairButton(icon: "download", title: "Download", format: "(.md)", hasLeadingRule: true) {
                    if let file = meeting.transcriptURL { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        }
        .padding(.leading, DS.Space.rowPadX)
        .padding(.trailing, DS.Space.snug)
        .frame(height: DS.Material.transcriptBarHeight)
        .background(DS.Color.editorFill)
        .overlay(alignment: .bottom) { CardDivider() }
    }

    /// The file itself, so what lands on the clipboard is exactly the .md.
    private func copyTranscript() {
        guard let file = meeting.transcriptURL, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(DS.Motion.statusHold))
            didCopy = false
        }
    }

    // MARK: The transcript

    @ViewBuilder
    private var transcript: some View {
        if let redoProgress {
            HStack(spacing: DS.Space.base) {
                Text("Transcribing")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                ProgressLine(fraction: redoProgress)
                Spacer(minLength: 0)
            }
            .padding(.leading, DS.Material.transcriptTimeColumn + DS.Space.rowPadX)
            .padding(.vertical, DS.Space.rowPadY)
        } else if shownLines.isEmpty {
            EmptyCardBody("Nothing in this transcript", detail: "This meeting has no words in it.")
            FaintDelete(title: "Delete \(library.noun)", action: onDelete)
        } else if isSnapshotting {
            lines(Array(shownLines.prefix(DS.Material.snapshotRows * 2)))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    lines(shownLines)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollEdgeFade()
                .frame(maxHeight: listHeight > 0 ? listHeight : nil)
                // The line playing is always kept in view (4A).
                .onChange(of: playingRow) { _, row in
                    guard let row, !player.isPaused else { return }
                    withAnimation(DS.Motion.follow) { proxy.scrollTo(row, anchor: DS.Material.playingLineAnchor) }
                }
                .onAppear {
                    if let focusRow, focusRow < shownLines.count {
                        proxy.scrollTo(focusRow, anchor: .center)
                        return
                    }
                    guard let first = meeting.lines.firstIndex(where: isHit) else { return }
                    proxy.scrollTo(first, anchor: .top)
                }
            }
        }
    }

    private func lines(_ lines: [MeetingLine]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                TranscriptRow(
                    line: line, folder: meeting.folder, query: trimmedQuery,
                    isFaded: fadesMisses && !isHit(line),
                    isFocused: index == focusRow,
                    isPlaying: index == playingRow,
                    removed: removedPicture?.path,
                    canPlay: meeting.audioURL != nil && !isCovered && !isAsking,
                    onPlay: {
                        if let audio = meeting.audioURL { player.play(audio, from: line.start) }
                    },
                    onDelete: onDeletePicture,
                    onUndo: { library.undoPicture() })
                    .id(index)
                if index < lines.count - 1 { CardDivider() }
            }
            // The only way to delete the whole meeting: past its last line.
            FaintDelete(title: "Delete \(library.noun)", action: onDelete)
        }
    }
}

private struct TranscriptRow: View {
    let line: MeetingLine
    /// The meeting's folder, which its photos' paths are inside.
    let folder: URL
    let query: String
    let isFaded: Bool
    /// The row a search moment opened the transcript at.
    var isFocused = false
    /// The sound is in this row, playing or paused.
    var isPlaying = false
    /// The picture just deleted, drawn as Undo where it was.
    let removed: String?
    /// A click anywhere on the row plays from its time (5B); a drag still selects words.
    var canPlay = false
    var onPlay: @MainActor () -> Void = {}
    let onDelete: (_ path: String, _ time: Double, _ isScreenshot: Bool) -> Void
    let onUndo: () -> Void
    @Environment(\.isSnapshotting) private var isSnapshotting

    private func time(_ path: String) -> Double {
        MeetingNaming.photoTime((path as NSString).lastPathComponent) ?? line.start
    }

    @ViewBuilder
    private func picture(_ path: String, isScreenshot: Bool) -> some View {
        if path == removed {
            PictureUndo(isScreenshot: isScreenshot, action: onUndo)
        } else {
            PhotoThumb(
                url: folder.appendingPathComponent(path), time: time(path),
                side: .rightOfPicture, isScreenshot: isScreenshot,
                onDelete: { onDelete(path, time(path), isScreenshot) })
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // The time, and under it any photos live notes took while the row was spoken.
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                Text("[\(MeetingNaming.clock(line.start))]")
                    .font(DS.Font.mono)
                    .foregroundStyle(isPlaying ? DS.Color.ink : DS.Color.dim)
                ForEach(line.photos, id: \.self) { path in
                    picture(path, isScreenshot: false)
                }
            }
            .frame(width: DS.Material.transcriptTimeColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                // A screenshot row: the picture where the words go.
                ForEach(line.screens, id: \.self) { path in
                    picture(path, isScreenshot: true)
                }
                if let speaker = line.speaker {
                    // A name reads the same as a number (Gokul, 14 Oct 2026, 2B).
                    Eyebrow(speaker, color: DS.Color.dim)
                }
                if !line.isScreenshot {
                    Text(underlined(line.text))
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY)
        .background(isFocused || isPlaying ? DS.Color.selectedFill : Color.clear)
        .background {
            // Not on a row whose Undo is showing: clicking Undo shouldn't also play. Not in a
            // snapshot run: the renderer paints AppKit views as its stand-in.
            if canPlay, !isSnapshotting, !hasUndo { ClickArea(onClick: onPlay) }
        }
        .opacity(isFaded ? DS.Material.searchFadeOpacity : 1)
    }

    private var hasUndo: Bool {
        guard let removed else { return false }
        return line.photos.contains(removed) || line.screens.contains(removed)
    }

    /// The searched word underlined wherever it appears, ignoring case.
    private func underlined(_ text: String) -> AttributedString {
        guard !query.isEmpty else { return AttributedString(text) }
        var out = AttributedString()
        var rest = text[...]
        while let match = rest.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            out.append(AttributedString(String(rest[..<match.lowerBound])))
            var word = AttributedString(String(rest[match]))
            word.underlineStyle = Text.LineStyle(pattern: .solid)
            out.append(word)
            rest = rest[match.upperBound...]
        }
        out.append(AttributedString(String(rest)))
        return out
    }
}

// MARK: - Transcribe again

/// A ghost on the bar: no border and no fill until the pointer is on it, quieter than the
/// pair beside it. The menu under it has the two ways to hear a meeting, with a check
/// against the one this transcript was heard as; picking the other redoes it.
private struct TranscribeAgainMenu: View {
    let current: MeetingLanguage
    let isBusy: Bool
    let onPick: (MeetingLanguage) -> Void

    @State private var isHovering = false

    var body: some View {
        Menu {
            Picker("", selection: Binding(get: { current }, set: { if $0 != current { onPick($0) } })) {
                ForEach(MeetingLanguage.allCases, id: \.self) { language in
                    Text(language.label).tag(language)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: DS.Control.iconGap) {
                CarbonIcon(name: "renew", size: DS.Control.iconSizeTiny)
                Text(isBusy ? "Transcribing" : "Transcribe again")
            }
            .font(DS.Font.caption)
            .foregroundStyle(isHovering && !isBusy ? DS.Color.ink : DS.Color.inkSecondary)
            .padding(.horizontal, DS.Control.padXQuiet)
            .frame(height: DS.Control.height - DS.Space.tight)
            .background(
                isHovering && !isBusy ? DS.Color.hoverFill : Color.clear,
                in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(isBusy)
        .onHover { isHovering = $0 }
        .handCursor()
    }
}

// MARK: - The joined pair

/// Two buttons side by side, each as wide as the wider one (Gokul: "the button with less
/// content takes the size of the bigger one").
private struct EqualWidthPair: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: width * CGFloat(subviews.count), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width / CGFloat(max(1, subviews.count))
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * width, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

/// One half of the pair: quieter than an AppButton, so the pair reads as part of the bar.
/// The speakers under the title, in the order they first speak. Click one to type a name:
/// Return saves it on every line of that speaker, Esc or clicking away leaves it, and an
/// empty name goes back to the number.
private struct SpeakerRow: View {
    let labels: [String]
    let onRename: (_ old: String, _ new: String) -> Void

    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            ForEach(labels, id: \.self) { label in
                if editing == label {
                    TextField(label, text: $draft)
                        .textFieldStyle(.plain)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.ink)
                        .padding(.horizontal, DS.Control.padXQuiet)
                        .frame(width: DS.Material.speakerFieldWidth, height: DS.Control.height - DS.Space.tight)
                        .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
                        .focused($isFocused)
                        .onAppear { isFocused = true }
                        .onSubmit {
                            editing = nil
                            onRename(label, draft)
                        }
                        .onExitCommand { editing = nil }
                        .onChange(of: isFocused) { _, focused in
                            if !focused, editing == label { editing = nil }
                        }
                } else {
                    SpeakerChip(label: label) {
                        draft = MeetingNaming.isNumberedSpeaker(label) ? "" : label
                        editing = label
                    }
                }
            }
        }
    }
}

private struct SpeakerChip: View {
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Control.iconGap) {
                Text(label)
                CarbonIcon(name: "edit", size: DS.Control.iconSizeTiny)
                    .opacity(isHovering ? 1 : DS.Material.searchFadeOpacity)
            }
            .font(DS.Font.caption)
            .foregroundStyle(isHovering ? DS.Color.ink : DS.Color.inkSecondary)
            .padding(.horizontal, DS.Control.padXQuiet)
            .frame(height: DS.Control.height - DS.Space.tight)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip)
                    .strokeBorder(isHovering ? DS.Color.borderStrong : DS.Color.border, lineWidth: DS.Border.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct PairButton: View {
    let icon: String
    let title: String
    let format: String?
    var hasLeadingRule = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Control.iconGap) {
                CarbonIcon(name: icon, size: DS.Control.iconSizeTiny)
                Text(title)
                if let format { Text(format).foregroundStyle(DS.Color.dim) }
            }
            .font(DS.Font.caption)
            .foregroundStyle(isHovering ? DS.Color.ink : DS.Color.inkSecondary)
            .padding(.horizontal, DS.Control.padX)
            .frame(maxWidth: .infinity)
            .frame(height: DS.Control.height - DS.Space.tight)
            .background(isHovering ? DS.Color.hoverFill : Color.clear)
            .overlay(alignment: .leading) {
                if hasLeadingRule {
                    Rectangle().fill(DS.Color.border).frame(width: DS.Border.hairline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .handCursor()
    }
}
