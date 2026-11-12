import AppKit
import Sparkle

/// SigmaFlow updates itself from GitHub releases (docs/mockups/app-updates.html, picks 10 + 02,
/// 12 Nov 2026). Sparkle reads `appcast.xml` from the repo once a day (`SUFeedURL`,
/// `SUScheduledCheckInterval` in the Info.plist), downloads a newer release's DMG in the
/// background, and checks it was signed with SigmaFlow's own key (`SUPublicEDKey`; the
/// private half lives only in Gokul's login keychain, account `sigmaflow`).
///
/// **Nothing is ever asked.** The downloaded version is put in place the next time
/// SigmaFlow quits or the Mac restarts, which Sparkle does by itself at termination. Until
/// then the sidebar's version line says it is ready, with Restart (`requestRestart`). If it
/// has waited `restartAfter` and SigmaFlow is idle (nothing recording, nothing transcribing,
/// no key or mouse for `idleBeforeRestart`), SigmaFlow restarts itself. Sparkle's own windows
/// never show: taking the install over in `willInstallUpdateOnQuit` stops its scheduler, and
/// with it every reminder it would draw.
///
/// When the new version opens, `UpdatedNotice` says so above the Dock.
@MainActor
@Observable
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()

    /// The version downloaded, checked and waiting to be put in place, as people read it.
    private(set) var readyVersion: String?
    /// Restart was pressed while something was still running; it happens once that ends.
    private(set) var restartWanted = false

    @ObservationIgnored private var updater: SPUStandardUpdaterController?
    @ObservationIgnored private weak var controller: DictationController?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var readySince: Date?
    @ObservationIgnored private var watch: Task<Void, Never>?

    /// How long a waiting update holds out for a quit before SigmaFlow restarts itself.
    private static let restartAfter: TimeInterval = 3 * 24 * 60 * 60
    /// How long the Mac must have had no key or mouse before that restart.
    private static let idleBeforeRestart: TimeInterval = 10 * 60
    /// How often a waiting update looks for its moment.
    private static let lookEvery: Duration = .seconds(30)

    /// Starts the daily check. Only in a bundle that carries a feed: a bare `swift build`
    /// binary, or a snapshot run that draws pages and quits, never looks for updates.
    func start(controller: DictationController) {
        guard updater == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              !CommandLine.arguments.contains("--snapshot-dir")
        else { return }
        // Sparkle is weak-linked: if macOS refused to load it, its classes are simply absent.
        guard NSClassFromString("SPUStandardUpdaterController") != nil else {
            Log.app.error("Sparkle did not load; SigmaFlow will not update itself")
            return
        }
        self.controller = controller
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    // MARK: - Sparkle

    /// The new version is downloaded and checked. Taking the install over means Sparkle
    /// shows nothing and schedules nothing more; it still installs it when SigmaFlow quits.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        Log.app.info("Update \(item.displayVersionString, privacy: .public) is ready; it installs when SigmaFlow quits")
        readyVersion = item.displayVersionString
        installNow = immediateInstallHandler
        if readySince == nil { readySince = Date() }
        lookForTheMoment()
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // No update is not a failure worth a word; anything else goes to the log only.
        let code = (error as NSError).code
        guard code != Int(SUError.noUpdateError.rawValue) else { return }
        Log.app.error("Update check stopped: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Restarting

    /// The sidebar's Restart. Waits for a dictation, a recording, notes or a transcript to
    /// finish, then restarts into the new version.
    func requestRestart() {
        guard installNow != nil else { return }
        restartWanted = true
        if !isBusy { install() } else { lookForTheMoment() }
    }

    private func lookForTheMoment() {
        guard watch == nil else { return }
        watch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.lookEvery)
                guard let self else { return }
                if self.isMoment { self.install(); return }
            }
        }
    }

    private var isMoment: Bool {
        guard installNow != nil, !isBusy else { return false }
        if restartWanted { return true }
        guard let readySince, Date().timeIntervalSince(readySince) >= Self.restartAfter else { return false }
        return Self.idleSeconds >= Self.idleBeforeRestart
    }

    private func install() {
        watch?.cancel()
        watch = nil
        Log.app.info("Restarting into \(self.readyVersion ?? "the new version", privacy: .public)")
        installNow?()
    }

    /// Anything a restart would cut short. Search's background reading is not on the list:
    /// it picks up where it left off after the launch.
    var isBusy: Bool {
        if let controller, controller.state != .idle || controller.writing != nil { return true }
        if MeetingSession.shared.isRecording || NotesSession.shared.isOpen { return true }
        for library in [MeetingLibrary.shared, MeetingLibrary.conversations]
        where !library.progress.isEmpty || !library.adding.isEmpty {
            return true
        }
        return false
    }

    /// Seconds since the last key press, click or mouse move anywhere on the Mac.
    private static var idleSeconds: TimeInterval {
        // kCGAnyInputEventType: every kind of input at once.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
