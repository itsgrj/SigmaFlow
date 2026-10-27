import AppKit
import SwiftUI

/// The notice that adds a correction as a rule, to Paper board 12:
///
///     ADDING TO DICTIONARY                       Not now
///     c̶l̶o̶d̶e̶  →  Claude
///     ───────────────────────────────────
///
/// The dictation HUD's card, same glass, edge and padding. It takes clicks but never key
/// focus, so the field the user is typing in keeps the cursor. A 2 px grey bar along the
/// bottom fills from the left over the window; when it reaches the end the rule is added and
/// the card flips to ADDED TO DICTIONARY with an Undo, holds a moment, and fades. Not now
/// removes the card at once and adds nothing. No mark before the label and the bar's slot
/// kept after it goes, so nothing moves when the card flips (Gokul, 16 Oct 2026,
/// docs/mockups/correction-notice.html, 1A 2B 3A 4C 5B, the bar counting up).
///
/// **Silence is yes**, decided 10 October 2026. The pointer over the card freezes the bar,
/// because a hover is the user reaching for the button and the countdown exists to settle a
/// notice nobody is looking at. Both clocks, the bar and the expiry, are one piece of state
/// on the model, so the card can never flip while the bar still shows time left. Hover is
/// tracked with an `.activeAlways` tracking area, not `.onHover`: SigmaFlow is not the front
/// app while this is up, and a key-window tracking area would work in testing and never in use.
///
/// The bar is the only thing that moves, and it is driven by the clock, not by an animation
/// on the model, so the words never slide into place.
@MainActor
final class CorrectionNoticePanel: NSPanel {
    private let model: CorrectionNoticeModel
    private var countdown: Task<Void, Never>?

    init(
        spoken: String,
        written: String,
        window: TimeInterval,
        onExpire: @escaping () -> Void,
        onUndo: @escaping () -> Void,
        onDecline: @escaping () -> Void
    ) {
        model = CorrectionNoticeModel(
            spoken: spoken,
            written: written,
            window: window,
            onUndo: onUndo,
            onDecline: onDecline
        )
        self.onExpire = onExpire
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: DS.Material.hudWidth, height: DS.Material.toolbarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)

        let hosting = HoverHostingView(rootView: CorrectionNoticeView(model: model))
        hosting.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        GlassCard.install(hosting, in: self)
    }

    private let onExpire: () -> Void

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Same spot as the dictation HUD: just above the Dock, centered.
    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + DS.Material.hudBottomInset))
        invalidateShadow()
    }

    func present() {
        layoutIfNeeded()
        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeIn
            animator().alphaValue = 1
        }
        model.start()
        // The notice can appear under a cursor that is already parked there; a tracking area
        // only reports crossings, so the first state has to be read, not waited for.
        if frame.contains(NSEvent.mouseLocation) { model.pause() }
        startCountdown()
    }

    // MARK: - The window running

    /// Owns the expiry, because it owns the pause. A `Task.sleep` cannot be held.
    private func startCountdown() {
        countdown?.cancel()
        countdown = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if model.hasExpired {
                    countdown = nil
                    switch model.stage {
                    case .adding: onExpire()
                    case .added, .undone: model.onDecline()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func stopCountdown() {
        countdown?.cancel()
        countdown = nil
    }

    /// Pointer in: bank the elapsed time and drop the clock. Pointer out: pick it up again
    /// from where it was frozen. Never while a confirmation is showing: those have nothing
    /// left to decide, and the pointer should not be able to pin one to the screen.
    private func hoverChanged(_ inside: Bool) {
        guard model.stage == .adding else { return }
        if inside { model.pause() } else { model.resume() }
    }

    /// The bar reached the end and the rule is in the store. Flip to the confirmation, on a
    /// short window of its own, then fade.
    func showAdded() {
        model.stage = .added
        model.start(window: DS.Motion.addedHold)
        startCountdown()
        recenter()
    }

    /// Undo was pressed. Say so briefly, then fade.
    func showUndone() {
        model.stage = .undone
        model.start(window: DS.Motion.addedHold)
        startCountdown()
        recenter()
    }

    /// The card keeps its height across stages, but a re-layout can still nudge the window;
    /// keep its bottom edge where it was.
    private func recenter() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.layoutIfNeeded()
            self?.reposition()
        }
    }

    func dismiss() {
        stopCountdown()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeOut
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }

    override func orderOut(_ sender: Any?) {
        stopCountdown()
        super.orderOut(sender)
    }
}

@MainActor
@Observable
final class CorrectionNoticeModel {
    let spoken: String
    let written: String
    /// How long the bar takes to fill while adding.
    let addingWindow: TimeInterval
    let onUndo: () -> Void
    /// Not now: the card goes at once and nothing is added.
    let onDecline: () -> Void

    enum Stage {
        /// The bar is filling. When it reaches the end the rule is added.
        case adding
        /// Added, with a moment to take it back.
        case added
        /// Taken back.
        case undone
    }

