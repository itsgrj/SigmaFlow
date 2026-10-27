import SwiftUI

/// FLOW: the engine's chunked snapshots land in a queue, and a metronome releases one
/// word every 130ms with a soft blur-in — so text arrives at a steady human pace instead
/// of in bursts. Words already on screen never move; when a streaming engine revises
/// earlier words they're swapped silently, with no animation, because animating a
/// correction draws attention to the model being wrong.
///
/// "Make room": a word that wraps onto a new line makes the overlay grow, and `HUDPanel`
/// glides the window up to fit. That word waits for most of the glide before it drifts
/// in, and every word after it queues behind it (`revealGate`), so the words never
/// arrive out of order.
struct WordFlowText: View {
    /// The full transcript so far — engines send snapshots, not deltas.
    let target: String
    /// Steady drip while listening. False flushes the queue at once (the final text).
    let paced: Bool

    private struct Word: Identifiable {
        let id: Int
        var text: String
    }

    @State private var shown: [Word] = []
    @State private var queue: [String] = []
    @State private var nextID = 0
    /// No word drifts in before this moment; a word opening a new line pushes it out.
    @State private var revealGate = Date.distantPast

    /// Words made with the view, not dripped in after: they draw already settled.
    @State private var settledBelow = 0

    /// The first word is in place from the very first frame. Without it the flow draws
    /// one frame with no height, and the overlay would dip a line and glide back up.
    ///
    /// `returning`: the text was on screen before (a live-notes line scrolled back into
    /// view), so unpaced, every word is in place and settled. The entrance is for words
    /// arriving, not for words coming back. The HUD never passes it: a batch model's text
    /// lands unpaced and should still drift in.
    init(target: String, paced: Bool, returning: Bool = false) {
        self.target = target
        self.paced = paced
        let words = target.split(separator: " ").map(String.init)
        let initial = returning && !paced ? words : Array(words.prefix(1))
        _shown = State(initialValue: initial.enumerated().map { Word(id: $0.offset, text: $0.element) })
        _nextID = State(initialValue: initial.count)
        _settledBelow = State(initialValue: returning && !paced ? initial.count : 0)
    }

    var body: some View {
        WrapLayout(spacing: 4, lineSpacing: 3) {
            ForEach(shown) { word in
                FlowWord(
                    text: word.text,
                    waitsForRoom: paced && word.id != shown.first?.id,
                    settled: word.id < settledBelow,
                    gate: $revealGate
                )
            }
        }
        .coordinateSpace(.named(FlowWord.space))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: target, initial: true) { _, new in sync(to: new) }
        .onChange(of: paced) { _, isPaced in
            if !isPaced { flush() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(130))
                dripOne()
            }
        }
    }

    private func dripOne() {
        guard !queue.isEmpty else { return }
        // No animation on the insert: the layout takes its new size at once, so the window
        // can glide to it, and the word handles its own entrance.
        shown.append(Word(id: nextID, text: queue.removeFirst()))
        nextID += 1
    }

    private func flush() {
        guard !queue.isEmpty else { return }
        for text in queue {
            shown.append(Word(id: nextID, text: text))
            nextID += 1
        }
        queue = []
    }

    private func sync(to target: String) {
        let words = target.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        // Silent correction: shown words the engine revised are swapped in place, and
        // text that no longer exists is dropped without ceremony.
        if words.count < shown.count {
            shown = Array(shown.prefix(words.count))
        }
        for index in shown.indices where shown[index].text != words[index] {
            shown[index].text = words[index]
        }

        queue = Array(words.dropFirst(shown.count))
        if !paced { flush() }
    }
}

/// Left-aligned wrapping layout. SwiftUI has no native flow layout, and per-word
/// transitions need every word to be its own view.
struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct BlurFade: ViewModifier {
    /// 1 = fully hidden, 0 = settled.
    let progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .blur(radius: progress * 3)
            .offset(y: progress * 3)
    }
}

/// One word of the flow. It is laid out at once but drawn hidden, then blurs into focus
/// with a 3pt rise. Settles once; never loops.
///
/// Whether it opened a new line is read from where `WrapLayout` put it: the first word of
/// every line sits at x = 0. Such a word holds back for `DS.Motion.hudLineWait` so the
/// window's glide makes the room first, and moves the shared gate so the words after it
/// queue behind. If the position never arrives, the word simply doesn't wait.
private struct FlowWord: View {
    static let space = "wordFlow"

    let text: String
    let waitsForRoom: Bool
    let settled: Bool
    @Binding var gate: Date

    @State private var opensLine = false
    @State private var revealed: Bool

    init(text: String, waitsForRoom: Bool, settled: Bool = false, gate: Binding<Date>) {
        self.text = text
        self.waitsForRoom = waitsForRoom
        self.settled = settled
        _gate = gate
        _revealed = State(initialValue: settled)
    }

    var body: some View {
        Text(text)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.ink)
            .modifier(BlurFade(progress: revealed ? 0 : 1))
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.frame(in: .named(Self.space)).minX < 1
            } action: { opensLine = $0 }
            .task {
                guard !revealed else { return }
                // One frame, so the layout has placed the word before it is asked where.
                try? await Task.sleep(for: .milliseconds(16))
                let now = Date()
                if waitsForRoom && opensLine {
                    gate = max(gate, now.addingTimeInterval(DS.Motion.hudLineWait))
                }
                let wait = gate.timeIntervalSince(now)
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: waitsForRoom ? DS.Motion.wordFlow : DS.Motion.wordFlush)) {
                    revealed = true
                }
            }
    }
}
