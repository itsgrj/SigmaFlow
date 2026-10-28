import AVFoundation
import AppKit
import Foundation
import Observation

/// The first open (docs/mockups/onboarding.html, round 6; Gokul's picks 1A 2B 3A 8E): a
/// setup window of its own that goes Welcome, Microphone and Accessibility, talk, hands
/// free, the folder, meetings (docs/mockups/meeting-drop-discover.html, pick 19), then
/// straight into the app on Transcriptions, where what was said during setup is already
/// waiting, or on Meetings when a recording was dropped on the last step.
///
/// The talking steps are real dictations. SigmaFlow is the app in front, so nothing is
/// typed anywhere, the overlay shows as always, and each run is saved like any other.
///
/// On a real first open, Parakeet Unified EN downloads from launch and becomes the model,
/// never named on screen (Gokul, 18 Oct 2026); the key stays held back until it lands (2B).
/// Opened again from the app menu, the window changes nothing about the setup.
@MainActor
@Observable
final class FirstOpen {
    static let shared = FirstOpen()

    enum Step: String, CaseIterable {
        case welcome, permissions, talk, handsFree, folder, meetings
    }

    var step: Step = .welcome

    /// Grants as last read. macOS says nothing when they change, so they are polled while
    /// the window is open.
    private(set) var hasMicrophone = Permissions.hasMicrophone
    private(set) var hasAccessibility = Permissions.hasAccessibility
    /// The microphone was refused once; the button opens System Settings from then on.
    private(set) var microphoneRefused = false
    /// The system's Accessibility prompt was shown once; after that, Allow opens the pane.
    private(set) var accessibilityAsked = false

    /// What was said on the talking steps, oldest first.
    private(set) var lines: [String] = []
    private(set) var newestLine = -1
    private(set) var talked = false
    private(set) var talkedHandsFree = false
    /// The file dropped on the Meetings step, now transcribing as a meeting.
    private(set) var droppedRecording: String?

    /// A real first open, as opposed to Welcome opened again from the app menu.
    private(set) var isFirstRun = false
    /// The window has handed over to the app, so closing it must not open the app again.
    private(set) var isFinished = false

    @ObservationIgnored private weak var controller: DictationController?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var downloadWatch: Task<Void, Never>?

    static let model = SpeechModelID.parakeetUnified

    private init() {}

    // MARK: - Starting

    /// At launch, before the hotkey is armed: Right ⌘ is the key the steps teach, and
    /// Parakeet starts arriving now so it is usually there by the talking step.
    func beginFirstRun(controller: DictationController) {
        isFirstRun = true
        self.controller = controller
        Settings.shared.pushToTalkKey = .rightCommand
        let library = ModelLibrary.shared
        library.refresh()
        if library.state(of: Self.model) == .downloaded {
            adoptModel()
        } else {
            controller.waitsForModel = true
            library.download(Self.model)
            watchDownload()
        }
    }

    /// Welcome opened again from the app menu: the steps from the top, nothing changed.
    func reopen(controller: DictationController) {
        self.controller = controller
        step = .welcome
        lines = []
        newestLine = -1
        talked = false
        talkedHandsFree = false
        droppedRecording = nil
        isFinished = false
    }

    /// `--snapshot-dir … --pages welcome/talk`: one step, with a dictation already landed on
    /// the talking steps so the field shows text.
    func showForSnapshot(_ step: Step) {
        self.step = step
        if step == .talk || step == .handsFree {
            lines = ["Remind me to send the deck to Priya before Friday, and ask her about the budget."]
            newestLine = 0
            talked = true
        }
    }

    /// The window appeared: watch the grants while it is open.
    func windowAppeared(controller: DictationController) {
        self.controller = controller
        startPolling()
    }

    // MARK: - The model

    var downloadState: ModelLibrary.State { ModelLibrary.shared.state(of: Self.model) }

    /// Whether a hold on the talking steps will be heard.
    var isModelReady: Bool {
        guard isFirstRun else { return true }
        return downloadState == .downloaded
    }

    var isModelFailed: Bool {
        if case .failed = downloadState { return true }
        return false
    }

    var downloadFraction: Double {
        switch downloadState {
        case .downloading(let fraction): fraction
        case .downloaded, .builtIn: 1
        case .notDownloaded, .failed: 0
        }
    }

    func retryDownload() {
        ModelLibrary.shared.download(Self.model)
        watchDownload()
    }

