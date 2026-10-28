import AppKit
import SwiftUI

@main
struct SigmaFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        Window("SigmaFlow", id: "main") {
            MainWindow(controller: delegate.controller)
        }
        // No title bar: the grey strip would be the one surface that isn't black. The
        // traffic lights float over the sidebar, which leaves room for them.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: DS.Material.windowWidth, height: DS.Material.windowHeight)
        .windowResizability(.contentMinSize)
        // The first open starts on the setup window; this one opens when it is done.
        .defaultLaunchBehavior(Settings.shared.firstOpenDone ? .automatic : .suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                WelcomeCommand(controller: delegate.controller)
                Button("Reveal Dictionary File") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
        }

        // The first open (docs/mockups/onboarding.html): its own small window, before the app.
        Window("Welcome to SigmaFlow", id: "welcome") {
            OnboardingView(controller: delegate.controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Settings.shared.firstOpenDone ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        // Fully qualified: this app has its own `Settings` type, which otherwise shadows
        // SwiftUI's settings scene.
        SwiftUI.Settings {
            SettingsWindow(controller: delegate.controller)
        }

        // Secondary now: status and the hotkey while you're working in another app.
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            // Carbon, like every other icon. The filled recording glyph stays up for the
            // whole meeting so nobody in the room can miss that the mic is open.
            MenuBarGlyph(
                isDictating: delegate.controller.state.isActive,
                isRecordingMeeting: delegate.meetings.isRecording)
                .modifier(MainWindowOpener(delegate: delegate))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    let meetings = MeetingSession.shared
    private var hud: HUDPanel?
    private let spotlight = Spotlight()
    private var stateObservation: NSObjectProtocol?
    /// Recordings opened before the SigmaFlow folder was looked for (a drop on the Dock icon
    /// that launched the app); filed once it has been.
    private var waitingRecordings: [URL] = []
    private var isLaunched = false
    /// Opens the main window when it is closed. Set by the menu bar icon, the one SwiftUI
    /// view that is always drawn, since `openWindow` only exists inside SwiftUI.
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else starts: no hotkeys, no call watching, no SigmaFlow folder.
        if MeetingCheck.runIfRequested() { return }
        if SearchCheck.runIfRequested() { return }
        if WriteCheck.runIfRequested() { return }

        // A regular app now: dock icon, app menu, standard windows. The HUD is still a
        // non-activating panel, so dictating into another app never steals its focus — that
        // property belongs to the panel, not to the activation policy.
        NSApp.setActivationPolicy(.regular)

        hud = HUDPanel(controller: controller)

        // The first open: Right ⌘ becomes the key and Parakeet starts arriving now, before
        // the hotkey is armed below, so the talking step usually finds it already here.
        let isFirstOpen = !Settings.shared.firstOpenDone
        if isFirstOpen { FirstOpen.shared.beginFirstRun(controller: controller) }

        // The SigmaFlow folder: made on the first run, found again on every later one. A
        // recording left behind by a quit mid-meeting is filed now rather than lost.
        MeetingLibrary.shared.locate()
        meetings.recoverUnfiled()
        // Recordings from the Dock and Finder (docs/mockups/meeting-drop-discover.html, 16, 17).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        isLaunched = true
        if !waitingRecordings.isEmpty { addRecordings(waitingRecordings) }
        waitingRecordings = []
        // Dictations sit in the same folder: the first time, the whole history moves in.
        RunLog.settle()
        // Search: lines and pictures not yet read, from recordings made before or while away.
        // Not in a snapshot run, which draws the pages and quits.
        if !CommandLine.arguments.contains("--snapshot-dir") { PictureReader.shared.catchUp() }
        // Watches for a call app opening the microphone, to offer to record the call.
        CallPrompter.shared.start()

        if !controller.activate() {
            // The setup window asks for Accessibility itself, in its own step.
            if !isFirstOpen { Permissions.promptForAccessibility() }
            // The tap can only be created once the user grants Accessibility, and there's
            // no notification for that — poll until it takes.
            retryActivation()
        }

        // Local models take seconds to load from disk, and that cost lands on whichever
        // dictation touches them first — so the first hold after every launch would stall
        // with the HUD showing nothing. Warm the active model in the background instead,
        // but only when it's actually going to be used and is already downloaded.
        let activeModel = Settings.shared.activeModel
        if activeModel != .apple, ModelLibrary.isOnDisk(activeModel) {
            Task.detached(priority: .utility) {
                try? await SpeechModelStores.warm(activeModel)
            }
        }

        observeState()
        Log.app.info("SigmaFlow ready — hold \(Settings.shared.pushToTalkKey.displayName) to dictate")
        WindowSnapshots.runIfRequested(controller: controller)
    }

    /// A recording dropped on the Dock icon, or opened with SigmaFlow from Finder: filed as a
    /// meeting exactly like a drop on the page (pick 16). The Info.plist declares audio and
    /// video at the Alternate rank, so SigmaFlow is offered but never becomes their default app.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        guard isLaunched else {
            waitingRecordings += files
            return
        }
        addRecordings(files)
    }

    /// Finder's right-click Transcribe with SigmaFlow (pick 17), the `NSServices` entry in
    /// the Info.plist; `NSMessage` names this method.
    @objc func transcribeRecordings(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        application(NSApp, open: urls ?? [])
    }

    /// The Meetings page comes forward, so the new row is in view as it transcribes. Before
    /// the first open is done the setup window stays the only window, and the recording is
    /// simply filed.
    private func addRecordings(_ urls: [URL]) {
        if Settings.shared.firstOpenDone {
            Settings.shared.lastPage = MainWindow.Section.meetings.rawValue
            NSApp.activate()
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openMainWindow?()
            }
        }
        MeetingLibrary.shared.add(recordings: urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.deactivate()
        TypedWords.shared.save()
    }

    /// Shows and hides the HUD in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
            _ = controller.styleActivity
            _ = controller.isPreview
            _ = controller.writing
            _ = controller.isWriting
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // A preview run draws in the overlay tiles on Settings, never in the panel.
                let dictating = self.controller.state.isActive && !self.controller.isPreview
                // Autowrite's Copied and Couldn't write outlast the run itself.
                let writingNotice = self.controller.writing != nil && !self.controller.isPreview
                if dictating || writingNotice || self.controller.styleActivity != nil {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                // Autowrite dims all but the window it writes into while it listens and writes.
                if self.controller.isWriting { self.spotlight.show() } else { self.spotlight.hide() }
                self.observeState()
            }
        }
    }

    private func retryActivation() {
        Task { @MainActor in
            while !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            controller.activate()
            Log.app.info("Accessibility granted — hotkey armed")
        }
    }
}

