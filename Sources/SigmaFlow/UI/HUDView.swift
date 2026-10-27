import AppKit
import SwiftUI

/// The dictation overlay, to Paper board 12: a card on real glass, anchored above the Dock
/// and growing upward from a fixed bottom edge. Nothing in it blinks.
///
/// Status row on top: a glyph, a label, the timer, the meter. The glyph is a steady dot
/// while listening, a lock when hands-free, a static ring while transcribing. No hint text
/// in any state: the way out of a lock is the hotkey, any key, or Esc, and the user knows
/// it. The words sit under the row when the overlay mode allows it; `HUDPanel` resizes to
/// fit and keeps the bottom edge anchored.
struct HUDView: View {
    @Bindable var controller: DictationController
    /// The card's measured height, for `HUDPanel` to size the window to.
    var onHeightChange: @MainActor (CGFloat) -> Void = { _ in }

    @State private var settings = Settings.shared
    @State private var startedAt: Date?
    @State private var elapsed: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug + DS.Space.hair) {
            statusRow
            if showsTranscript {
                transcriptView
            }
        }
        .padding(.horizontal, DS.Space.hudPadX)
        .padding(.vertical, DS.Space.hudPadY)
        .frame(width: DS.Material.hudWidth, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        // The card sits at the top of a canvas taller than itself; the window shows only the
        // card's height of it.
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onChange(of: controller.state.isActive, initial: true) { _, active in
            startedAt = active ? Date() : nil
            if !active { elapsed = 0 }
        }
        .task(id: startedAt) {
            guard let startedAt else { return }
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: Status row

    @ViewBuilder
    private var statusRow: some View {
        if let writing = controller.writing {
            // Autowrite after the key comes up (O6.2 to O6.4): no timer, no meter.
            HStack(spacing: DS.Space.snug) {
                HUDGlyph(kind: writing.phase == .writing ? .busy : writing.phase == .copied ? .done : .warning)
                Eyebrow(Self.writingLabel(writing.phase), color: DS.Color.ink)
                Spacer(minLength: 0)
            }
        } else if let activity = controller.styleActivity {
            // A style rewrite borrows the overlay: no timer, no meter, nothing recording.
            HStack(spacing: DS.Space.snug) {
                HUDGlyph(kind: activity.isError ? .warning : .busy)
                Eyebrow(activity.isError ? "Style failed" : activity.name, color: DS.Color.ink)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: DS.Space.roomy - DS.Space.hair) {
                HStack(spacing: DS.Space.snug) {
                    HUDGlyph(kind: glyph)
                    Eyebrow(statusText, color: DS.Color.ink)
                }
                .fixedSize()
                Readout(text: counterText)
                    .foregroundStyle(controller.state == .finishing ? DS.Color.dim : DS.Color.inkSecondary)
                VUMeter(level: controller.level, isActive: controller.state == .listening)
                    .frame(width: VUMeter.naturalWidth, height: DS.Material.meterDotSize * 2)
                Spacer(minLength: 0)
            }
        }
    }

    private var glyph: HUDGlyph.Kind {
        switch controller.state {
        // Autowrite's pen in place of the dot (round 3, 4-01): the one mark that always
        // means recording says this time SigmaFlow will write.
        case .starting, .listening: controller.isWriting ? .pen : controller.isLatched ? .lock : .dot
        case .finishing: .busy
        case .error: .warning
        case .idle: .dot
        }
    }

    private var statusText: String {
        switch controller.state {
        case .starting, .listening:
            controller.isWriting ? "Autowrite"
                : controller.isLatched ? "Locked" : (controller.isPowerHeld ? "Rec in Power mode" : "Rec")
        case .finishing: controller.isWriting ? "Autowrite" : "Processing"
        case .error: "Error"
        case .idle: ""
        }
    }

    private var counterText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func writingLabel(_ phase: DictationController.Writing.Phase) -> String {
        switch phase {
        case .writing: "Autowrite"
        case .copied: "Copied"
        case .failed: "Couldn’t write"
        }
    }

    // MARK: Words

    /// Minimal mode hides the words; error messages and style activity always show.
    private var showsTranscript: Bool {
        // Autowrite always shows its words: what you ask is the whole point of it.
        if controller.writing != nil || controller.isWriting { return true }
        if controller.styleActivity != nil { return true }
        if case .error = controller.state { return true }
        return settings.overlayMode == .live
    }

    /// While Autowrite listens and writes, the screen it read sits beside the words, small
    /// (round 3, 4-09): proof it is looking, and at what.
    @ViewBuilder
    private var transcriptView: some View {
        if let picture = controller.screenPicture,
           controller.isWriting || controller.writing?.phase == .writing {
            HStack(alignment: .top, spacing: DS.Space.snug + DS.Space.hair) {
                ScreenThumb(image: picture)
                transcriptContent
            }
        } else {
            transcriptContent
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if let writing = controller.writing {
            WritingWords(writing: writing)
        } else if let activity = controller.styleActivity {
            words(activity.message, color: DS.Color.ink)
        } else {
            switch controller.state {
            case .error(let message):
                words(message, color: DS.Color.ink)
            case .idle:
                EmptyView()
            default:
                if controller.transcript.isEmpty {
                    // Batch models transcribe in one pass on release, so there is nothing to
                    // show until it lands; say what is happening rather than show an empty card.
                    words(controller.state == .finishing ? "Transcribing" : "Listening", color: DS.Color.inkSecondary)
                } else {
                    WordFlowText(
                        target: controller.transcript,
                        paced: controller.state == .listening || controller.state == .starting
                    )
                    .foregroundStyle(controller.state == .finishing ? DS.Color.inkSecondary : DS.Color.ink)
                }
            }
        }
    }

    private func words(_ text: String, color: Color) -> some View {
        Text(text)
            .font(DS.Font.transcript)
            .foregroundStyle(color)
            .lineSpacing(DS.Space.tight)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Autowrite's words in the overlay (4A): what you asked, dim,
/// over the writing as it arrives; then the whole of it, or why it couldn't write. Long
/// writing keeps its newest lines in view.
struct WritingWords: View {
    let writing: DictationController.Writing
    /// The words' own height. A `maxHeight` frame alone would grow to its limit inside the
    /// overlay's tall canvas, so the cap is applied to what was measured.
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            if writing.phase == .writing {
                line(writing.ask, color: DS.Color.dim)
            }
            if !writing.text.isEmpty {
                line(writing.text, color: DS.Color.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(height: min(height, DS.Material.writeWordsMaxHeight), alignment: .bottom)
        .clipped()
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(DS.Font.transcript)
            .foregroundStyle(color)
            .lineSpacing(DS.Space.tight)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The screen Autowrite read, as a small picture with a 1 px edge.
struct ScreenThumb: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: DS.Material.writeThumbWidth, height: DS.Material.writeThumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
    }
}

/// The small mark at the head of the status row. A dot, a lock, a static ring, a warning,
/// a tick, a pen. None of them move.
struct HUDGlyph: View {
    enum Kind { case dot, lock, busy, warning, done, pen }
    let kind: Kind

    var body: some View {
        switch kind {
        case .dot:
            Circle()
                .fill(DS.Color.ink)
                .frame(width: DS.Control.hudDot, height: DS.Control.hudDot)
                .frame(width: DS.Control.hudGlyph, height: DS.Control.hudGlyph)
        case .lock:
            LockMark()
                .frame(width: DS.Control.hudGlyph, height: DS.Control.hudGlyph)
        case .busy:
            CarbonIcon(name: "circle-dash", size: DS.Control.hudGlyph)
                .foregroundStyle(DS.Color.ink)
        case .warning:
            CarbonIcon(name: "warning", size: DS.Control.hudGlyph)
                .foregroundStyle(DS.Color.ink)
        case .done:
            CarbonIcon(name: "checkmark", size: DS.Control.hudGlyph)
                .foregroundStyle(DS.Color.ink)
        case .pen:
            CarbonIcon(name: "edit", size: DS.Control.hudGlyph)
                .foregroundStyle(DS.Color.ink)
        }
    }
}

/// A padlock drawn from two shapes, so it matches the dot's weight rather than an icon set.
private struct LockMark: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                // Shackle
                Path { path in
                    path.addArc(center: CGPoint(x: w / 2, y: h * 0.34), radius: w * 0.26,
                                startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                }
                .stroke(DS.Color.ink, lineWidth: DS.Border.hairline * 1.4)
                .frame(height: h * 0.5)
                .frame(maxHeight: .infinity, alignment: .top)
                // Body
                RoundedRectangle(cornerRadius: DS.Space.hair)
                    .fill(DS.Color.ink)
                    .frame(width: w * 0.8, height: h * 0.52)
            }
        }
    }
}
