import AppKit
import SwiftUI

/// The live notes overlay (docs/mockups/live-notes.html): the dictation overlay's glass,
/// grown into a card in the top right corner. Fixed width; the height is the user's, by
/// the bar along the bottom edge; the status row drags it anywhere.
///
/// Takes clicks, never key focus, like the dictation overlay: the app in front keeps the
/// keyboard, so the user can type while the notes run.
@MainActor
final class NotesPanel: NSPanel {
    /// Where the user last left it, for the rest of this run of the app.
    private static var lastFrame: NSRect?

    private var dragStart: (mouse: NSPoint, frame: NSRect)?

    init(session: NotesSession) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: DS.Material.notesWidth, height: DS.Material.notesHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        acceptsMouseMovedEvents = true
        Self.letCursorChangeFromBehind()
        let view = NotesView(
            session: session,
            onMove: { [weak self] phase in self?.drag(phase, resizing: false) },
            onResize: { [weak self] phase in self?.drag(phase, resizing: true) })
        GlassCard.install(NSHostingView(rootView: view), in: self, fills: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        if let last = Self.lastFrame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(last) }) {
            setFrame(last, display: false)
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let inset = DS.Material.notesInset
            setFrame(NSRect(
                x: visible.maxX - DS.Material.notesWidth - inset,
                y: visible.maxY - DS.Material.notesHeight - inset,
                width: DS.Material.notesWidth, height: DS.Material.notesHeight), display: false)
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeIn
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        Self.lastFrame = frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeOut
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.orderOut(nil) }
        }
    }

    /// macOS ignores a cursor change from an app that isn't in front, and SigmaFlow never
    /// is while the card floats over someone's work: tested 16 Oct 2026, `NSCursor.set()`
    /// from behind did nothing. This switch on our own window-server connection lets it
    /// through. It is private (SkyLight); without it the card works, the cursor just
    /// doesn't change.
    private static var cursorSwitchOn = false
    private static func letCursorChangeFromBehind() {
        guard !cursorSwitchOn else { return }
        cursorSwitchOn = true
        let connection = _CGSDefaultConnection()
        _ = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    enum DragPhase { case changed, ended }

    /// Moves the card, or changes its height with the top edge held still. Read from the
    /// mouse's place on screen, not the gesture's: the gesture's own space moves with the
    /// window it is moving.
    private func drag(_ phase: DragPhase, resizing: Bool) {
        let mouse = NSEvent.mouseLocation
        guard phase == .changed else {
            dragStart = nil
            Self.lastFrame = frame
            (resizing ? NSCursor.resizeUpDown : NSCursor.openHand).set()
            return
        }
        // The hand closes while it holds the card.
        (resizing ? NSCursor.resizeUpDown : NSCursor.closedHand).set()
        guard let start = dragStart else {
            dragStart = (mouse, frame)
            return
        }
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        if resizing {
            let maxHeight = (screen ?? NSScreen.main)?.visibleFrame.height ?? start.frame.height
            let height = min(maxHeight, max(DS.Material.notesMinHeight, start.frame.height - dy))
            setFrame(NSRect(x: start.frame.minX, y: start.frame.maxY - height, width: start.frame.width, height: height),
                     display: true)
        } else {
            setFrameOrigin(NSPoint(x: start.frame.minX + dx, y: start.frame.minY + dy))
        }
    }
}