/// App menu: Welcome to SigmaFlow, the setup window again from its first step.
private struct WelcomeCommand: View {
    let controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Welcome to SigmaFlow") {
            FirstOpen.shared.reopen(controller: controller)
            openWindow(id: "welcome")
        }
    }
}

/// Hands the app delegate a way to open the main window, from inside SwiftUI where
/// `openWindow` lives.
private struct MainWindowOpener: ViewModifier {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let open = openWindow
            delegate.openMainWindow = { open(id: "main") }
        }
    }
}

/// The menu bar icon as an NSImage: MenuBarExtra labels can't take a resizable SwiftUI
/// image, so the Carbon SVG is handed over pre-sized.
private struct MenuBarGlyph: View {
    let isDictating: Bool
    let isRecordingMeeting: Bool

    var body: some View {
        let name = isRecordingMeeting ? "recording--filled" : (isDictating ? "microphone--filled" : "microphone")
        if let image = CarbonIconCache.nsImage(named: name, size: 16) {
            Image(nsImage: image)
        } else {
            Text("Σ")
        }
    }
}

private struct MenuContent: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    /// Only models that are actually on this Mac — downloading belongs to the Models page.
    private var readyModels: [SpeechModelID] {
        SpeechModelID.allCases.filter { ModelLibrary.isOnDisk($0) }
    }

    var body: some View {
        Text("Hold \(settings.pushToTalkKey.displayName) to dictate")

        Divider()

        Picker("Model", selection: $settings.activeModel) {
            ForEach(readyModels, id: \.self) { model in
                Text(model.displayName).tag(model)
            }
        }

        Toggle("Clean up text", isOn: $settings.cleanupEnabled)

        if settings.cleanupEnabled {
            Toggle("Smart cleanup (on-device AI)", isOn: $settings.smartCleanup)
                .disabled(!FoundationModelFormatter.isAvailable)
            if let reason = FoundationModelFormatter.unavailableReason {
                Text(reason).font(.caption)
            }
        }

        Toggle("Sound", isOn: $settings.soundEnabled)

        Divider()

        if !Permissions.hasAccessibility {
            Button("Grant Accessibility") { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasMicrophone {
            Button("Grant Microphone") { Permissions.openMicrophoneSettings() }
        }

        Button("Quit SigmaFlow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}


/// A developer aid: `SigmaFlow --snapshot-dir DIR --pages models,styles/custom,...`
/// opens each page (and tab), draws the main window to DIR/<page>[-<tab>].png, and quits.
/// `--snapshot-size WxH` draws at another window size (the minimum is 980x620).
/// The window draws itself, so no screen-recording grant is needed; vibrancy behind the
/// sidebar is composited by the window server and does not appear in the file.
@MainActor
enum WindowSnapshots {
    static func runIfRequested(controller: DictationController) {
        let args = CommandLine.arguments
        guard let dirIndex = args.firstIndex(of: "--snapshot-dir"), dirIndex + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[dirIndex + 1], isDirectory: true)
        var pages = MainWindow.Section.allCases.map { ($0.rawValue, nil as String?) }
        if let pagesIndex = args.firstIndex(of: "--pages"), pagesIndex + 1 < args.count {
            pages = args[pagesIndex + 1].split(separator: ",").map { spec in
                let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
                return (parts[0], parts.count > 1 ? parts[1] : nil)
            }
        }
        var size = CGSize(width: DS.Material.windowWidth, height: DS.Material.windowHeight)
        if let sizeIndex = args.firstIndex(of: "--snapshot-size"), sizeIndex + 1 < args.count {
            let parts = args[sizeIndex + 1].lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            for (page, tab) in pages {
                if page == "welcome" {
                    // `--pages welcome/talk`: the setup window at one of its steps.
                    FirstOpen.shared.showForSnapshot(FirstOpen.Step(rawValue: tab ?? "") ?? .welcome)
                    try? await Task.sleep(for: .seconds(0.3))
                    let renderer = ImageRenderer(
                        content: OnboardingView(controller: controller)
                            .environment(\.colorScheme, .dark)
                            .environment(\.isSnapshotting, true))
                    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
                    let file = directory.appendingPathComponent("welcome-\(tab ?? "welcome").png")
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: file)
                    }
                    continue
                }
                if let tab { Settings.shared.openTabs[page] = tab }
                Settings.shared.lastPage = page
                try? await Task.sleep(for: .seconds(0.8))
                // The window only lends its scale; a launch that restores no window (the app
                // was last quit with it closed) still draws, at the screen's scale.
                let window = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 600 })
                let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
                let name = tab.map { "\(page)-\($0)" } ?? page
                let file = directory.appendingPathComponent("\(name).png")
                // SwiftUI's own offscreen renderer draws the whole hierarchy at the window's
                // size, dark, at 2x. Vibrancy views draw nothing here; everything else does.
                let renderer = ImageRenderer(
                    content: MainWindow(controller: controller)
                        .frame(width: size.width, height: size.height)
                        .environment(\.colorScheme, .dark)
                        .environment(\.isSnapshotting, true)
                )
                renderer.scale = scale
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: file)
                }
            }
            NSApp.terminate(nil)
        }
    }
}


