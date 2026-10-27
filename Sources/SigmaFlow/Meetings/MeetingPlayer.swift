import AVFoundation
import Foundation
import Observation

/// Plays a meeting's audio inside SigmaFlow.
///
/// Play used to hand the file to whatever app opens .m4a files. On Gokul's Mac that is
/// Music, which played it with no window in sight, so there was sound with nothing to stop
/// it but Activity Monitor (16 Oct 2026). Now the button that starts it is the button that
/// pauses it, and leaving the transcript or quitting the app stops it too.
///
/// One button since 20 Oct 2026 (docs/mockups/conversation-playback.html, 2A): Pause keeps
/// the place and Play carries on from it. A click on a line plays from that line (5B).
@MainActor
@Observable
final class MeetingPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = MeetingPlayer()

    /// The file playing or paused now, if any.
    private(set) var playing: URL?
    /// Paused part way: `playing` keeps the file and `elapsed` the place.
    private(set) var isPaused = false
    /// Seconds into it.
    private(set) var elapsed: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    /// From the start, from `time`, or, for the file already paused, from where it paused.
    func play(_ url: URL, from time: TimeInterval? = nil) {
        if url != playing || player == nil {
            stop()
            guard let player = try? AVAudioPlayer(contentsOf: url) else {
                Log.meetings.error("couldn't play \(url.lastPathComponent, privacy: .public)")
                return
            }
            player.delegate = self
            self.player = player
            playing = url
        }
        guard let player else { return }
        if let time { player.currentTime = min(max(0, time), player.duration) }
        guard player.play() else { return stop() }
        isPaused = false
        elapsed = player.currentTime
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.elapsed = player.currentTime
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func pause() {
        guard let player, !isPaused else { return }
        player.pause()
        ticker?.cancel()
        ticker = nil
        elapsed = player.currentTime
        isPaused = true
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        playing = nil
        isPaused = false
        elapsed = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
