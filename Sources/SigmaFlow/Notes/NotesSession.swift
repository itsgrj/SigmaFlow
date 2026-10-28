import Foundation
import Observation

/// Live notes: ⌃⌥N opens an overlay in the top right corner that writes down a conversation
/// in the room as it happens, and Stop makes it a meeting (docs/mockups/live-notes.html,
/// Gokul's picks 16 Oct 2026).
///
/// In-person only: the microphone, never the call side (calls are what Meetings is for).
/// The recording is a meeting recording in every way that matters after Stop: written by
/// `MeetingRecorder` into the hidden staging folder, filed into SigmaFlow/Meetings, and
/// transcribed again whole, with speakers and Tamil. The live lines are a draft.
///
/// Audio ordering is the dictation rule: one stream, drained by one task, in order.
/// A camera photo or a screenshot taken during live notes: when, in seconds of recording,
/// and its file.
struct NotePhoto: Identifiable, Hashable, Sendable {
    let time: Double
    let url: URL
    var id: URL { url }
}

@MainActor
@Observable
final class NotesSession {
    static let shared = NotesSession()

    private(set) var isOpen = false
    private(set) var isPaused = false
    /// Lines so far, oldest first.
    private(set) var lines: [NoteLine] = []
    /// Seconds of audio recorded, which is the clock the line times use.
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    /// True until the live model has loaded; the overlay is already listening.
    private(set) var isPreparing = false
    /// The camera button: on at every start, off by a press (Gokul, 16 Oct 2026).
    private(set) var isCameraOn = false
    private(set) var photos: [NotePhoto] = []
    /// Screenshots every 15 s: off at every start, on by the screen button (Gokul, 16 Oct).
    /// Right ⌘ + S takes one whenever, on or off.
    private(set) var isScreensOn = false
    private(set) var screens: [NotePhoto] = []
    static let screenInterval: Double = 15

    /// A photo every this many seconds of recording,
    static let photoInterval: Double = 30
    /// the first this far in: a camera just turned on hasn't found its exposure yet.
    static let firstPhoto: Double = 2

    private let camera = NotesCamera()
    private var photosFolder: URL?
    private var nextPhoto: Double = 0
    private var isCapturing = false
    private var screensFolder: URL?
    private var nextScreen: Double = 0
    private var isShooting = false
    /// The last screen kept, so an unchanged one every 15 s is not kept again.
    private var lastScreen: NotesScreen.Print?

    private let recorder = MeetingRecorder()
    private var transcriber: NotesTranscriber?
    private var stagedURL: URL?
    private var startedAt: Date?
    private var feed: AsyncStream<AudioChunk>.Continuation?
    private var drain: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var panel: NotesPanel?
    /// The cancellation token, as in dictation: an async tail from an earlier session
    /// checks it before touching anything.
    private var generation = 0
    /// The newest numbered update shown: Tamil lines are decided out of order.
    private var shownRevision = 0

    private init() {}

    func toggle() {
        if isOpen { stop() } else { start() }
    }

