import AppKit
import SwiftUI

/// "Record this meeting?", above the Dock where dictation shows, the moment a call app opens
/// the microphone (docs/mockups/meeting-call-detect.html, picks A A A B).
///
/// SigmaFlow's own icon, the question, two buttons (docs/mockups/call-card.html, 1H 2A 3A,
/// 19 Oct 2026). The card used to carry the call app's name on top, and "Dia" there read as
/// Dia asking to record. Nothing explains anything (Gokul, 13 Oct 2026:
/// "they are not auditing the app"). Record meeting turns the card into the recording's
/// status row for a moment, then it goes; Not now leaves this call alone. The card also goes
/// by itself when the call ends unanswered.
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
        model.onRecord = { [weak self, weak model] in
            MeetingSession.shared.start(for: call)
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
    var onRecord: () -> Void = {}
    var onDismiss: () -> Void = {}
}

/// The dictation overlay's card: same glass, edge and padding. Takes clicks, never key
/// focus, so the call app keeps the keyboard.
@MainActor
final class CallPromptPanel: NSPanel {
    init(model: CallPromptModel) {
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
        GlassCard.install(NSHostingView(rootView: CallPromptView(model: model)), in: self)
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
    }

    func dismiss() {
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
                            AppButton(title: "Record meeting", kind: .secondary, icon: "microphone") { model.onRecord() }
                            AppButton(title: "Not now") { model.onDismiss() }
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
        .environment(\.colorScheme, .dark)
    }
}
