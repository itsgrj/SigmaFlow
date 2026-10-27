import SwiftUI

/// The Overlay row on Settings, to docs/mockups/overlay-preview-options.html (option A1).
///
/// Two tiles instead of a popup, so the choice is seen rather than described. Each tile is
/// a header over a stage: a small copy of the overlay above a text box, the way the real
/// one sits above the Dock while your words land in some other app. Until someone tries
/// it, both tiles play the same sample sentence on a loop, and both end with the sentence
/// pasted into their box, so Minimal visibly hands over the same words as Live transcript.
///
/// Hold to talk runs a real dictation in preview mode (`DictationController.isPreview`):
/// your mic, your model, your cleanup and dictionary, but the panel stays hidden, nothing
/// is typed and nothing is saved. Both tiles draw that one run, each in its own mode. The
/// push-to-talk key is deliberately not wired in here: it would bring up the real overlay
/// as well, and there would be three on screen at once.
struct OverlayChooser: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @Environment(\.isSnapshotting) private var isSnapshotting

    /// Once someone has held the button, the tiles show their own words from then on.
    @State private var hasTried = false
    /// Counts preview runs, so each run's words flow in from empty.
    @State private var run = 0
    @State private var demoStart = Date()

    var body: some View {
        VStack(spacing: 0) {
            heading
            HStack(alignment: .top, spacing: DS.Space.tileGap) {
                ForEach(OverlayMode.allCases, id: \.self) { mode in
                    OverlayTile(
                        mode: mode,
                        isSelected: settings.overlayMode == mode,
                        paused: isSnapshotting,
                        frame: frame(at:)
                    ) {
                        settings.overlayMode = mode
                    }
                }
            }
            .padding(.horizontal, DS.Space.rowPadX)
            .padding(.bottom, DS.Space.rowPadX)
            CardDivider()
        }
        .onChange(of: controller.isPreview) { _, isPreview in
            guard isPreview else { return }
            hasTried = true
            run += 1
        }
        .onDisappear { controller.endPreview() }
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: DS.Space.roomy) {
            VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                Text("Overlay")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                Caption("What you see while you talk.")
            }
            .padding(.vertical, DS.Space.rowPadY)
            Spacer(minLength: 0)
            HoldToTalkButton(
                isEnabled: controller.state == .idle || controller.isPreview,
                onPress: { controller.beginPreview() },
                onRelease: { controller.endPreview() }
            )
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .frame(minHeight: DS.Material.cardRowHeight)
    }

    /// What both tiles draw at this moment: the sample until someone tries it, then the
    /// preview run, then what that run pasted.
    private func frame(at date: Date) -> OverlayPreviewFrame {
        guard hasTried || controller.isPreview else {
            let elapsed = date.timeIntervalSince(demoStart)
            let t = isSnapshotting ? DS.Motion.demoSnapshotAt : elapsed.truncatingRemainder(dividingBy: DS.Motion.demoCycle)
            return .sample(at: t, cycle: Int(elapsed / DS.Motion.demoCycle))
        }
        guard controller.isPreview else {
            return OverlayPreviewFrame(pasted: controller.previewText, run: run)
        }
        let start = controller.holdStarted ?? date
        switch controller.state {
        case .starting, .listening:
            return OverlayPreviewFrame(
                phase: .recording, seconds: date.timeIntervalSince(start), level: controller.level,
                words: controller.transcript, run: run
            )
        case .finishing:
            return OverlayPreviewFrame(
                phase: .processing, seconds: (controller.releasedAt ?? date).timeIntervalSince(start),
                words: controller.transcript, run: run
            )
        case .error(let message):
            return OverlayPreviewFrame(phase: .error(message), run: run)
        case .idle:
            return OverlayPreviewFrame(pasted: controller.previewText, run: run)
        }
    }
}

// MARK: - The moment both tiles draw

struct OverlayPreviewFrame {
    enum Phase: Equatable {
        case hidden, recording, processing
        case error(String)
    }

    var phase: Phase = .hidden
    var seconds: TimeInterval = 0
    var level: Float = 0
    var words = ""
    var pasted = ""
    /// Which run the words belong to; the sample's rounds count down from -1.
    var run = 0

    static let sampleSentence = "Can we move the design review to Thursday at three and send the deck tonight?"
    private static let sampleWords = sampleSentence.split(separator: " ").map(String.init)

