import SwiftUI

/// Autowrite, its own page after Styles (docs/mockups/autowrite-page.html, round 1 1-03 2A
/// 3A, round 2 B down the page, round 3 words). The steps run down the left on the painting,
/// numbered and joined by a line, with no card: only what you can change gets one. On the
/// right, the key, the AI model and the custom instructions. The model is the Styles page's
/// and is changed there, so there is one model setting, not two. Nothing on the page scrolls.
struct AutowritePage: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    /// The custom instructions as typed; Autowrite reads them only once Save is pressed
    /// (Gokul, 27 Oct 2026: typing gave no sign anything was kept). Leaving the page drops
    /// an unsaved edit, like a style left unsaved.
    @State private var draft = ""
    @State private var didSave = false

    private var engine: StyleEngineChoice { settings.styleEngine }
    private var key: PushToTalkKey { WriteKey.key(besides: settings.pushToTalkKey) }

    var body: some View {
        ListPage {
            PageHeader(
                "Autowrite",
                subtitle: "Tell SigmaFlow what to write, out loud. It reads your screen to understand what you’re replying to, then types the text into the app you’re using."
            )
            HStack(alignment: .top, spacing: DS.Space.panel) {
                steps
                    .frame(width: DS.Material.writeStepsWidth, alignment: .leading)
                VStack(spacing: DS.Space.roomy) {
                    setup
                    instructions
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            Step(
                number: 1,
                title: Text("Click where the text should go"),
                detail: "A reply box, an email, a chat, a document. Any app works."
            )
            Step(
                number: 2,
                title: Text("Hold \(Text(key.displayName).font(DS.Font.mono)) and say what you want SigmaFlow to write"),
                detail: "For example: “Reply to John. Thursday works, but not before 11.”"
            )
            Step(
                number: 3,
                title: Text("Let go of the key"),
                detail: "SigmaFlow reads what’s on your screen, understands the context, like the email you’re answering, and writes the response."
            )
            Step(
                number: 4,
                title: Text("Check it, then send it yourself"),
                detail: "The text appears where you clicked. SigmaFlow never sends anything. If you didn’t click into a text box, the text is copied so you can paste it.",
                isLast: true
            )
        }
    }

    private var setup: some View {
        Card {
            CardRow("Key", caption: keyCaption) {
                KeyChip(text: key.displayName)
            }
            CardRow("AI model", caption: engineCaption, isLast: true) {
                AppButton(title: "Open Styles") { openStyles() }
            }
        }
    }

    private var instructions: some View {
        Card {
            CardRow(
                "Custom instructions",
                caption: "SigmaFlow follows these every time it writes for you: how you like to sound, how you sign off, who people are."
            )
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                InstructionsBox(text: $draft)
                if engine == .apple,
                   WritePrompt.wordCount(draft) > WritePrompt.appleInstructionWords {
                    Caption("Apple Intelligence reads only the first \(WritePrompt.appleInstructionWords) words. Put what matters most first, or switch to Claude on the Styles page.")
                }
                AppButton(
                    title: didSave ? "Saved" : "Save",
                    kind: .secondary,
                    icon: didSave ? "checkmark" : nil,
                    isEnabled: draft != settings.autowriteInstructions
                ) {
                    settings.autowriteInstructions = draft
                    didSave = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(DS.Motion.statusHold))
                        didSave = false
                    }
                }
            }
            .padding(.horizontal, DS.Space.rowPadX)
            .padding(.vertical, DS.Space.rowPadY)
        }
        .frame(maxHeight: .infinity)
        .onAppear { draft = settings.autowriteInstructions }
        // An import replaces what is saved; it replaces the box too unless you're mid-edit.
        .onChange(of: settings.autowriteInstructions) { old, new in
            if draft == old { draft = new }
        }
        .onChange(of: draft) { didSave = false }
    }

    /// Why it's this key: it is always the right-hand key dictation doesn't use.
    private var keyCaption: String {
        switch settings.pushToTalkKey {
        case .rightOption, .rightCommand:
            "Hold it while you talk. Dictation uses \(settings.pushToTalkKey.displayName), so Autowrite uses \(key.displayName)."
        case .custom:
            "Hold it while you talk."
        }
    }

    private var engineCaption: String {
        guard engine.hasKey else {
            let provider = engine == .claude ? "Anthropic" : engine.shortName
            return "\(engine.shortName) needs your \(provider) key before it can write. Add it on the Styles page."
        }
        return "\(engine.shortName) writes your text. Your styles use the same model, so you change it on the Styles page."
    }

    private func openStyles() {
        settings.openTabs["styles"] = StylesPage.Tab.custom.rawValue
        settings.lastPage = MainWindow.Section.styles.rawValue
    }
}

/// One step: its number in a ring, a line down to the next number, what you do, and a line
/// under it saying more. On the painting, never in a card.
private struct Step: View {
    let number: Int
    let title: Text
    let detail: String
    var isLast = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.roomy) {
            Text(String(number))
                .font(DS.Font.monoSmall)
                .foregroundStyle(DS.Color.ink)
                .frame(width: DS.Material.writeStepNumber, height: DS.Material.writeStepNumber)
                .overlay(Circle().strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                title
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, DS.Space.hair)
        }
        .padding(.bottom, isLast ? 0 : DS.Material.writeStepGap)
        .background(alignment: .topLeading) {
            if !isLast {
                Rectangle()
                    .fill(DS.Color.borderStrong)
                    .frame(width: DS.Border.hairline)
                    .padding(.top, DS.Material.writeStepNumber + DS.Space.tight)
                    .padding(.bottom, DS.Space.tight)
                    .padding(.leading, (DS.Material.writeStepNumber - DS.Border.hairline) / 2)
            }
        }
    }
}

/// The custom instructions: a box that fills the card's height, scrolling inside past it.
/// Styled like `GrowingTextArea`, which grows with its text instead.
private struct InstructionsBox: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.ink)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, DS.Control.fieldPadX - DS.Space.tight)
            .padding(.vertical, DS.Control.fieldPadY)
            .frame(maxWidth: .infinity, minHeight: DS.Material.writeInstructionsMin, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("For example: Keep replies short. Sign emails with my first name. Use British spelling.")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.placeholder)
                        .padding(.horizontal, DS.Control.fieldPadX)
                        .padding(.vertical, DS.Control.fieldPadY)
                        .allowsHitTesting(false)
                }
            }
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
            .background(ClickOutsideEndsEditing())
    }
}

/// Takes the cursor out of the box when you click anywhere else in the window, Save
/// included. AppKit leaves it blinking in the box otherwise (Gokul, 27 Oct 2026). The click
/// itself goes on to whatever it landed on.
private struct ClickOutsideEndsEditing: NSViewRepresentable {
    func makeNSView(context: Context) -> WatchView { WatchView() }
    func updateNSView(_ view: WatchView, context: Context) {}

    final class WatchView: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.endEditingIfOutside(event) }
                return event
            }
        }

        private func endEditingIfOutside(_ event: NSEvent) {
            guard let window, event.window === window,
                  let editor = window.firstResponder as? NSTextView else { return }
            let box = convert(bounds, to: nil)
            // Only this box's own editor: another field keeps its cursor.
            guard editor.convert(editor.bounds, to: nil).intersects(box),
                  !box.contains(event.locationInWindow) else { return }
            window.makeFirstResponder(nil)
        }
    }
}