    func start() {
        guard !isOpen else { return }
        // One recording at a time: a meeting already has the microphone and the folder.
        guard !MeetingSession.shared.isRecording, !MeetingLibrary.shared.isFolderMissing else { return }
        guard Permissions.hasMicrophone else {
            Task { @MainActor in
                if await Permissions.requestMicrophone() { self.start() }
            }
            return
        }

        generation += 1
        let generation = generation
        let url = MeetingSession.stagingFolder.appendingPathComponent("\(UUID().uuidString).m4a")
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        do {
            try recorder.start(
                to: url, inputDeviceUID: Settings.shared.microphoneID,
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        guard let self else { return }
                        self.level = self.level * 0.6 + level * 0.4
                    }
                },
                onAudio: { chunk in continuation.yield(chunk) })
        } catch {
            Log.meetings.error("notes: mic failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            continuation.finish()
            return
        }

        stagedURL = url
        let photosFolder = url.deletingPathExtension().appendingPathExtension("photos")
        try? FileManager.default.createDirectory(at: photosFolder, withIntermediateDirectories: true)
        self.photosFolder = photosFolder
        let screensFolder = url.deletingPathExtension().appendingPathExtension("screens")
        try? FileManager.default.createDirectory(at: screensFolder, withIntermediateDirectories: true)
        self.screensFolder = screensFolder
        screens = []
        isScreensOn = false
        lastScreen = nil
        photos = []
        nextPhoto = Self.firstPhoto
        isCameraOn = true
        Task { @MainActor in
            if await NotesCamera.requestAccess() {
                guard self.isOpen, self.isCameraOn else { return }
                self.camera.start()
            } else {
                self.isCameraOn = false
            }
        }
        startedAt = Date()
        feed = continuation
        lines = []
        elapsed = 0
        isPaused = false
        isOpen = true
        isPreparing = true
        SystemSounds.playStart()

        shownRevision = 0
        let transcriber = NotesTranscriber { lines, revision in
            Task { @MainActor in NotesSession.shared.show(lines, revision: revision, generation: generation) }
        }
        self.transcriber = transcriber
        // The model loads while the microphone already records: nothing said in the first
        // seconds is lost, it waits in the stream.
        drain = Task.detached(priority: .userInitiated) {
            do {
                try await transcriber.prepare()
            } catch {
                Log.speech.error("notes: model failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run {
                guard NotesSession.shared.generation == generation else { return }
                NotesSession.shared.isPreparing = false
            }
            for await chunk in stream {
                await transcriber.feed(chunk)
            }
        }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == generation else { return }
                self.elapsed = self.recorder.seconds
                self.photoIfDue()
                self.screenIfDue()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        let panel = NotesPanel(session: self)
        self.panel = panel
        panel.present()
        Log.meetings.info("notes started")
    }

    func toggleCamera() {
        guard isOpen else { return }
        isCameraOn.toggle()
        if isCameraOn {
            nextPhoto = elapsed + Self.firstPhoto
            Task { @MainActor in
                if await NotesCamera.requestAccess(), self.isCameraOn { self.camera.start() } else { self.isCameraOn = false }
            }
        } else {
            camera.stop()
        }
    }

    /// The screen button: every 15 s from now, or not. The first press asks macOS for
    /// Screen Recording; until it is allowed the button stays off.
    func toggleScreens() {
        guard isOpen else { return }
        if isScreensOn {
            isScreensOn = false
            return
        }
        guard NotesScreen.isAllowed || NotesScreen.requestAccess() else { return }
        isScreensOn = true
        nextScreen = elapsed
    }

    /// Right ⌘ + S: one screenshot now, kept even if the screen hasn't changed.
    func screenshotNow() {
        guard isOpen else { return }
        guard NotesScreen.isAllowed || NotesScreen.requestAccess() else { return }
        shoot(at: elapsed, unlessSame: false)
    }

    private func screenIfDue() {
        guard isScreensOn, !isPaused, elapsed >= nextScreen else { return }
        nextScreen = elapsed + Self.screenInterval
        shoot(at: elapsed, unlessSame: true)
    }

    private func shoot(at time: Double, unlessSame: Bool) {
        guard !isShooting, let screensFolder else { return }
        let at = time.rounded(.down)
        let url = screensFolder.appendingPathComponent(
            MeetingNaming.clock(at).replacingOccurrences(of: ":", with: "-") + ".jpg")
        // One a second at most: the key and the 15 s mark in the same second are one picture.
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        isShooting = true
        let previous = unlessSame ? lastScreen : nil
        let generation = generation
        Task { @MainActor in
            let (saved, print) = await NotesScreen.capture(to: url, unlessSameAs: previous)
            guard self.generation == generation else { return }
            self.isShooting = false
            guard saved else { return }
            self.lastScreen = print
            self.screens.append(NotePhoto(time: at, url: url))
        }
    }

    /// Every 30 s of recording while the camera is on. A photo that fails (the camera still
    /// waking) is tried again on the next tick.
    private func photoIfDue() {
        guard isCameraOn, !isPaused, !isCapturing, elapsed >= nextPhoto, let photosFolder else { return }
        isCapturing = true
        let at = elapsed.rounded(.down)
        let url = photosFolder.appendingPathComponent(
            MeetingNaming.clock(at).replacingOccurrences(of: ":", with: "-") + ".jpg")
        let generation = generation
        Task { @MainActor in
            let ok = await camera.capture(to: url)
            guard self.generation == generation else { return }
            self.isCapturing = false
            guard ok else { return }
            self.photos.append(NotePhoto(time: at, url: url))
            self.nextPhoto = at + Self.photoInterval
        }
    }

    /// The dictation key went down or came up. While it is held the notes write silence.
    func dictationChanged(_ isDictating: Bool) {
        guard isOpen else { return }
        recorder.isMuted = isDictating
    }

    func togglePause() {
        guard isOpen else { return }
        isPaused.toggle()
        recorder.isPaused = isPaused
    }

    func stop() {
        guard isOpen, let staged = stagedURL else { return }
        let date = startedAt ?? Date()
        ticker?.cancel()
        let result = recorder.stop()
        feed?.finish()
        feed = nil
        let duration = result?.seconds ?? elapsed
        camera.stop()
        let photosFolder = photosFolder
        self.photosFolder = nil
        let screensFolder = screensFolder
        self.screensFolder = nil
        isScreensOn = false
        isShooting = false
        isCameraOn = false
        isCapturing = false
        isOpen = false
        isPaused = false
        level = 0
        stagedURL = nil
        startedAt = nil
        panel?.dismiss()
        panel = nil
        SystemSounds.playStop()

        let drain = drain
        let transcriber = transcriber
        self.drain = nil
        self.transcriber = nil
        Task { @MainActor in
            // The stream is closed; let the model hear what it still holds, then let it go.
            await drain?.value
            _ = await transcriber?.finish()
            // Two seconds is a mis-press, not a conversation.
            guard duration >= 2 else {
                try? FileManager.default.removeItem(at: staged)
                if let photosFolder { try? FileManager.default.removeItem(at: photosFolder) }
                if let screensFolder { try? FileManager.default.removeItem(at: screensFolder) }
                return
            }
            // The encoder may still be writing the file's trailer when stop returns.
            try? await Task.sleep(for: .milliseconds(300))
            do {
                // A conversation, filed in SigmaFlow/Conversations (Gokul, 16 Oct 2026, 1B 2C).
                let library = MeetingLibrary.conversations
                let meeting = try library.file(
                    recording: staged, date: date, duration: duration, photos: photosFolder, screens: screensFolder)
                library.transcribe(meeting)
            } catch {
                // The audio stays in the staging folder and is filed at the next launch.
                Log.meetings.error("notes: filing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        Log.meetings.info("notes stopped, \(Int(duration)) s")
    }

    private func show(_ lines: [NoteLine], revision: Int, generation: Int) {
        guard self.generation == generation, isOpen, revision > shownRevision else { return }
        shownRevision = revision
        self.lines = lines
    }
}

// MARK: - README pictures

extension NotesSession {
    /// For `--readme-frames` only (Support/ReadmeFrames.swift): the card's state with made-up
    /// lines and photos. No microphone, camera, recording or folder is behind it.
    func stageForPicture(open: Bool, lines: [NoteLine], elapsed: TimeInterval, level: Float, photos: [NotePhoto]) {
        isOpen = open
        isPaused = false
        isPreparing = false
        isCameraOn = open
        isScreensOn = false
        self.lines = lines
        self.elapsed = elapsed
        self.level = level
        self.photos = photos
        screens = []
    }
}
