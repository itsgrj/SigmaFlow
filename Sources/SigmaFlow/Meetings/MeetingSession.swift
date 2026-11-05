import CoreMedia
import Foundation
import Observation

/// The one place that starts and stops a meeting recording, from the page or ⌃⌥M.
///
/// The recording is written into SigmaFlow's own hidden folder while it runs and only
/// moves into SigmaFlow/Meetings at Stop. A synced folder must never see a file that is
/// still growing: a sync engine uploads it over and over and can mark it mid-write
/// (CLAUDE.md, the build-race note). It is also why a crash mid-meeting is recoverable:
/// the staged file is still there at the next launch and gets filed then.
@MainActor
@Observable
final class MeetingSession {
    static let shared = MeetingSession()

    private(set) var isRecording = false
    /// One level for the one meter: whichever side is louder, the user or the call.
    var level: Float { max(micLevel, callLevel) }
    private(set) var elapsed: TimeInterval = 0
    private(set) var startedAt: Date?
    /// Why the last start failed, for the page to show. Cleared on the next start.
    private(set) var lastError: String?
    /// The call this recording was started for from the "Record this meeting?" card. It
    /// stops by itself when that call ends (Gokul, 3A); a recording started by hand never does.
    private(set) var call: CallWatcher.Call?
    /// The recording's From line: the call app, or for a browser call the site it is on
    /// ("Zoho Cliq", `CallSite`) once the browser has said. A recording started by hand
    /// during a call is that call's too; one with no call has none.
    private(set) var source: String?
    /// Filming as well as recording the sound (docs/mockups/meeting-video.html, 03 12).
    private(set) var isFilming = false

    private var micLevel: Float = 0
    private var callLevel: Float = 0
    private let recorder = MeetingRecorder()
    private var tap: SystemAudioTap?
    private var stagedURL: URL?
    private var stagedCallURL: URL?
    private var film: MeetingVideo?
    /// Resolves once filming has started, or failed to: Stop waits for it before stopping.
    private var filmStarting: Task<Bool, Never>?
    private var ticker: Task<Void, Never>?

    private init() {}

