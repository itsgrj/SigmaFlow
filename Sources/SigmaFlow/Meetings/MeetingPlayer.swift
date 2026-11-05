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
///
/// A call's file keeps the microphone on the left and the call on the right (`MeetingAudio`),
/// which played as the user in one ear and everyone else in the other (Gokul, 4 Nov 2026).
/// So the sound goes through a one-channel mixer on its way out: both sides, both ears. The
/// file itself stays two-sided; the transcript needs the sides apart.
///
/// A meeting recorded with video plays its .mp4 instead (docs/mockups/meeting-video.html, 22),
/// through `video`, whose picture the transcript shows: one clock for the picture, the sound
/// (already one channel in that file) and the line that is filled.
@MainActor
@Observable
final class MeetingPlayer {
    static let shared = MeetingPlayer()

    /// The file playing or paused now, if any.
    private(set) var playing: URL?
    /// Paused part way: `playing` keeps the file and `elapsed` the place.
    private(set) var isPaused = false
    /// Seconds into it.
    private(set) var elapsed: TimeInterval = 0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// The one channel both sides are folded into.
    private let together = AVAudioMixerNode()
    private var file: AVAudioFile?
    /// Where the part now scheduled starts, in seconds; the node's clock counts from there.
    private var offset: TimeInterval = 0
    /// Bumped whenever the scheduled part is dropped, so its end can't stop a newer one.
    private var scheduling = 0
    private var ticker: Task<Void, Never>?
    /// The filmed meeting playing or paused, for its picture.
    private(set) var video: AVPlayer?
    private var videoEnded: NSObjectProtocol?

    private init() {
        engine.attach(node)
        engine.attach(together)
        // A new output (AirPods in, a display's speakers) stops the engine; carry on there.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MeetingPlayer.shared.outputChanged() }
        }
    }

    /// From the start, from `time`, or, for the file already paused, from where it paused.
    func play(_ url: URL, from time: TimeInterval? = nil) {
        if url.pathExtension.lowercased() == "mp4" { return playVideo(url, from: time) }
        if url != playing || file == nil {
            stop()
            guard let file = try? AVAudioFile(forReading: url),
                  let one = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1)
            else {
                Log.meetings.error("couldn't play \(url.lastPathComponent, privacy: .public)")
                return
            }
            engine.connect(node, to: together, format: file.processingFormat)
            engine.connect(together, to: engine.mainMixerNode, format: one)
            self.file = file
            playing = url
            start(at: time ?? 0)
        } else if let time {
            start(at: time)
        } else if isPaused {
            node.play()
            isPaused = false
            tick()
        }
    }

    func pause() {
        if let video, !isPaused {
            video.pause()
            elapsed = video.currentTime().seconds
            ticker?.cancel()
            ticker = nil
            isPaused = true
            return
        }
        guard file != nil, !isPaused else { return }
        elapsed = position
        node.pause()
        ticker?.cancel()
        ticker = nil
        isPaused = true
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        video?.pause()
        video = nil
        if let videoEnded { NotificationCenter.default.removeObserver(videoEnded) }
        videoEnded = nil
        scheduling += 1
        node.stop()
        engine.stop()
        file = nil
        playing = nil
        isPaused = false
        elapsed = 0
        offset = 0
    }

    private func playVideo(_ url: URL, from time: TimeInterval?) {
        if url != playing || video == nil {
            stop()
            let player = AVPlayer(url: url)
            video = player
            playing = url
            videoEnded = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
            ) { _ in
                MainActor.assumeIsolated { MeetingPlayer.shared.stop() }
            }
            seekVideo(to: time ?? 0)
        } else if let time {
            seekVideo(to: time)
        } else if isPaused {
            video?.play()
            isPaused = false
            tick()
        }
    }

    private func seekVideo(to time: TimeInterval) {
        guard let video else { return }
        video.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        video.play()
        isPaused = false
        elapsed = time
        tick()
    }

    private func start(at time: TimeInterval) {
        guard let file else { return }
        let rate = file.processingFormat.sampleRate
        let first = min(max(0, AVAudioFramePosition(time * rate)), file.length)
        scheduling += 1
        node.stop()
        guard first < file.length else { return stop() }
        let scheduled = scheduling
        node.scheduleSegment(
            file, startingFrame: first, frameCount: AVAudioFrameCount(file.length - first), at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.scheduling == scheduled else { return }
                self.stop()
            }
        }
        offset = Double(first) / rate
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            Log.meetings.error("couldn't play: \(error.localizedDescription, privacy: .public)")
            return stop()
        }
        node.play()
        isPaused = false
        elapsed = offset
        tick()
    }

    private func tick() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.elapsed = self.position
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Seconds into the file, by the node's clock.
    private var position: TimeInterval {
        if let video { return video.currentTime().seconds }
        guard let now = node.lastRenderTime, let time = node.playerTime(forNodeTime: now) else { return elapsed }
        return offset + Double(time.sampleTime) / time.sampleRate
    }

    private func outputChanged() {
        guard file != nil else { return }
        let wasPaused = isPaused
        start(at: elapsed)
        if wasPaused { pause() }
    }
}