struct NotesView: View {
    @Bindable var session: NotesSession
    let onMove: (NotesPanel.DragPhase) -> Void
    let onResize: (NotesPanel.DragPhase) -> Void

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            Rectangle()
                .fill(DS.Color.border)
                .frame(height: DS.Border.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.base) {
                    let lines = session.lines
                    // Screenshots taken before anyone spoke come first.
                    ForEach(screens(before: lines.first?.start)) { ScreenLineView(screen: $0) }
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        NotesLineView(
                            line: line,
                            isLive: index == lines.count - 1 && !session.isPaused,
                            photos: photos(for: index, in: lines))
                        // Then each screenshot on a line of its own, after the line it was taken in (6B).
                        ForEach(screens(for: index, in: lines)) { ScreenLineView(screen: $0) }
                    }
                }
                .padding(.horizontal, DS.Space.hudPadX)
                .padding(.vertical, DS.Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // New lines keep the newest in view; scrolling up to read stays put.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            grip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// The dictation overlay's row: the steady dot (hollow while paused), REC, the timer,
    /// the meter, then Pause and Stop. Everything left of the buttons moves the card, with an
    /// open hand over it; the buttons stay buttons.
    private var statusRow: some View {
        HStack(spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.snug) {
                HStack(spacing: DS.Space.snug) {
                    if session.isPaused {
                        Circle()
                            .strokeBorder(DS.Color.inkSecondary, lineWidth: DS.Border.pausedRing)
                            .frame(width: DS.Control.hudDot, height: DS.Control.hudDot)
                            .frame(width: DS.Control.hudGlyph, height: DS.Control.hudGlyph)
                    } else {
                        HUDGlyph(kind: .dot)
                    }
                    Eyebrow(session.isPaused ? "Paused" : "Rec", color: DS.Color.ink)
                }
                .fixedSize()
                Readout(text: MeetingNaming.clock(session.elapsed))
                    .fixedSize()
                // Fewer dots than the dictation overlay's: the row also holds the buttons.
                VUMeter(level: session.level, isActive: !session.isPaused, segments: DS.Material.notesMeterSegments)
                    .frame(
                        width: VUMeter.naturalWidth(segments: DS.Material.notesMeterSegments),
                        height: DS.Material.meterDotSize * 2)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(PointerArea(cursor: .openHand))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in onMove(.changed) }
                .onEnded { _ in onMove(.ended) })
            HStack(spacing: DS.Space.snug) {
                // Screenshots every 15 s: off at every start, faint while off (2B).
                AppButton(title: "", kind: .secondary, icon: "laptop", iconDimmed: !session.isScreensOn, compact: true) {
                    session.toggleScreens()
                }
                // On at every start; faint while off (docs/mockups/live-notes.html, 1A).
                AppButton(title: "", kind: .secondary, icon: "camera", iconDimmed: !session.isCameraOn, compact: true) {
                    session.toggleCamera()
                }
                AppButton(title: "", kind: .secondary, icon: session.isPaused ? "play" : "pause", compact: true) {
                    session.togglePause()
                }
                AppButton(title: "Stop", kind: .secondary, icon: "stop", compact: true) { session.stop() }
            }
            .fixedSize()
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DS.Space.hudPadX)
        .padding(.vertical, DS.Space.hudPadY)
    }

    /// The photos taken while a line was spoken: from its start to the next line's, the
    /// first line also taking any taken before anyone spoke. The rule the .md uses too.
    private func photos(for index: Int, in lines: [NoteLine]) -> [NotePhoto] {
        let from = index == 0 ? -Double.infinity : lines[index].start
        let to = index + 1 < lines.count ? lines[index + 1].start : Double.infinity
        return session.photos.filter { $0.time >= from && $0.time < to }
    }

    private func screens(for index: Int, in lines: [NoteLine]) -> [NotePhoto] {
        let to = index + 1 < lines.count ? lines[index + 1].start : Double.infinity
        return session.screens.filter { $0.time >= lines[index].start && $0.time < to }
    }

    private func screens(before start: Double?) -> [NotePhoto] {
        session.screens.filter { $0.time < (start ?? .infinity) }
    }

    private var grip: some View {
        Capsule()
            .fill(DS.Color.gaugeOff)
            .frame(width: DS.Material.notesGripWidth, height: DS.Material.notesGripThickness)
            .frame(maxWidth: .infinity)
            .frame(height: DS.Material.notesGripHeight)
            .contentShape(Rectangle())
            .background(PointerArea(cursor: .resizeUpDown))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in onResize(.changed) }
                .onEnded { _ in onResize(.ended) })
    }
}

/// One line: its time, then the words. The line being spoken now brings its words in the
/// way the dictation overlay does (`WordFlowText`, Gokul 16 Oct 2026); earlier lines sit
/// still, and come back settled when scrolled into view again. A line heard as Tamil while
/// spoken shows grey blocks until IndicConformer has heard it, then lands whole.
private struct NotesLineView: View {
    let line: NoteLine
    let isLive: Bool
    let photos: [NotePhoto]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.base) {
            // The time, and under it the photos taken while the line was spoken (2A).
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                Text(MeetingNaming.clock(line.start))
                    .font(DS.Font.monoSmall)
                    .foregroundStyle(DS.Color.dim)
                ForEach(photos) { PhotoThumb(url: $0.url, time: $0.time, side: .leftOfWindow) }
            }
            .frame(width: DS.Material.notesTimeColumn, alignment: .leading)
            switch line.language {
            case .english:
                WordFlowText(target: line.text, paced: isLive, returning: !isLive)
            case .tamilPending:
                WordBlocks(count: Int(line.length / DS.Material.notesBlockPace) + 1)
            case .tamil:
                // A new view, so the Tamil words come in rather than swap in silently; once
                // they have, a scroll back finds them settled.
                WordFlowText(target: line.text, paced: false, returning: !justLanded)
                    .id(line.language)
            }
        }
    }

    private var justLanded: Bool {
        guard let landed = line.landed else { return false }
        return Date().timeIntervalSince(landed) < DS.Motion.wordFlow * 2
    }
}

/// A screenshot on a line of its own: its time, and the picture where words would be.
private struct ScreenLineView: View {
    let screen: NotePhoto

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            Text(MeetingNaming.clock(screen.time))
                .font(DS.Font.monoSmall)
                .foregroundStyle(DS.Color.dim)
                .frame(width: DS.Material.notesTimeColumn, alignment: .leading)
            PhotoThumb(url: screen.url, time: screen.time, side: .leftOfWindow, isScreenshot: true)
            Spacer(minLength: 0)
        }
    }
}

/// A Tamil line still being heard: a grey block for every half second or so of speech, the
/// way its words will fill the line (Gokul, 16 Oct 2026, round 1 C). Each block fades in;
/// none of them moves after.
private struct WordBlocks: View {
    let count: Int

    var body: some View {
        WrapLayout(spacing: DS.Material.notesBlockGap, lineSpacing: DS.Material.notesBlockGap) {
            ForEach(0..<count, id: \.self) { index in
                let widths = DS.Material.notesBlockWidths
                RoundedRectangle(cornerRadius: DS.Radius.chip / 2)
                    .fill(DS.Color.gaugeOff)
                    .frame(width: widths[index % widths.count], height: DS.Material.notesBlockHeight)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: DS.Motion.wordFlow), value: count)
        // Sits on the line where the first words would, the time beside its first row.
        .padding(.top, DS.Space.tight + DS.Space.hair)
        .alignmentGuide(.firstTextBaseline) { _ in DS.Space.tight + DS.Space.hair + DS.Material.notesBlockHeight }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@_silgen_name("_CGSDefaultConnection") private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ connection: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32
