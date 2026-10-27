import AppKit
import SwiftUI

/// Settings, to Figma windows 27, 27B and 27C: three tabs, one card each. Dictation is
/// how SigmaFlow listens and cleans up; Connections lets Claude read your dictations;
/// Your data is the folder you can carry to another Mac.
///
/// Settings save on change, as every Mac preferences pane does. There is no Save button.
/// The rewrite engine lives on the Styles page and the learning switch on the Dictionary
/// page; neither is here.
struct SettingsPage: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    enum Tab: String { case dictation, connections, data }

    // Microphone
    @State private var microphones: [MicrophoneDevice] = []

    // Connections
    @State private var claude = ClaudeConnection.shared

    // Your data
    @State private var library = MeetingLibrary.shared
    @State private var dataOutcome: DataOutcome?
    @State private var pendingImport: (folder: URL, manifest: DataPortability.Manifest)?

    // Custom-shortcut capture
    @State private var isCapturing = false
    @State private var captureHint = ""
    @State private var captureMonitor: Any?

    enum DataOutcome: Equatable {
        case exported(URL)
        case imported(String)
        case failed(String)
    }

    /// The popup's three choices; the custom combo itself lives in Settings.
    private enum HotkeyChoice: String, CaseIterable {
        case rightOption, rightCommand, custom
    }

    /// Clean up what you say: one popup, three answers.
    private enum CleanupChoice: String, CaseIterable {
        case off, basic, smart
    }

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: settings.openTabs["settings"] ?? "") ?? .dictation },
            set: { settings.openTabs["settings"] = $0.rawValue }
        )
    }

    var body: some View {
        PageScroll {
            PageHeader(
                "Settings",
                subtitle: "How SigmaFlow listens, cleans up what you say, and connects to the services you choose."
            )
            TabStrip(
                tabs: [(.dictation, "Dictation"), (.connections, "Connections"), (.data, "Your data")],
                selection: tab
            )
        } content: {
            switch tab.wrappedValue {
            case .dictation: dictationCard
            case .connections: connectionsCard
            case .data:
                folderCard
                dataCard
            }
        }
        .onAppear {
            microphones = MicrophoneDevices.all()
            claude.refresh()
        }
        .onDisappear { endCapture() }
    }

    // MARK: - Dictation

    private var dictationCard: some View {
        Card {
            if !controller.hotkeyArmed { hotkeyWarning }

            CardRow("Push-to-talk key", caption: "Hold to dictate. Double-tap to latch.") {
                PopupButton(selection: hotkeyChoice, options: [
                    (.rightOption, "Right Option ⌥"),
                    (.rightCommand, "Right Command ⌘"),
                    (.custom, "Custom shortcut"),
                ])
            }
            if isCustomSelected || isCapturing {
                customShortcutRow
            }

            // Right ⌥ is the send key because it sits beside Right ⌘; with any other
            // push-to-talk key there is no neighbour to hold, so the switch waits.
            CardRow("Power mode", caption: powerModeAvailable
                // No-break spaces keep each key name on one line when the caption wraps.
                ? "When turned on, you will be able to auto-send your messages. Hold Right\u{00A0}⌥ with Right\u{00A0}⌘ together."
                : "Works when your push-to-talk key is Right\u{00A0}⌘.") {
                settingsToggle($settings.powerMode)
                    .disabled(!powerModeAvailable)
            }

            CardRow("Ask to record calls") {
                settingsToggle($settings.askToRecordCalls)
            }

            CardRow("Microphone", caption: "Which input records. Plug one in and it appears here.") {
                PopupButton(selection: microphoneSelection, options: microphoneOptions)
            }

            // Two tiles you can try with your own voice, not a popup (overlay-preview-options.html).
            OverlayChooser(controller: controller)

            CardRow("Clean up what you say", caption: cleanupCaption) {
                PopupButton(selection: cleanupChoice, options: [
                    (.off, "Off"),
                    (.basic, "Basic fixes"),
                    (.smart, "With Apple Intelligence"),
                ], width: DS.Control.popupWidthWide)
            }

            // The sound pickers belong to the Sound row, so no line sits between them.
            CardRow("Sound", caption: soundCaption, isLast: true) {
                settingsToggle($settings.soundEnabled)
            }
            if settings.soundEnabled { soundPickers }
            CardDivider()

            CardRow("Pause media while recording", caption: "Music or video pauses while you talk.", isLast: true) {
                settingsToggle($settings.pauseMediaWhileRecording)
            }
        }
    }

    private func settingsToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DS.Color.blue700)
    }

    // MARK: Cleanup

    private var cleanupChoice: Binding<CleanupChoice> {
        Binding(
            get: {
                if !settings.cleanupEnabled { return .off }
                return settings.smartCleanup ? .smart : .basic
            },
            set: { choice in
                switch choice {
                case .off:
                    settings.cleanupEnabled = false
                case .basic:
                    settings.cleanupEnabled = true
                    settings.smartCleanup = false
                case .smart:
                    settings.cleanupEnabled = true
                    settings.smartCleanup = true
                }
            }
        )
    }

    private var cleanupCaption: String {
        switch cleanupChoice.wrappedValue {
        case .off:
            "Typed exactly as heard."
        case .basic:
            "Removes umms and false starts. Capitals and punctuation follow your default style."
        case .smart:
            FoundationModelFormatter.isAvailable
                ? "Also fixes punctuation, applies your self-corrections and formats lists. Adds a few seconds after you release."
                : (FoundationModelFormatter.unavailableReason ?? "Needs a Mac with Apple Intelligence turned on.")
        }
    }

    // MARK: Sound

    private var soundCaption: String {
        settings.soundEnabled ? "\(settings.startSound) on start, \(settings.stopSound) on stop." : "Nothing plays when recording starts or stops."
    }

    /// Picking a sound plays it, because choosing a tick you cannot hear is guesswork.
    private var soundPickers: some View {
        HStack(spacing: DS.Space.base) {
            Spacer(minLength: 0)
            Eyebrow("Start")
            PopupButton(selection: $settings.startSound, options: soundOptions, width: DS.Control.popupWidthSound)
                .onChange(of: settings.startSound) { _, name in SystemSounds.play(name) }
            Eyebrow("Stop")
            PopupButton(selection: $settings.stopSound, options: soundOptions, width: DS.Control.popupWidthSound)
                .onChange(of: settings.stopSound) { _, name in SystemSounds.play(name) }
        }
        .padding(.top, DS.Space.soundPickersTop)
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.bottom, DS.Space.rowPadX)
    }

    private var soundOptions: [(String, String)] {
        SystemSounds.available.map { ($0, $0) }
    }

    // MARK: Microphone

    /// The last item of the microphone popup re-reads the devices instead of choosing one.
    private static let refreshTag = "__refresh__"

    private var microphoneOptions: [(String, String)] {
        [("", "System default")] + microphones.map { ($0.id, $0.name) } + [(Self.refreshTag, "Refresh list")]
    }

    private var microphoneSelection: Binding<String> {
        Binding(
            get: { settings.microphoneID ?? "" },
            set: { chosen in
                if chosen == Self.refreshTag {
                    microphones = MicrophoneDevices.all()
                } else {
                    settings.microphoneID = chosen.isEmpty ? nil : chosen
                }
            }
        )
    }

    // MARK: Push-to-talk

    private var isCustomSelected: Bool {
        if case .custom = settings.pushToTalkKey { return true }
        return false
    }

    private var powerModeAvailable: Bool { settings.pushToTalkKey == .rightCommand }

    private var hotkeyChoice: Binding<HotkeyChoice> {
        Binding(
            get: {
                switch settings.pushToTalkKey {
                case .rightOption: .rightOption
                case .rightCommand: .rightCommand
                case .custom: .custom
                }
            },
            set: { choice in
                switch choice {
                case .rightOption: select(.rightOption)
                case .rightCommand: select(.rightCommand)
                case .custom:
                    if let combo = settings.savedCustomCombo {
                        select(.custom(combo))
                    } else {
                        beginCapture()
                    }
                }
            }
        )
    }

    /// Under the popup when Custom is chosen: the recorder, and what it last recorded.
    private var customShortcutRow: some View {
        CardContentRow {
            HStack(spacing: DS.Space.base) {
                AppButton(title: isCapturing ? "Press your keys" : "Record shortcut", kind: .secondary) { beginCapture() }
                if !captureHint.isEmpty {
                    Caption(captureHint)
                } else if let combo = settings.savedCustomCombo, !isCapturing {
                    KeyChip(text: combo.display)
                    Caption("Any modifiers with a key, like ⌃⌥D.")
                } else {
                    Caption("Any modifiers with a key, like ⌃⌥D.")
                }
            }
        }
    }

    /// Shown when the keyboard tap couldn't be installed. macOS ties the Accessibility
    /// grant to the app's signature, so a rebuild can silently revoke it; this is the
    /// visible symptom instead of shortcuts that just go dead.
    private var hotkeyWarning: some View {
        CardContentRow {
            HStack(spacing: DS.Space.roomy) {
                VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                    Text("SigmaFlow can't watch the keyboard, so no shortcut works.")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                    Caption("Turn SigmaFlow off and on in the Accessibility list, then open the app again.")
                }
                Spacer()
                AppButton(title: "Open Accessibility settings", kind: .secondary) {
                    Permissions.openAccessibilitySettings()
                }
            }
        }
    }

    private func select(_ key: PushToTalkKey) {
        endCapture()
        settings.pushToTalkKey = key
        controller.reloadHotkey()
    }

    /// Waits for one real keystroke and records it. Modifier-only presses are ignored so
    /// the user can settle the modifiers first; a keystroke with no modifiers is refused,
    /// since a bare letter as a global hotkey would swallow that letter everywhere.
    private func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        captureHint = ""
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { finishCapture(with: event) }
            return nil  // the recorded keystroke shouldn't also type into the window
        }
    }

    private func finishCapture(with event: NSEvent) {
        let flags = event.modifierFlags
        let hasModifier = flags.contains(.control) || flags.contains(.option)
            || flags.contains(.shift) || flags.contains(.command)
        guard hasModifier else {
            captureHint = "Add at least one modifier: ⌃, ⌥, ⇧ or ⌘."
            return
        }

        var display = ""
        if flags.contains(.control) { display += "⌃" }
        if flags.contains(.option) { display += "⌥" }
        if flags.contains(.shift) { display += "⇧" }
        if flags.contains(.command) { display += "⌘" }
        display += Self.keyName(for: event)

        let combo = HotkeyCombo(
            keyCode: Int64(event.keyCode),
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift),
            command: flags.contains(.command),
            display: display
        )
        endCapture()
        settings.savedCustomCombo = combo
        select(.custom(combo))
    }

    private func endCapture() {
        if let captureMonitor { NSEvent.removeMonitor(captureMonitor) }
        captureMonitor = nil
        isCapturing = false
        captureHint = ""
    }

    private static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Esc"
        case 51: return "Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let name = (event.charactersIgnoringModifiers ?? "").uppercased()
            return name.isEmpty ? "Key \(event.keyCode)" : name
        }
    }

    // MARK: - Connections

    private var connectionsCard: some View {
        Card {
            CardRow("Claude Desktop", caption: claudeCaption, data: claude.status == .connected ? "Connected" : nil) {
                switch claude.status {
                case .connected:
                    AppButton(title: "Disconnect", icon: "close") { claude.disconnect() }
                case .notConnected, .failed:
                    AppButton(title: "Add to Claude", kind: .secondary, icon: "add") { claude.connect() }
                case .claudeNotInstalled:
                    EmptyView()
                }
            }
            CardRow("Claude Code", caption: "Paste one command in the terminal and Claude Code can read your dictations too.") {
                CopyButton(text: "claude mcp add sigmaflow -- \(ClaudeConnection.helperURL.path)", title: "Copy command", kind: .secondary)
            }
            CardRow("Other apps", caption: "Any app that speaks MCP can connect with this path.", isLast: true) {
                CopyButton(text: ClaudeConnection.helperURL.path, title: "Copy path", kind: .secondary)
            }
        } footer: {
            CardFooter(hint: "Connected apps read your dictation history on this Mac. Nothing leaves it.") { EmptyView() }
        }
    }

    private var claudeCaption: String? {
        switch claude.status {
        case .connected: "Ask Claude about your dictations."
        case .notConnected: "Lets Claude Desktop search your dictations and answer questions about them."
        case .claudeNotInstalled: "Claude Desktop is not installed on this Mac."
        case .failed(let message): message
        }
    }

    // MARK: - Your data

    /// The SigmaFlow folder, on top, with as few buttons as it can have: the path opens it in
    /// Finder, Change is for after it has moved (docs/mockups/meetings-simple.html tab 05).
    @ViewBuilder
    private var folderCard: some View {
        Card {
            if library.isFolderMissing {
                CardRow(
                    "Can't find your meetings",
                    caption: "Show SigmaFlow where they are now.",
                    isLast: true
                ) {
                    AppButton(title: "Find it", kind: .secondary) { library.pickFolder() }
                }
            } else {
                CardRow(
                    "SigmaFlow folder",
                    caption: "Where your meetings are kept.",
                    isLast: true
                ) {
                    HStack(spacing: DS.Space.snug) {
                        FolderPathButton(path: MeetingsPage.displayPath(library.root?.path)) { library.revealRoot() }
                        AppButton(title: "Change", kind: .secondary) { library.pickFolder() }
                    }
                }
            }
        }
    }

    private var dataCard: some View {
        Card {
            CardRow("Meetings", data: library.meetings.count.formatted())
            CardRow("Transcriptions", data: RunStore.shared.runs.count.formatted())
            CardRow("Dictionary", data: "\(DictionaryStore.shared.entries.count.formatted()) word\(DictionaryStore.shared.entries.count == 1 ? "" : "s")")
            CardRow("Snippets", data: SnippetStore.shared.snippets.count.formatted())
            CardRow("Styles", data: StyleStore.shared.styles.count.formatted())
            CardRow("Settings", data: "Saved")
            CardRow("API keys", data: "Kept in the Mac's Keychain, never exported", isLast: pendingImport == nil && dataOutcome == nil)
            if let pendingImport {
                importPrompt(pendingImport)
            } else if let dataOutcome {
                outcomeRow(dataOutcome)
            }
        } footer: {
            CardFooter(hint: "Moving to another Mac? Export takes your dictionary, snippets, styles and settings.") {
                AppButton(title: "Import a folder", kind: .secondary) { beginImport() }
                AppButton(title: "Export", kind: .inverted) { runExport() }
            }
        }
    }

    /// Import asks whether to merge into this Mac or replace everything here before it
    /// touches anything.
    private func importPrompt(_ pending: (folder: URL, manifest: DataPortability.Manifest)) -> some View {
        CardContentRow(isLast: true) {
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                Eyebrow("Found in \(pending.folder.lastPathComponent)")
                Caption("\(pending.manifest.summary). This Mac has \(RunStore.shared.runs.count) transcriptions, \(DictionaryStore.shared.entries.count) dictionary words, \(SnippetStore.shared.snippets.count) snippets and \(StyleStore.shared.styles.count) styles.")
                HStack(spacing: DS.Space.snug) {
                    AppButton(title: "Merge into this Mac", kind: .secondary) {
                        dataOutcome = .imported(DataPortability.merge(pending.manifest))
                        pendingImport = nil
                    }
                    AppButton(title: "Replace everything here", kind: .secondary) {
                        dataOutcome = .imported(DataPortability.replace(with: pending.manifest))
                        pendingImport = nil
                        controller.reloadHotkey()
                    }
                    AppButton(title: "Cancel") { pendingImport = nil }
                }
            }
        }
    }

    private func outcomeRow(_ outcome: DataOutcome) -> some View {
        CardContentRow(isLast: true) {
            HStack(spacing: DS.Space.base) {
                switch outcome {
                case .exported(let url):
                    StatusLine(text: "Exported to \(url.path)")
                    AppButton(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                case .imported(let message):
                    StatusLine(text: message)
                case .failed(let message):
                    StatusLine(text: message, icon: "warning")
                }
                Spacer()
                AppButton(title: "Dismiss") { dataOutcome = nil }
            }
        }
    }

    private func runExport() {
        do {
            dataOutcome = .exported(try DataPortability.export())
        } catch {
            dataOutcome = .failed(error.localizedDescription)
        }
    }

    private func beginImport() {
        guard let folder = DataPortability.chooseFolder() else { return }
        do {
            pendingImport = (folder, try DataPortability.read(folder))
            dataOutcome = nil
        } catch {
            dataOutcome = .failed(error.localizedDescription)
        }
    }
}

/// The Settings scene (⌘,) shows the same page in its own window.
struct SettingsWindow: View {
    @Bindable var controller: DictationController

    var body: some View {
        SettingsPage(controller: controller)
            .background { BackgroundImage() }
            .frame(width: DS.Material.settingsWindowWidth, height: DS.Material.settingsWindowHeight)
            .preferredColorScheme(.dark)
    }
}

/// The SigmaFlow folder's path with a folder in front: the path is the button. Pressing it
/// opens the folder in Finder.
private struct FolderPathButton: View {
    let path: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.snug) {
                CarbonIcon(name: "folder", size: DS.Control.iconSizeTiny)
                    .foregroundStyle(DS.Color.inkSecondary)
                Text(path)
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.ink)
            }
            .padding(.horizontal, DS.Control.padXQuiet)
            .frame(height: DS.Control.height)
            .background(isHovering ? DS.Color.hoverFill : DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(
                isHovering ? DS.Color.borderStrong : DS.Color.border, lineWidth: DS.Border.hairline))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .help("Open in Finder")
        .onHover { isHovering = $0 }
        .handCursor()
    }
}