/// A developer aid: `SigmaFlow --transcribe-meeting AUDIO OUT.md [--language english|tamil]`
/// transcribes a recording exactly as Stop does, writes the .md to OUT.md, and quits. It runs
/// instead of the app, so a copy launched beside the installed one starts no hotkeys and no
/// call watching and never touches the SigmaFlow folder. Without `--language` the meeting is
/// heard by ear, as after Stop.
@MainActor
enum MeetingCheck {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        // `--title-check FOLDER`: the title that recording would be given, and how long it took.
        // Reads the .md only; nothing is renamed.
        if let index = args.firstIndex(of: "--title-check"), index + 1 < args.count {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                guard let meeting = MeetingLibrary.read(URL(fileURLWithPath: args[index + 1])) else {
                    print("title check: no recording there")
                    return NSApp.terminate(nil)
                }
                let started = Date()
                let title = await MeetingTitler.title(for: meeting.lines.map(\.text), language: meeting.language ?? .english)
                print("title check: \(title ?? "(none)"), \((meeting.language ?? .english).label), \(Int(Date().timeIntervalSince(started))) s")
                NSApp.terminate(nil)
            }
            return true
        }
        guard let index = args.firstIndex(of: "--transcribe-meeting"), index + 2 < args.count else { return false }
        NSApp.setActivationPolicy(.accessory)
        let audio = URL(fileURLWithPath: args[index + 1])
        let out = URL(fileURLWithPath: args[index + 2])
        var language: MeetingLanguage?
        if let flag = args.firstIndex(of: "--language"), flag + 1 < args.count {
            language = MeetingLanguage(rawValue: args[flag + 1])
        }
        Task { @MainActor in
            let started = Date()
            do {
                let transcript = try await MeetingProcessor.transcribe(audio: audio, language: language) { _ in }
                let markdown = MeetingMarkdown.render(
                    name: audio.deletingPathExtension().lastPathComponent, date: started,
                    duration: MeetingLibrary.audioSeconds(audio), lines: transcript.lines,
                    audioFileName: audio.lastPathComponent, language: transcript.language, speakers: transcript.speakers)
                try markdown.write(to: out, atomically: true, encoding: .utf8)
                print("meeting check: \(transcript.lines.count) rows, \(transcript.language.label), \(Int(Date().timeIntervalSince(started))) s")
            } catch {
                print("meeting check failed: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
        return true
    }
}