    /// Application Support/SigmaFlow/Recording: never synced, never shown.
    static var stagingFolder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigmaFlow", isDirectory: true)
            .appendingPathComponent("Recording", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    /// `video`: the call card's answer. Without one (⌃⌥M, Record meeting) the last answer
    /// given on the card stands (Gokul, 4 Nov 2026).
    func start(for call: CallWatcher.Call? = nil, video: Bool? = nil) {
        guard !isRecording else { return }
        lastError = nil

        // Live notes already have the microphone; their Stop makes them a meeting anyway.
        guard !NotesSession.shared.isOpen else { return }

        guard !MeetingLibrary.shared.isFolderMissing else {
            lastError = MeetingLibrary.LibraryError.folderMissing.localizedDescription
            return
        }

        // Refuse rather than record silence: the mic grant is the one thing we cannot work
        // around, and a 40-minute file of nothing is worse than an error now.
        guard Permissions.hasMicrophone else {
            Task { @MainActor in
                if await Permissions.requestMicrophone() { self.start(for: call, video: video) }
                else { self.lastError = "SigmaFlow needs the microphone to record. Allow it in System Settings, Privacy & Security." }
            }
            return
        }

        let id = UUID().uuidString
        let url = Self.stagingFolder.appendingPathComponent("\(id).m4a")
        do {
            try recorder.start(to: url, inputDeviceUID: Settings.shared.microphoneID) { [weak self] level in
                Task { @MainActor in
                    guard let self else { return }
                    self.micLevel = self.micLevel * 0.6 + level * 0.4
                }
            }
        } catch {
            lastError = "Couldn't start recording."
            Log.meetings.error("mic failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return
        }
        // The sound's clock: the film is laid against it.
        let soundStarted = CMClockGetTime(CMClockGetHostTimeClock())

        // The other side of a call, from what the Mac plays. Every recording gets it: a
        // meeting started by hand during a call should hear the call too. If it cannot start,
        // the meeting is the microphone alone, as before.
        let callURL = Self.stagingFolder.appendingPathComponent("\(id).call.m4a")
        let tap = SystemAudioTap()
        do {
            try tap.start(to: callURL) { [weak self] level in
                Task { @MainActor in
                    guard let self else { return }
                    self.callLevel = self.callLevel * 0.6 + level * 0.4
                }
            }
            self.tap = tap
            stagedCallURL = callURL
        } catch {
            Log.meetings.error("call tap failed, microphone only: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: callURL)
        }

        self.call = call
        let during = call ?? CallWatcher.shared.current
        if video ?? Settings.shared.recordVideo {
            startFilming(id: id, at: soundStarted, call: during)
        }
        source = during?.app
        if let browser = during?.browser {
            Task { @MainActor in
                guard let site = await CallSite.name(in: browser), self.stagedURL == url else { return }
                self.source = site
            }
        }
        stagedURL = url
        startedAt = Date()
        elapsed = 0
        isRecording = true
        SystemSounds.playStart()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        Log.meetings.info("meeting recording started")
    }

    /// The film beside the sound, into `<id>.video.mov` and stills into `<id>.screens`.
    /// Without Screen Recording the system is asked, and this meeting is sound only.
    private func startFilming(id: String, at soundStarted: CMTime, call: CallWatcher.Call?) {
        guard MeetingVideo.isAllowed else {
            NotesScreen.requestAccess()
            Log.meetings.info("no Screen Recording yet, sound only")
            return
        }
        let film = MeetingVideo()
        let url = Self.stagingFolder.appendingPathComponent("\(id).video.mov")
        let stills = Self.stagingFolder.appendingPathComponent("\(id).screens")
        self.film = film
        isFilming = true
        filmStarting = Task { @MainActor [weak self] in
            do {
                try await film.start(to: url, stills: stills, startedAt: soundStarted, call: call)
                return true
            } catch {
                Log.meetings.error("filming failed, sound only: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
                if self?.film === film { self?.isFilming = false }
                return false
            }
        }
    }

    func stop() {
        guard isRecording, let staged = stagedURL else { return }
        ticker?.cancel()
        ticker = nil
        let date = startedAt ?? Date()
        let result = recorder.stop()
        let callPeak = tap?.stop() ?? 0
        let callStaged = stagedCallURL
        let app = source
        let film = film
        let filmStarting = filmStarting
        let id = staged.deletingPathExtension().lastPathComponent
        let filmURL = Self.stagingFolder.appendingPathComponent("\(id).video.mov")
        let stills = Self.stagingFolder.appendingPathComponent("\(id).screens")
        let duration = result?.seconds ?? elapsed
        isRecording = false
        micLevel = 0
        callLevel = 0
        elapsed = 0
        stagedURL = nil
        stagedCallURL = nil
        tap = nil
        call = nil
        source = nil
        self.film = nil
        self.filmStarting = nil
        isFilming = false
        startedAt = nil
        SystemSounds.playStop()

        Task { @MainActor in
            var filmed = false
            if let film, await filmStarting?.value == true { filmed = await film.stop() }
            // Two seconds is a mis-tap, not a meeting.
            guard duration >= 2 else {
                for file in [staged, callStaged, filmURL, stills].compactMap({ $0 }) { try? FileManager.default.removeItem(at: file) }
                return
            }
            // The encoders may still be writing the files' trailers when stop returns.
            try? await Task.sleep(for: .milliseconds(300))
            var recording = staged
            // A call side that heard something joins the microphone in one two-sided file;
            // a silent one (no call, or the permission refused) is dropped.
            if let callStaged {
                if callPeak >= 0.01 {
                    let both = Self.stagingFolder.appendingPathComponent("\(UUID().uuidString).m4a")
                    do {
                        try MeetingAudio.merge(mic: staged, call: callStaged, into: both)
                        try? FileManager.default.removeItem(at: staged)
                        recording = both
                    } catch {
                        Log.meetings.error("merge failed, microphone only: \(error.localizedDescription, privacy: .public)")
                    }
                }
                try? FileManager.default.removeItem(at: callStaged)
            }
            if !filmed { try? FileManager.default.removeItem(at: filmURL) }
            do {
                let meeting = try MeetingLibrary.shared.file(
                    recording: recording, date: date, duration: duration, app: app, screens: filmed ? stills : nil)
                MeetingLibrary.shared.transcribe(meeting)
                if filmed { Self.makeMovie(film: filmURL, for: meeting) }
            } catch {
                // The audio stays in the staging folder and is filed at the next launch.
                self.lastError = "Couldn't save the recording."
                Log.meetings.error("filing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The meeting's .mp4 from the film and its filed sound, while the transcript is made.
    /// A film that can't be made into one stays in the staging folder rather than being lost.
    private static func makeMovie(film: URL, for meeting: Meeting) {
        guard let sound = meeting.audioURL else { return }
        let movie = stagingFolder.appendingPathComponent("\(UUID().uuidString).mp4")
        Task { @MainActor in
            do {
                try await MeetingMovie.make(film: film, sound: sound, into: movie)
                try? FileManager.default.removeItem(at: film)
                MeetingLibrary.shared.attachVideo(movie, to: meeting.id)
            } catch {
                try? FileManager.default.removeItem(at: movie)
                Log.meetings.error("couldn't make the video: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A recording left in the staging folder by a quit or a crash: file it as a meeting so
    /// it shows up with Try again. Called once at launch, before anything can be recording.
    func recoverUnfiled() {
        guard !isRecording, !MeetingLibrary.shared.isFolderMissing else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.stagingFolder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        // A call side left alone is half a meeting with no microphone to join; it goes. So
        // does a dropped recording's copy cut short by a quit: the original is still wherever
        // the user keeps it, and dropping it again is the way back.
        let leftovers = [".call.m4a", ".import.m4a"]
        func isLeftover(_ file: URL) -> Bool { leftovers.contains { file.lastPathComponent.hasSuffix($0) } }
        for file in files where isLeftover(file) {
            try? FileManager.default.removeItem(at: file)
        }
        for file in files where file.pathExtension == "m4a" && !isLeftover(file) {
            let seconds = MeetingLibrary.audioSeconds(file)
            guard seconds >= 2 else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            // Live notes leave their camera photos beside the audio, in <id>.photos.
            let photos = file.deletingPathExtension().appendingPathExtension("photos")
            let hasPhotos = FileManager.default.fileExists(atPath: photos.path)
            let screens = file.deletingPathExtension().appendingPathExtension("screens")
            let hasScreens = FileManager.default.fileExists(atPath: screens.path)
            // Live notes always stage a photos folder: theirs is a conversation, not a meeting.
            // A meeting filmed has stills, and its film beside it.
            let library = hasPhotos ? MeetingLibrary.conversations : MeetingLibrary.shared
            let film = file.deletingPathExtension().appendingPathExtension("video.mov")
            if let meeting = try? library.file(
                recording: file, date: date, duration: seconds, photos: hasPhotos ? photos : nil,
                screens: hasScreens ? screens : nil) {
                Log.meetings.info("filed a recording left over from the last run")
                if FileManager.default.fileExists(atPath: film.path) { Self.makeMovie(film: film, for: meeting) }
            }
        }
    }
}
