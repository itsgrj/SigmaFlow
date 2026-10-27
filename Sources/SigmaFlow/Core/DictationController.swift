import SigmaFlowDictionary
import AVFoundation
import AppKit
import Foundation
import Observation

/// Builds the engine named by the current setting.
///
/// Deliberately at file scope rather than a static on `DictationController`: the class is
/// `@MainActor`, which would make a static method main-actor-isolated and therefore
/// ineligible to be `@Sendable`. Reading the setting per-utterance is what lets the menu's
/// engine picker take effect on the very next hold instead of needing a restart.
@Sendable
func engineForCurrentSetting() -> any TranscriptionEngine {
    // Always invoked from `beginDictation`, which runs on the main actor.
    MainActor.assumeIsolated {
        SpeechModelStores.engine(for: Settings.shared.activeModel)
    }
}

@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case error(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error: false
            }
        }
    }

    private(set) var state: State = .idle {
        // While the mic is open for dictation, live notes write silence: what you dictate
        // stays out of the notes, live and after Stop (Gokul, 16 Oct 2026, 7B).
        didSet {
            let open = state == .starting || state == .listening
            if open != (oldValue == .starting || oldValue == .listening) { NotesSession.shared.dictationChanged(open) }
            // Search's picture reader waits while dictation runs, so it never slows it.
            PictureReader.shared.isDictating = state.isActive
        }
    }
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0
    /// Hands-free: recording was locked on by a double-tap and runs until the next tap.
    private(set) var isLatched = false
    /// False when the keyboard tap couldn't be installed — the Settings page surfaces
    /// this instead of letting every shortcut die silently.
    private(set) var hotkeyArmed = true

    /// What a style shortcut is doing right now. Drives the overlay while a rewrite runs,
    /// so a shortcut is never a silent two-second pause with no explanation.
    struct StyleActivity: Equatable {
        var name: String
        var message: String
        var isError: Bool = false
    }
    private(set) var styleActivity: StyleActivity?
    private var styleClearTask: Task<Void, Never>?

    /// A run started by Hold to talk on the Settings page: the same mic, model, cleanup and
    /// dictionary, but the overlay panel stays hidden, nothing is typed and nothing is saved.
    /// The two overlay tiles draw it instead. Stays true through processing and through an
    /// error, so the tiles can show both.
    private(set) var isPreview = false
    /// What the last preview run would have typed.
    private(set) var previewText = ""

    /// This run is Autowrite (Core/Autowrite.swift): what you say is the ask, and what
    /// lands is what the engine writes from it and the screen. Set once the key has been
    /// held for `DS.Motion.writeArm`, cleared when the run lands, fails or is abandoned.
    private(set) var isWriting = false
    /// What the overlay shows of Autowrite once the key comes up (O6.2 to O6.4): what
    /// you asked and the writing as it arrives, then the whole of it under Copied when
    /// there was no text box, or why it couldn't write.
    struct Writing: Equatable {
        enum Phase: Equatable { case writing, copied, failed }
        var phase: Phase
        var ask: String
        var text: String
    }
    private(set) var writing: Writing?
    /// The screen as Autowrite read it, for the small picture in the overlay (O6, 4-09):
    /// proof it is looking, and at what. Nil until the screen is in, or without permission.
    private(set) var screenPicture: NSImage?
    private var writeArmTask: Task<Void, Never>?
    private var screenTask: Task<ScreenContext, Never>?
    private var writeTask: Task<Void, Never>?
    private var writeClearTask: Task<Void, Never>?
    /// The longest a write may take once the ask is in, before it is abandoned with a reason.
    private static let writeTimeout: Duration = .seconds(60)

    /// A dictation that landed: saved, and typed unless SigmaFlow was in front. The first
    /// open reads it to fill its field and to know hands free was tried.
    struct Landing: Equatable {
        let number: Int
        let text: String
        let handsFree: Bool
    }
    private(set) var lastLanding: Landing?

    /// The first open holds the key back while Parakeet is still arriving (2B): a hold then
    /// does nothing rather than reaching for a model that isn't there yet.
    var waitsForModel = false

    /// Right ⌥, as the hotkey monitor last saw it.
    private(set) var companionHeld = false
    /// Power mode is on and Right ⌥ is held with Right ⌘: this dictation is sent when it
    /// lands, and the overlay reads REC IN POWER MODE. Let go of Right ⌥ first and it is an
    /// ordinary paste again. Never for hands-free (no second key to hold) or a preview.
    var isPowerHeld: Bool {
        Settings.shared.powerMode && Settings.shared.pushToTalkKey == .rightCommand
            && companionHeld && !isLatched && !isPreview && !isWriting
    }

    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    private let makeEngine: @Sendable () -> any TranscriptionEngine

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?

    /// Chosen per-utterance so the menu toggle applies to the very next hold.
    private var activeFormatter: any TextFormatter {
        if let formatter { return formatter }
        return Settings.shared.smartCleanup
            ? FoundationModelFormatter()
            : RuleBasedFormatter()
    }

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?

    /// Timestamps for the run log: when the key went down, and when it came up. Read by
    /// the overlay tiles for the timer of a preview run.
    private(set) var holdStarted: Date?
    private(set) var releasedAt: Date?
    private var engineName = ""

    /// Bumped whenever a session starts or is cancelled. Async tails from an abandoned
    /// session check it before touching shared state, so a hung engine can never act on
    /// a recording the user already walked away from.
    private var runGeneration = 0
    /// When a sub-300ms tap ended, for double-tap detection. The first open lights its
    /// first tap dot from it.
    private(set) var lastTapEndedAt: Date?

    init(
        formatter: (any TextFormatter)? = nil,
        makeEngine: @escaping @Sendable () -> any TranscriptionEngine = engineForCurrentSetting
    ) {
        self.formatter = formatter
        self.makeEngine = makeEngine
    }

    // MARK: - Lifecycle

    /// - Returns: `false` if the hotkey tap couldn't be installed (missing Accessibility).
    @discardableResult
    func activate() -> Bool {
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onEscape = { [weak self] in self?.escapePressed() ?? false }
        hotkey.onOtherKey = { [weak self] in self?.otherKeyPressed() }
        hotkey.onTyping = { TypedWords.shared.note($0) }
        hotkey.onUndoKey = {
            guard CorrectionLearner.shared.canUndo else { return false }
            return CorrectionLearner.shared.undo()
        }
        hotkey.onStyleKey = { [weak self] key in
            guard let self, let style = StyleStore.shared.style(forShortcut: key) else { return false }
            // Never rewrite while the mic is open: the user is mid-sentence, not mid-edit.
            guard !self.state.isActive else { return true }
            SelectionRewriter.apply(style, controller: self)
            return true
        }
        hotkey.onCompanionChange = { [weak self] down in self?.companionHeld = down }
        hotkey.writeKey = WriteKey.key(besides: Settings.shared.pushToTalkKey)
        hotkey.onWritePress = { [weak self] in self?.writeKeyPressed() }
        hotkey.onWriteRelease = { [weak self] in self?.writeKeyReleased() }
        hotkey.onWriteInterrupted = { [weak self] in self?.writeKeyInterrupted() }
        hotkey.onMeetingKey = {
            MeetingSession.shared.toggle()
            return true
        }
        hotkey.onNotesKey = {
            NotesSession.shared.toggle()
            return true
        }
        hotkey.onScreenshotKey = { [weak self] in
            guard NotesSession.shared.isOpen else { return false }
            self?.screenshotKeyPressed()
            NotesSession.shared.screenshotNow()
            return true
        }
        hotkeyArmed = hotkey.start()
        return hotkeyArmed
    }

    func deactivate() {
        hotkey.stop()
        cancelDictation()
    }

    /// Re-arms the tap after the user picks a different push-to-talk key.
    @discardableResult
    func reloadHotkey() -> Bool {
        hotkey.stop()
        return activate()
    }

    // MARK: - Hotkey grammar
    //
    // Hold = push-to-talk. A sub-300ms tap isn't dictation — it's half of a double-tap,
    // which latches recording on hands-free; the next single tap ends it the normal way.
    // Esc abandons: any recording, latched or held, and a stuck processing run. The
    // hotkey ends things, Esc throws things away.

    private func hotkeyPressed() {
        if state == .finishing {
            cancelDictation()  // tapping the key abandons a stuck processing run
            return
        }
        if isLatched {
            endDictation()     // one tap ends a latched recording, same as releasing a hold
            return
        }
        guard case .idle = state, !waitsForModel else { return }
        if let last = lastTapEndedAt, Date().timeIntervalSince(last) < 0.35 {
            lastTapEndedAt = nil
            isLatched = true
        }
        beginDictation()
    }

    private func hotkeyReleased() {
        if ignoresNextRelease {
            ignoresNextRelease = false
            return
        }
        if isLatched { return }  // the tap that started the latch lifts; recording continues
        guard state.isActive, state != .finishing else { return }
        // A sub-300ms hold is a tap, not dictation: discard the fragment and arm the
        // double-tap window. Nothing intelligible fits in a third of a second anyway.
        if let holdStarted, Date().timeIntervalSince(holdStarted) < 0.3 {
            lastTapEndedAt = Date()
            cancelDictation()
            return
        }
        endDictation()
    }

    /// Right ⌘ + S while live notes are open: the ⌘ going down already started a dictation
    /// (it is the push-to-talk key), so the S takes it back. Nothing is typed, the ⌘
    /// coming up is not a tap, and two quick screenshots never latch hands-free.
    private var ignoresNextRelease = false

    private func screenshotKeyPressed() {
        guard Settings.shared.pushToTalkKey == .rightCommand, !isLatched,
              state.isActive, state != .finishing, holdStarted != nil else { return }
        cancelDictation()
        lastTapEndedAt = nil
        ignoresNextRelease = true
    }

    /// Hands-free recording ends when you start typing: any ordinary key stops it and the
    /// transcript lands, exactly as a tap of the hotkey would. Esc still abandons instead.
    private func otherKeyPressed() {
        guard isLatched, state.isActive, state != .finishing else { return }
        endDictation()
    }

    // MARK: - Autowrite's key
    //
    // Hold, talk, let go. The key only counts once held for `writeArm` with no other key:
    // Right ⌥ and Right ⌘ are also half of everyday shortcuts, and those must never open
    // the mic, pause the music or flash the overlay. No double tap, no hands free.

    private func writeKeyPressed() {
        if state == .finishing && isWriting {
            cancelDictation()  // as with the dictation key: a press abandons a stuck run
            return
        }
        guard case .idle = state, !waitsForModel else { return }
        writeArmTask?.cancel()
        writeArmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DS.Motion.writeArm))
            guard let self, !Task.isCancelled, case .idle = self.state else { return }
            self.writeArmTask = nil
            self.beginWriting()
        }
    }

    private func writeKeyReleased() {
        if let armTask = writeArmTask {
            // Let go before it counted: a tap, nothing happens.
            armTask.cancel()
            writeArmTask = nil
            return
        }
        guard isWriting, !isPreview, state.isActive, state != .finishing else { return }
        endDictation()
    }

    /// Another key went down while the key was held: it was a shortcut. Before the key has
    /// counted nothing started; after, the run is thrown away without a word.
    private func writeKeyInterrupted() {
        writeArmTask?.cancel()
        writeArmTask = nil
        guard isWriting, !isPreview, state.isActive, state != .finishing else { return }
        cancelDictation()
    }

    private func beginWriting() {
        writeClearTask?.cancel()
        writeClearTask = nil
        writing = nil
        screenPicture = nil
        isWriting = true
        // The screen as it is now, while you talk. SigmaFlow's own windows are left out, so
        // the overlay and the dimming coming up are never part of it.
        let generation = runGeneration + 1  // the run beginDictation is about to start
        screenTask = Task { @MainActor [weak self] in
            let context = await ScreenReader.read()
            if let self, self.runGeneration == generation, self.isWriting {
                self.screenPicture = context.jpeg.flatMap { NSImage(data: $0) }
            }
            return context
        }
        beginDictation()
    }

    /// The ask is in: write it, then type it where the cursor is, or copy it when there is
    /// nowhere to type. Runs after the dictation's own tail has finished, so its watchdog
    /// never times a write; this one has `writeTimeout`.
    private func write(ask raw: String, generation: Int) async {
        let (ask, _) = DictionaryStore.shared.corrector.apply(to: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        writing = Writing(phase: .writing, ask: ask, text: "")
        var context = ScreenContext.empty
        if let screenTask { context = await screenTask.value }
        screenTask = nil
        guard runGeneration == generation, state == .finishing else { return }

        let engine: any WritingEngine
        do {
            engine = try WriteEngines.current()
        } catch {
            failWriting(error.localizedDescription)
            return
        }

        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeTimeout)
            guard let self, !Task.isCancelled, self.runGeneration == generation, self.state == .finishing else { return }
            Log.app.error("autowrite: overran its time — abandoning")
            self.failWriting("That took too long, so nothing was typed.")
        }
        defer { watchdog.cancel() }

        var text = ""
        do {
            for try await sofar in engine.write(ask: ask, context: context) {
                guard runGeneration == generation, state == .finishing else { return }
                text = sofar
                writing?.text = sofar
            }
        } catch {
            guard runGeneration == generation, state == .finishing else { return }
            failWriting(error.localizedDescription)
            return
        }
        guard runGeneration == generation, state == .finishing else { return }

        // The dictionary runs last here too, so a name it guarantees is spelt its way.
        let (output, _) = DictionaryStore.shared.corrector.apply(to: WritePrompt.tidy(text))
        guard !output.isEmpty else {
            failWriting("Nothing came back, so nothing was typed.")
            return
        }
        holdStarted = nil
        releasedAt = nil
        SystemSounds.playStop()

        // Not saved to Transcriptions: only what you dictate is. Not watched by the learner:
        // an edit to it is an edit to the engine's words, not a misheard one.
        let focus = NSApp.isActive ? .notText : TextInjector.focus()
        if focus == .notText {
            TextInjector.copy(output)
            writing = Writing(phase: .copied, ask: ask, text: output)
            isWriting = false
            screenPicture = nil
            state = .idle
            writeClearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(DS.Motion.writeCopiedHold))
                guard let self, !Task.isCancelled, self.writing?.phase == .copied else { return }
                self.writing = nil
            }
        } else {
            TextInjector.insert(output)
            endWriting()
        }
    }

    private func endWriting() {
        writing = nil
        isWriting = false
        screenPicture = nil
        state = .idle
        transcript = ""
    }

    /// Couldn't write (O6.4): the reason stays a few seconds, nothing is typed, the clipboard
    /// is left alone. Bumps the generation so a late piece of writing can't land after it.
    private func failWriting(_ message: String) {
        Log.app.error("autowrite: \(message, privacy: .public)")
        runGeneration += 1
        writeTask?.cancel()
        writeTask = nil
        let ask = writing?.ask ?? ""
        writing = Writing(phase: .failed, ask: ask, text: message)
        isWriting = false
        screenPicture = nil
        holdStarted = nil
        releasedAt = nil
        transcript = ""
        state = .idle
        writeClearTask?.cancel()
        writeClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DS.Motion.writeFailedHold))
            guard let self, !Task.isCancelled, self.writing?.phase == .failed else { return }
            self.writing = nil
        }
    }

    /// Everything Autowrite holds, dropped: an abandoned or failed run.
    private func dropWriting() {
        writeArmTask?.cancel()
        writeArmTask = nil
        screenTask?.cancel()
        screenTask = nil
        writeTask?.cancel()
        writeTask = nil
        isWriting = false
        screenPicture = nil
        if writing?.phase == .writing { writing = nil }
    }

    /// - Returns: `true` when something was abandoned (the keystroke gets swallowed).
    private func escapePressed() -> Bool {
        guard state.isActive else { return false }
        cancelDictation()
        return true
    }

    // MARK: - Preview

    /// Hold to talk went down. Ignored while a real dictation owns the mic.
    func beginPreview() {
        guard case .idle = state else { return }
        isPreview = true
        previewText = ""
        beginDictation()
    }

    /// Hold to talk came up. A click shorter than a hold is thrown away, as with the key.
    func endPreview() {
        guard isPreview, state.isActive, state != .finishing else { return }
        if let holdStarted, Date().timeIntervalSince(holdStarted) < 0.3 {
            cancelDictation()
            return
        }
        endDictation()
    }

    // MARK: - Dictation

    private func beginDictation() {
        guard case .idle = state else { return }
        // A Copied or Couldn't write still showing gives way to the next run.
        if !isWriting { writeClearTask?.cancel(); writing = nil }
        state = .starting
        transcript = ""
        runGeneration += 1
        let generation = runGeneration
        MediaPauser.shared.recordingStarted()
        holdStarted = Date()
        engineName = Settings.shared.activeModel.displayName

        Task { @MainActor in
            do {
                guard await Permissions.requestMicrophone() else {
                    fail("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    return
                }

                let engine = makeEngine()
                self.engine = engine

                let chunks = try await engine.start()

                // The engine dictates the capture format, never the other way round.
                // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
                // as a hard precondition — feeding it float32 doesn't fail gracefully, it
                // kills the process.
                guard let format = await engine.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }

                // The user may have cancelled (Esc, or a tap fragment) while the model
                // was spinning up — and a newer session may even own the mic already,
                // so tearing down shared state here would sabotage it. Just walk away.
                guard self.runGeneration == generation else {
                    await engine.finish()
                    return
                }
                guard case .starting = self.state else {
                    await self.teardown()
                    return
                }

                // Audio must reach the engine in capture order. A stream plus a single
                // draining task guarantees that; spawning a Task per buffer would not.
                let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )
                self.audioContinuation = audioContinuation

                self.feedTask = Task.detached(priority: .userInitiated) {
                    for await chunk in audioStream {
                        await engine.feed(chunk)
                    }
                }

                try capture.start(
                    outputFormat: format,
                    inputDeviceUID: Settings.shared.microphoneID,
                    onBuffer: { chunk in
                        audioContinuation.yield(chunk)
                    },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.updateLevel(level) }
                    }
                )

                self.state = .listening
                SystemSounds.playStart()

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunks {
                            self.transcript = chunk.text
                        }
                    } catch {
                        self.fail(error.localizedDescription)
                    }
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func endDictation() {
        // `.finishing` is "active", so without this a second press during processing would
        // run the whole tail again — re-reading `transcript` before the first pass cleared
        // it and pasting the same utterance twice. The window is wide: Parakeet transcribes
        // inside `finish()`, and smart cleanup adds up to 4s on top.
        guard state.isActive, state != .finishing else { return }
        // Decided at release, before the latch clears: the monitor updates Right ⌥ from
        // the same event that carries the ⌘ release, so this is the state at let-go.
        let sendOnLand = isPowerHeld
        let wasHandsFree = isLatched
        state = .finishing
        isLatched = false
        capture.stop()
        MediaPauser.shared.recordingEnded()
        level = 0
        releasedAt = Date()

        let generation = runGeneration
        let audioSeconds = holdStarted.map { Date().timeIntervalSince($0) } ?? 0

        Task { @MainActor in
            // Watchdog: a hung engine must never own the screen. Batch models earn
            // generous room — the budget scales with how long you spoke — and then the
            // run is abandoned with a visible reason instead of an eternal PROCESSING.
            let timeout = min(180, max(30, audioSeconds * 3))
            let watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled,
                      self.runGeneration == generation, self.state == .finishing else { return }
                Log.speech.error("watchdog: transcription overran \(Int(timeout))s — abandoning")
                self.cancelDictation(
                    message: "That took too long, so the recording was abandoned. Try again, or pick a faster model in Models."
                )
            }
            defer { watchdog.cancel() }

            // Drain every captured buffer into the engine before asking it to finalize,
            // or the tail of the utterance gets dropped.
            audioContinuation?.finish()
            audioContinuation = nil
            await feedTask?.value
            feedTask = nil

            await engine?.finish()
            await consumeTask?.value
            consumeTask = nil
            engine = nil

            // The watchdog or an Esc may have abandoned this run while the engine was
            // finishing — in that case whatever it produced is dead on arrival.
            guard runGeneration == generation, state == .finishing else { return }

            let raw = transcript
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                dropWriting()
                state = .idle
                transcript = ""
                isPreview = false
                return
            }

            // Autowrite: what was said is the ask. Its own task, so this tail (and its
            // watchdog) ends here; the run stays `.finishing`, so Esc still abandons it.
            if isWriting {
                writeTask = Task { @MainActor [weak self] in
                    await self?.write(ask: raw, generation: generation)
                }
                return
            }

            let cleaned = Settings.shared.cleanupEnabled
                ? await activeFormatter.format(raw)
                : raw

            // The default style shapes capitals and punctuation on every dictation, and
            // runs before the dictionary so a name the dictionary guarantees keeps its
            // capitals. Off means typed exactly as heard, style included.
            let styled = Settings.shared.cleanupEnabled
                ? Settings.shared.defaultStyle.apply(to: cleaned)
                : cleaned

            // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
            // only raises the odds of the right word; this is the pass that guarantees it,
            // so it must not be something the user can accidentally switch off.
            let (corrected, corrections) = DictionaryStore.shared.corrector.apply(to: styled)
            if !corrections.isEmpty {
                Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
            }

            // Snippets expand after the dictionary, so a trigger the engine mishears can be
            // rescued by a correction first ("my work e mail" -> "my work email").
            let (output, expanded) = SnippetStore.shared.expand(corrected)
            if !expanded.isEmpty {
                Log.speech.info("snippets · \(expanded.count, privacy: .public) expanded")
            }

            // A preview hands its words to the overlay tiles and stops there: not saved,
            // not typed, nothing for the learner to watch.
            if isPreview {
                previewText = output
                holdStarted = nil
                releasedAt = nil
                SystemSounds.playStop()
                state = .idle
                transcript = ""
                isPreview = false
                return
            }

            let run = recordRun(text: output, corrections: corrections)
            lastLanding = Landing(number: (lastLanding?.number ?? 0) + 1, text: output, handsFree: wasHandsFree)

            // Holding the key while SigmaFlow itself is the front app is the test: the
            // transcript is saved to the list above, but nothing gets typed anywhere.
            if !NSApp.isActive {
                let target = TextInjector.insert(output, pressingReturn: sendOnLand)
                // A sent message leaves the field; there is no edit left to learn from, and
                // what was sent is what was said. Otherwise an edit reaches the saved
                // transcript, and may become a rule when learning is on.
                if !sendOnLand, let target {
                    CorrectionLearner.shared.watch(
                        target, inserted: output, run: run,
                        learn: Settings.shared.learnFromCorrections
                    )
                }
            }
            SystemSounds.playStop()

            state = .idle
            transcript = ""
        }
    }

    /// Abandons whatever is happening — a live recording, a latched one, or a stuck
    /// processing run. Nothing is transcribed, nothing is saved, nothing is typed.
    private func cancelDictation(message: String? = nil) {
        runGeneration += 1
        isLatched = false
        dropWriting()
        capture.stop()
        MediaPauser.shared.recordingEnded()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil

        let engine = self.engine
        self.engine = nil
        Task { await engine?.finish() }

        transcript = ""
        level = 0
        holdStarted = nil
        releasedAt = nil

        if let message {
            state = .error(message)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if case .error = state { state = .idle; isPreview = false }
            }
        } else {
            state = .idle
            isPreview = false
        }
    }

    private func teardown() async {
        dropWriting()
        capture.stop()
        MediaPauser.shared.recordingEnded()
        audioContinuation?.finish()
        audioContinuation = nil
        await feedTask?.value
        feedTask = nil
        await engine?.finish()
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .idle
        isPreview = false
    }

    // MARK: - Helpers

    /// Files the finished utterance for the Transcriptions page.
    ///
    /// `processSeconds` is measured from key release, not from capture start — that's the
    /// wait the user actually experiences, and it means the same thing for a streaming
    /// engine and a batch one.
    /// - Returns: the saved run's id, so a later edit in the field can update it.
    @discardableResult
    private func recordRun(text: String, corrections: [AppliedCorrection] = []) -> UUID? {
        guard let holdStarted, let releasedAt else { return nil }
        let run = DictationRun(
            date: releasedAt,
            engine: engineName,
            audioSeconds: releasedAt.timeIntervalSince(holdStarted),
            processSeconds: Date().timeIntervalSince(releasedAt),
            text: text,
            corrections: corrections.isEmpty ? nil : corrections
        )
        RunLog.record(run)
        self.holdStarted = nil
        self.releasedAt = nil
        return run.id
    }

    // MARK: - Style activity

    func beginStyleActivity(_ name: String, message: String) {
        styleClearTask?.cancel()
        styleClearTask = nil
        styleActivity = StyleActivity(name: name, message: message)
    }

    func endStyleActivity() {
        styleActivity = nil
        styleClearTask?.cancel()
        styleClearTask = nil
    }

    /// Failures linger a few seconds so the reason is readable, then clear themselves.
    func failStyleActivity(_ name: String, message: String) {
        styleActivity = StyleActivity(name: name, message: message, isError: true)
        styleClearTask?.cancel()
        styleClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.styleActivity = nil
        }
    }

    /// Light smoothing so the waveform glides instead of strobing at buffer rate.
    private func updateLevel(_ new: Float) {
        level += (new - level) * 0.35
    }

    private func fail(_ message: String) {
        Log.app.error("\(message)")
        isLatched = false
        dropWriting()
        capture.stop()
        MediaPauser.shared.recordingEnded()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .error(message)
        level = 0

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { state = .idle; isPreview = false }
        }
    }
}