    /// One round of the sample: words arrive at a speaking pace, release, processing, then
    /// the sentence sits pasted in the box until the round starts again.
    static func sample(at t: TimeInterval, cycle: Int) -> OverlayPreviewFrame {
        let run = -1 - cycle
        if t < DS.Motion.demoRecord {
            let count = max(0, Int((t - DS.Motion.demoLead) / DS.Motion.demoWordPace))
            return OverlayPreviewFrame(
                phase: .recording, seconds: t, level: sampleLevel(t),
                words: sampleWords.prefix(count).joined(separator: " "), run: run
            )
        }
        if t < DS.Motion.demoProcess {
            return OverlayPreviewFrame(phase: .processing, seconds: DS.Motion.demoRecord, words: sampleSentence, run: run)
        }
        return OverlayPreviewFrame(pasted: sampleSentence, run: run)
    }

    /// A voice-like level for the sample: a quick wobble, dipping now and then between
    /// phrases. The meter damps it the same way it damps a real mic.
    private static func sampleLevel(_ t: TimeInterval) -> Float {
        let wobble = 0.45 + 0.25 * sin(t / 0.13) + 0.1 * sin(t / 0.047)
        let phrase = sin(t / 0.9) > -0.7 ? 1.0 : 0.2
        return Float(min(max(wobble * phrase, 0), 1))
    }
}

// MARK: - Tile

/// One choice: name, what it does, SELECTED when it is the one in use, then the stage.
/// Clicking anywhere on it selects it, as with the default style tiles.
private struct OverlayTile: View {
    let mode: OverlayMode
    let isSelected: Bool
    let paused: Bool
    let frame: (Date) -> OverlayPreviewFrame
    let action: () -> Void

    private var caption: String {
        switch mode {
        case .live: "Your words appear as you speak."
        case .minimal: "Your words appear after you speak."
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                header
                OverlayStage(mode: mode, paused: paused, frame: frame)
            }
            .background(isSelected ? DS.Color.tileSelectedFill : DS.Color.glass)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(
                    isSelected ? DS.Color.ink : DS.Color.border,
                    lineWidth: isSelected ? DS.Material.tileSelectedStroke : DS.Border.hairline
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .buttonStyle(.plain)
        .handCursor()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.captionGap) {
            Text(mode.displayName)
                .font(DS.Font.transcript)
                .foregroundStyle(DS.Color.ink)
            Text(caption)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if isSelected {
                HStack(spacing: DS.Space.fieldLabelGap) {
                    CarbonIcon(name: "checkmark", size: DS.Control.iconSizeTiny)
                        .foregroundStyle(DS.Color.ink)
                    Eyebrow("Selected", color: DS.Color.ink)
                }
                .padding(.top, DS.Space.snug)
            }
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, minHeight: DS.Material.overlayTileHeader, alignment: .topLeading)
    }
}

// MARK: - Stage

/// A slice of screen: the painting, softened, with the overlay card standing above a text
/// box. The card grows upward from a fixed line, as the real one grows from above the Dock.
private struct OverlayStage: View {
    let mode: OverlayMode
    let paused: Bool
    let frame: (Date) -> OverlayPreviewFrame

    var body: some View {
        GeometryReader { geo in
            // The real card is wider than a tile at the window's minimum width; draw it
            // smaller there rather than let it run past the tile's edges.
            let scale = min(DS.Material.overlayPreviewScale, (geo.size.width - DS.Space.roomy * 2) / DS.Material.hudWidth)
            ZStack {
                if let painting = BackgroundImage.image {
                    Image(nsImage: painting)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: DS.Material.overlayStageBlur)
                        .overlay(DS.Color.paintingScrim)
                } else {
                    DS.Color.chassis
                }
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
                    let now = frame(context.date)
                    VStack(spacing: DS.Space.base) {
                        Spacer(minLength: 0)
                        Color.clear
                            .frame(height: 0)
                            .overlay(alignment: .bottom) {
                                if now.phase != .hidden {
                                    OverlayPreviewCard(mode: mode, frame: now)
                                        .fixedSize()
                                        .scaleEffect(scale, anchor: .bottom)
                                        .transition(.opacity)
                                }
                            }
                            .animation(DS.Motion.fade, value: now.phase == .hidden)
                        PreviewField(text: now.pasted)
                    }
                    .padding(DS.Space.roomy)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: DS.Material.overlayStageHeight)
        .clipped()
    }
}

