import AppKit
import Foundation

/// Pauses whatever is playing when a recording starts, and resumes it a moment after the
/// recording ends.
///
/// Control goes through MediaRemote — the framework behind the Now Playing widget and the
/// keyboard's play/pause key — so it reaches whichever app owns the Now Playing session:
/// Music, Spotify, a YouTube tab. Since macOS 15.4 that framework answers "nothing playing"
/// to any process without Apple's private entitlement, and a pause sent from here goes
/// nowhere. So the app never talks to it directly: every query and command runs inside
/// `/usr/bin/perl`, an Apple platform binary the framework trusts, which loads the
/// `SigmaFlowMediaHost` dylib from Contents/Frameworks. `Sources/SigmaFlowMediaHost/
/// MediaHost.c` documents the one-word protocol; `MediaHost` below is the Swift side.
@MainActor
final class MediaPauser {
    static let shared = MediaPauser()

    /// True from the moment we paused something until the moment we've resumed it. Kept
    /// across back-to-back holds: if you dictate again inside the resume delay, the
    /// pending resume is cancelled and the music comes back after the *last* hold.
    private var didPause = false
    private var isRecording = false
    private var pauseTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?

    private init() {
        if !MediaHost.isAvailable {
            Log.audio.info("media host unavailable — pause-media does nothing this session")
        }
    }

    func recordingStarted() {
        isRecording = true
        guard Settings.shared.pauseMediaWhileRecording, MediaHost.isAvailable else { return }
        resumeTask?.cancel()
        resumeTask = nil
        // Still inside a previous hold's resume window, or a pause is already in flight:
        // media is (about to be) paused by us, so there is nothing to ask.
        guard !didPause, pauseTask == nil else { return }

        pauseTask = Task { @MainActor in
            defer { pauseTask = nil }
            guard isRecording, Settings.shared.pauseMediaWhileRecording else { return }
            // The host looks before it pauses, so a quiet room stays quiet, and only
            // "paused" means there is something to resume later.
            let reply = await MediaHost.run(.pause)
            switch reply {
            case "paused":
                didPause = true
                Log.audio.info("media paused for recording")
                // A tap so short the key was already up: resume on the normal schedule.
                if !isRecording { scheduleResume() }
            case "idle":
                break
            default:
                Log.audio.error("media host: \(reply ?? "no reply", privacy: .public)")
            }
        }
    }

    func recordingEnded() {
        isRecording = false
        guard didPause else { return }
        scheduleResume()
    }

    private func scheduleResume() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let reply = await MediaHost.run(.play)
            didPause = false
            resumeTask = nil
            if reply == "playing" {
                Log.audio.info("media resumed")
            } else {
                Log.audio.error("media host: \(reply ?? "no reply", privacy: .public)")
            }
        }
    }
}

/// One command through the perl-hosted MediaRemote bridge. Runs off the main actor: perl
/// takes ~25 ms to start and answer, and a stuck child is killed after two seconds so a
/// wedged mediaremoted can never hang a recording.
enum MediaHost {
    enum Command: String, Sendable { case status, pause, play }

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    /// The dylib the Makefile stages into Contents/Frameworks. Nil when running a bare
    /// `swift build` binary, or on a Mac that has dropped perl — the feature then does
    /// nothing rather than misfiring.
    private static let library: URL? = {
        guard let url = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("libSigmaFlowMediaHost.dylib"),
              FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isExecutableFile(atPath: perl.path)
        else { return nil }
        return url
    }()

    static var isAvailable: Bool { library != nil }

    /// The bridge's one-word reply, or nil when perl could not be run at all.
    static func run(_ command: Command) async -> String? {
        guard let library else { return nil }
        return await Task.detached(priority: .userInitiated) {
            // Process isn't Sendable; it never leaves this closure, but the watchdog block
            // below has to name it.
            nonisolated(unsafe) let process = Process()
            process.executableURL = perl
            // DynaLoader is perl's CPAN-extension loader; dl_load_file is a dlopen, and the
            // dylib's constructor does everything before perl gets its next statement.
            process.arguments = [
                "-e",
                "use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();",
                library.path,
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["SIGMAFLOW_MEDIA_COMMAND"] = command.rawValue
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return nil
            }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2), execute: watchdog)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