    var stage: Stage = .adding

    /// The window the current stage is running down.
    private(set) var window: TimeInterval
    /// Window already spent, not counting the run in progress. Remaining time is this plus
    /// the clock since `runningSince`, which is what makes a pause expressible at all.
    private var spent: TimeInterval = 0
    /// When the current run began; nil while the pointer holds the notice open.
    private var runningSince: Date?
    /// When the hold began, for the cap below.
    private var pausedAt: Date?
    private(set) var hasStarted = false

    /// Freezing at the point of hover would still leave a sliver when the hover lands late,
    /// so the freeze also buys the remainder back up to this much.
    private static let heldFloor: TimeInterval = 1.5
    /// A cursor parked over the notice is not a user deciding, and nothing may own the
    /// screen forever. A hold gives up on its own after this long, and the rule is added.
    private static let maxHold: TimeInterval = 15

    init(spoken: String, written: String, window: TimeInterval, onUndo: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.spoken = spoken
        self.written = written
        self.addingWindow = window
        self.window = window
        self.onUndo = onUndo
        self.onDecline = onDecline
    }

    func start(window: TimeInterval? = nil) {
        if let window { self.window = window }
        hasStarted = true
        spent = 0
        pausedAt = nil
        runningSince = Date()
    }

    func pause() {
        guard hasStarted, let since = runningSince else { return }
        spent = min(spent + Date().timeIntervalSince(since), max(0, window - Self.heldFloor))
        runningSince = nil
        pausedAt = Date()
    }

    func resume() {
        guard hasStarted, runningSince == nil else { return }
        pausedAt = nil
        runningSince = Date()
    }

    var isPaused: Bool { hasStarted && runningSince == nil }

    private func elapsed(at date: Date) -> TimeInterval {
        guard let since = runningSince else { return spent }
        return spent + date.timeIntervalSince(since)
    }

    /// What the bar draws: 1 at the start, 0 at expiry, constant while held.
    func remaining(at date: Date) -> Double {
        guard window > 0 else { return 0 }
        return max(0, min(1, 1 - elapsed(at: date) / window))
    }

    var hasExpired: Bool {
        guard hasStarted else { return false }
        if let pausedAt { return Date().timeIntervalSince(pausedAt) >= Self.maxHold }
        return elapsed(at: Date()) >= window
    }
}

/// Hosts the notice and reports the pointer crossing its edge. `NSTrackingArea` with
/// `.activeAlways` is the point of the subclass: the panel never becomes key and the app is
/// not frontmost, so nothing keyed to the key window ever fires here.
@MainActor
private final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

struct CorrectionNoticeView: View {
    @Bindable var model: CorrectionNoticeModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(alignment: .center, spacing: DS.Space.roomy) {
                VStack(alignment: .leading, spacing: DS.Space.snug - DS.Space.hair) {
                    headline
                    pair
                }
                Spacer(minLength: 0)
                action
            }
            // Kept after the bar has gone, so the card's height holds when it flips.
            bar.opacity(model.stage == .adding ? 1 : 0)
        }
        .padding(.horizontal, DS.Space.hudPadX)
        .padding(.vertical, DS.Space.hudPadY)
        .frame(width: DS.Material.hudWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var headline: some View {
        switch model.stage {
        case .adding:
            Eyebrow("Adding to dictionary")
        case .added:
            Eyebrow("Added to dictionary", color: DS.Color.ink)
        case .undone:
            Eyebrow("Not added", color: DS.Color.ink)
        }
    }

    /// The rule: the engine's word struck through, an arrow, the user's word.
    private var pair: some View {
        HStack(spacing: DS.Space.snug + DS.Space.hair) {
            Text(model.spoken)
                .font(DS.Font.transcript)
                .foregroundStyle(DS.Color.inkSecondary)
                .strikethrough(true, color: DS.Color.inkSecondary)
            CarbonIcon(name: "arrow--right", size: DS.Control.hudGlyph)
                .foregroundStyle(DS.Color.inkSecondary)
            Text(model.written)
                .font(DS.Font.transcript)
                .foregroundStyle(model.stage == .undone ? DS.Color.inkSecondary : DS.Color.ink)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var action: some View {
        switch model.stage {
        case .adding: AppButton(title: "Not now", kind: .secondary, action: model.onDecline)
        case .added: AppButton(title: "Undo", kind: .secondary, action: model.onUndo)
        case .undone: EmptyView()
        }
    }

    /// Read from the clock every frame; no transaction, so nothing else moves. Held, the
    /// timeline stops asking and the width simply stands still. It counts up: empty at the
    /// start, full when the rule is added.
    private var bar: some View {
        TimelineView(.animation(minimumInterval: nil, paused: model.isPaused)) { context in
            let remaining = model.remaining(at: context.date)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Color.noticeTrack)
                    Capsule().fill(DS.Color.dim).frame(width: proxy.size.width * (1 - remaining))
                }
            }
            .frame(height: DS.Border.bar)
        }
    }
}