/// The overlay card, drawn from a frame instead of the controller. Same parts and sizes as
/// `HUDView`; the tint and edge that `HUDPanel` draws for the real one are drawn here.
private struct OverlayPreviewCard: View {
    let mode: OverlayMode
    let frame: OverlayPreviewFrame

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug + DS.Space.hair) {
            HStack(spacing: DS.Space.roomy - DS.Space.hair) {
                HStack(spacing: DS.Space.snug) {
                    HUDGlyph(kind: glyph)
                    Eyebrow(statusText, color: DS.Color.ink)
                }
                .fixedSize()
                Readout(text: counterText)
                    .foregroundStyle(frame.phase == .processing ? DS.Color.dim : DS.Color.inkSecondary)
                VUMeter(level: frame.level, isActive: frame.phase == .recording)
                    .frame(width: VUMeter.naturalWidth, height: DS.Material.meterDotSize * 2)
                Spacer(minLength: 0)
            }
            if showsWords {
                words
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: DS.Material.overlayWordsMaxHeight, alignment: .bottom)
                    .clipped()
            }
        }
        .padding(.horizontal, DS.Space.hudPadX)
        .padding(.vertical, DS.Space.hudPadY)
        .frame(width: DS.Material.hudWidth, alignment: .leading)
        .background(DS.Color.hudGlass, in: RoundedRectangle(cornerRadius: DS.Radius.hud))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.hud).strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
        .environment(\.colorScheme, .dark)
    }

    private var glyph: HUDGlyph.Kind {
        switch frame.phase {
        case .processing: .busy
        case .error: .warning
        case .recording, .hidden: .dot
        }
    }

    private var statusText: String {
        switch frame.phase {
        case .processing: "Processing"
        case .error: "Error"
        case .recording, .hidden: "Rec"
        }
    }

    private var counterText: String {
        let total = Int(frame.seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Minimal hides the words, as the real overlay does; an error always shows.
    private var showsWords: Bool {
        if case .error = frame.phase { return true }
        return mode == .live
    }

    @ViewBuilder
    private var words: some View {
        if case .error(let message) = frame.phase {
            plain(message, color: DS.Color.ink)
        } else if frame.words.isEmpty {
            plain(frame.phase == .processing ? "Transcribing" : "Listening", color: DS.Color.inkSecondary)
        } else {
            WordFlowText(target: frame.words, paced: frame.phase == .recording)
                .id(frame.run)
                .foregroundStyle(frame.phase == .processing ? DS.Color.inkSecondary : DS.Color.ink)
        }
    }

    private func plain(_ text: String, color: Color) -> some View {
        Text(text)
            .font(DS.Font.transcript)
            .foregroundStyle(color)
            .lineSpacing(DS.Space.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Where the words land: a text box standing in for whatever app you are dictating into.
/// Long text keeps its end in view, the part that was just pasted.
private struct PreviewField: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Text("A text box".uppercased())
                .font(DS.Font.micro)
                .tracking(DS.Font.microTracking)
                .foregroundStyle(DS.Color.dim)
            Spacer(minLength: 0)
            Group {
                if text.isEmpty {
                    Text("Your words are pasted here")
                        .foregroundStyle(DS.Color.placeholder)
                } else {
                    Text(text)
                        .foregroundStyle(DS.Color.ink)
                }
            }
            .font(DS.Font.body)
            .lineLimit(2)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Control.fieldPadX)
        .padding(.vertical, DS.Control.fieldPadY)
        .frame(height: DS.Material.overlayFieldHeight)
        .background(DS.Color.previewField, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

// MARK: - Hold to talk

/// Pressed and held, it dictates; released, it stops. It inverts while held, so the press
/// is visible without anything moving. A gesture the system cancels (an alert stealing the
/// mouse) counts as a release, so the run can never stay open with no hand on the button.
private struct HoldToTalkButton: View {
    let isEnabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @GestureState private var isHeld = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Control.iconGap) {
            CarbonIcon(name: "microphone", size: DS.Control.iconSize)
            Text("Hold to talk").font(DS.Font.body)
        }
        .foregroundStyle(isHeld ? DS.Color.inkOnInverted : DS.Color.ink)
        .padding(.horizontal, DS.Control.padX)
        .frame(height: DS.Control.height)
        .background(fill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(isHovering || isHeld ? DS.Color.borderStrong : DS.Color.border, lineWidth: DS.Border.hairline)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isHeld) { _, held, _ in held = true }
        )
        .onChange(of: isHeld) { _, held in
            if held { onPress() } else { onRelease() }
        }
        .allowsHitTesting(isEnabled || isHeld)
        .opacity(isEnabled || isHeld ? 1 : DS.Border.disabledOpacity)
        .onHover { isHovering = $0 }
        .handCursor()
        .accessibilityLabel("Hold to talk")
        .accessibilityAddTraits(.isButton)
    }

    private var fill: Color {
        if isHeld { return DS.Color.gray1000 }
        return isHovering ? DS.Color.hoverFill : DS.Color.controlFill
    }
}