    private func watchDownload() {
        downloadWatch?.cancel()
        downloadWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch self.downloadState {
                case .downloaded:
                    self.adoptModel()
                    return
                case .failed:
                    return
                default:
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    /// Parakeet is here: it becomes the model, unless the person has picked another
    /// meanwhile, and the key is let go. Downloading it also loaded it; warming is a no-op
    /// then, and a quick load when the files were already on this Mac.
    private func adoptModel() {
        if Settings.shared.activeModel == .apple {
            Settings.shared.activeModel = Self.model
        }
        controller?.waitsForModel = false
        Task.detached(priority: .userInitiated) {
            try? await SpeechModelStores.warm(FirstOpen.model)
        }
    }

    // MARK: - Permissions

    func askMicrophone() {
        if microphoneRefused || AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            Permissions.openMicrophoneSettings()
            return
        }
        Task { @MainActor in
            let granted = await Permissions.requestMicrophone()
            hasMicrophone = granted
            microphoneRefused = !granted
        }
    }

    func askAccessibility() {
        if accessibilityAsked {
            Permissions.openAccessibilitySettings()
        } else {
            accessibilityAsked = true
            // The system prompt also puts SigmaFlow in the Accessibility list, so the switch
            // is there to turn on when System Settings opens.
            Permissions.promptForAccessibility()
        }
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let microphone = Permissions.hasMicrophone
                let accessibility = Permissions.hasAccessibility
                if microphone != self.hasMicrophone { self.hasMicrophone = microphone }
                if accessibility != self.hasAccessibility {
                    self.hasAccessibility = accessibility
                    // Accessibility is switched on in System Settings, which is now in front.
                    // Come back, so the next step's hold is heard here and typed nowhere.
                    if accessibility { self.comeForward() }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func comeForward() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Talking

    /// A dictation landed. Only the talking steps keep it.
    func landed(_ landing: DictationController.Landing) {
        guard step == .talk || step == .handsFree else { return }
        lines.append(landing.text)
        newestLine = lines.count - 1
        talked = true
        if landing.handsFree { talkedHandsFree = true }
    }

    // MARK: - The folder

    var folderURL: URL? { MeetingLibrary.shared.root }

    var folderPath: String {
        guard let folderURL else { return "" }
        return (folderURL.path as NSString).abbreviatingWithTildeInPath
    }

    var isHomeFolder: Bool {
        guard let folderURL else { return true }
        return folderURL.standardizedFileURL == MeetingLibrary.defaultRoot.standardizedFileURL
    }

    /// The folder sits somewhere iCloud copies off this Mac: iCloud Drive, or Desktop and
    /// Documents when those sync.
    var folderSyncs: Bool {
        guard let folderURL else { return false }
        if folderURL.path.contains("/Library/Mobile Documents/") { return true }
        let values = try? folderURL.resourceValues(forKeys: [.isUbiquitousItemKey])
        return values?.isUbiquitousItem ?? false
    }

    func useHomeFolder() {
        guard !isHomeFolder else { return }
        MeetingLibrary.shared.choose(MeetingLibrary.defaultRoot)
    }

    func chooseFolder() {
        MeetingLibrary.shared.pickFolder()
    }

    // MARK: - Meetings

    /// A recording dropped on the Meetings step: filed and transcribed as any drop is.
    func addRecordings(_ urls: [URL]) {
        guard let first = urls.first else { return }
        MeetingLibrary.shared.add(recordings: urls)
        droppedRecording = first.lastPathComponent
    }

    // MARK: - Moving through

    var canContinue: Bool {
        switch step {
        case .welcome, .folder, .meetings: true
        case .permissions: hasMicrophone && hasAccessibility
        // A download that failed must not trap anyone here; Apple hears them meanwhile.
        case .talk: talked || isModelFailed
        case .handsFree: talkedHandsFree || isModelFailed
        }
    }

    func next() {
        let all = Step.allCases
        guard let index = all.firstIndex(of: step), index + 1 < all.count else { return }
        step = all[index + 1]
    }

    func back() {
        let all = Step.allCases
        guard let index = all.firstIndex(of: step), index > 0 else { return }
        step = all[index - 1]
    }

    /// Open SigmaFlow: the setup is done, and the app opens on Transcriptions, where the
    /// talking steps' dictations are the first rows (8E), or on Meetings when a recording
    /// was dropped on the last step, so it is there transcribing.
    func finish() {
        isFinished = true
        Settings.shared.firstOpenDone = true
        let page: MainWindow.Section = droppedRecording == nil ? .transcriptions : .meetings
        Settings.shared.lastPage = page.rawValue
        controller?.waitsForModel = false
        poll?.cancel()
        poll = nil
    }

    /// The window was closed some other way: the app takes over, and the setup window comes
    /// back at the next launch.
    func closedEarly() {
        controller?.waitsForModel = false
        poll?.cancel()
        poll = nil
    }
}
