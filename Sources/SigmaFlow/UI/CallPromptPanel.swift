import AppKit
import SwiftUI

/// "Record this meeting?", above the Dock where dictation shows, the moment a call app opens
/// the microphone (docs/mockups/meeting-call-detect.html, picks A A A B).
///
/// SigmaFlow's own icon, the question, two buttons (docs/mockups/call-card.html, 1H 2A 3A,
/// 19 Oct 2026). The card used to carry the call app's name on top, and "Dia" there read as
/// Dia asking to record. Nothing explains anything (Gokul, 13 Oct 2026:
/// "they are not auditing the app").
///
/// Since 5 Nov 2026 the two buttons are the answer itself, With video or Sound only, and
/// there is no Not now (docs/mockups/meeting-video.html, 33; Gokul: two choices, no third
/// button to close the card). A 2 px line along the card's foot runs down over
/// `DS.Motion.callAnswerWindow`; the pointer on the card holds it, and when it runs out the
/// card goes and nothing is recorded. The answer is remembered for ⌃⌥M and Record meeting.
/// Either button turns the card into the recording's status row for a moment, then it goes.
/// The card also goes by itself when the call ends unanswered.
@MainActor
final class CallPrompter {
    static let shared = CallPrompter()

    private var panel: CallPromptPanel?
    private var model: CallPromptModel?

    private init() {}

    func start() {
        let watcher = CallWatcher.shared
        watcher.onStart = { [weak self] call in self?.callStarted(call) }
        watcher.onEnd = { [weak self] call in self?.callEnded(call) }
        watcher.start()
    }

    private func callStarted(_ call: CallWatcher.Call) {
        guard Settings.shared.askToRecordCalls, !MeetingSession.shared.isRecording else { return }
        let model = CallPromptModel()
        model.onRecord = { [weak self, weak model] video in
            Settings.shared.recordVideo = video
            MeetingSession.shared.start(for: call, video: video)
            guard MeetingSession.shared.isRecording, let model else {
                self?.close()
                return
            }
            model.stage = .recording
            self?.panel?.reanchor()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(DS.Motion.callConfirmHold))
                if self?.model === model { self?.close() }
            }
        }
        model.onDismiss = { [weak self] in self?.close() }
        close()
        self.model = model
        let panel = CallPromptPanel(model: model)
        self.panel = panel
        panel.present()
    }

    private func callEnded(_ call: CallWatcher.Call) {
        if model?.stage == .asking { close() }
        // Started from the card for this call: it ends with the call (Gokul, 3A).
        let session = MeetingSession.shared
        if session.isRecording, session.call == call { session.stop() }
    }

    private func close() {
        panel?.dismiss()
        panel = nil
        model = nil
    }
}

@MainActor
@Observable
final class CallPromptModel {
    enum Stage { case asking, recording }

    var stage: Stage = .asking
    /// With video (true) or Sound only.
    var onRecord: (Bool) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    /// The answer window already spent, not counting the run in progress; nil `runningSince`
    /// while the pointer holds the card, as the correction notice keeps its bar.
    private var spent: TimeInterval = 0
    private var runningSince: Date? = Date()

    var isHeld: Bool { runningSince == nil }

    func hold() {
        guard let since = runningSince else { return }
        spent += Date().timeIntervalSince(since)
        runningSince = nil
    }

    func release() {
        guard runningSince == nil else { return }
        runningSince = Date()
    }

    /// What the line draws: 1 when the card arrives, 0 when it goes.
    func remaining(at date: Date) -> Double {
        let elapsed = spent + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
        return max(0, 1 - elapsed / DS.Motion.callAnswerWindow)
    }
}

/// The dictation overlay's card: same glass, edge and padding. Takes clicks, never key
/// focus, so the call app keeps the keyboard.
@MainActor
final class CallPromptPanel: NSPanel {
    private let model: CallPromptModel
    private var countdown: Task<Void, Never>?

    init(model: CallPromptModel) {
        self.model = model
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
        let hosting = HoverHostingView(rootView: CallPromptView(model: model))
        hosting.onHoverChange = { [weak model] inside in
            if inside { model?.hold() } else { model?.release() }
        }
        GlassCard.install(hosting, in: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Above the Dock, centred, bottom edge fixed: the same spot as the dictation overlay.
    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + DS.Material.hudBottomInset))
        invalidateShadow()
    }

    /// The card changed size (asking to recording); keep its bottom edge where it was.
    func reanchor() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.layoutIfNeeded()
            self?.place()
        }
    }

    func present() {
        layoutIfNeeded()
        place()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeIn
            animator().alphaValue = 1
        }
        // A tracking area only reports crossings: a pointer already there holds it now.
        if frame.contains(NSEvent.mouseLocation) { model.hold() }
        countdown = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.model.stage == .asking, self.model.remaining(at: Date()) <= 0 {
                    self.model.onDismiss()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func dismiss() {
        countdown?.cancel()
        countdown = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeOut
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.orderOut(nil) }
        }
    }
}

struct CallPromptView: View {
    @Bindable var model: CallPromptModel
    @State private var session = MeetingSession.shared

    var body: some View {
        Group {
            switch model.stage {
            case .asking:
                HStack(alignment: .top, spacing: DS.Space.roomy - DS.Space.hair) {
                    AppIconTile(size: DS.Material.callPromptIcon)
                    VStack(alignment: .leading, spacing: DS.Space.snug - DS.Space.hair) {
                        // As tall as the icon, so the question sits level with its middle.
                        Text("Record this meeting?")
                            .font(DS.Font.transcript)
                            .foregroundStyle(DS.Color.ink)
                            .frame(minHeight: DS.Material.callPromptIcon)
                        HStack(spacing: DS.Space.snug) {
                            AppButton(title: "With video", kind: .secondary, icon: "video") { model.onRecord(true) }
                            AppButton(title: "Sound only", kind: .secondary, icon: "microphone") { model.onRecord(false) }
                        }
                    }
                }
            case .recording:
                // The overlay's status row: the steady dot, REC, the timer, the green dots.
                HStack(spacing: DS.Space.roomy - DS.Space.hair) {
                    HStack(spacing: DS.Space.snug) {
                        HUDGlyph(kind: .dot)
                        Eyebrow("Rec", color: DS.Color.ink)
                    }
                    .fixedSize()
                    Readout(text: MeetingNaming.clock(session.elapsed))
                    VUMeter(level: session.level, isActive: true)
                        .frame(width: VUMeter.naturalWidth, height: DS.Material.meterDotSize * 2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, DS.Space.hudPadX)
        .padding(.vertical, DS.Space.hudPadY)
        .frame(width: DS.Material.hudWidth, alignment: .leading)
        .overlay(alignment: .bottomLeading) {
            if model.stage == .asking { answerLine }
        }
        .environment(\.colorScheme, .dark)
    }

    /// Read from the clock every frame and still while held, like the correction notice's bar.
    private var answerLine: some View {
        TimelineView(.animation(minimumInterval: nil, paused: model.isHeld)) { context in
            GeometryReader { proxy in
                Rectangle()
                    .fill(DS.Color.dim)
                    .frame(width: proxy.size.width * model.remaining(at: context.date))
            }
            .frame(height: DS.Border.bar)
        }
    }
}
